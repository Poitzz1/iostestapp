/**
 * Backfill legacy single-template students into the embeddings[] shape, and
 * report multi-template coverage.
 *
 *   node backfill_embeddings.mjs            # report only, changes nothing
 *   node backfill_embeddings.mjs --apply    # perform the backfill
 *
 * Requires GOOGLE_APPLICATION_CREDENTIALS.
 *
 * WHY A BACKFILL RATHER THAN FORCED RE-ENROLMENT: 8,000+ students are already
 * enrolled with one template. Making all of them re-enrol to keep using the
 * system is not acceptable, so the read path accepts both shapes and this
 * script simply normalises the storage. A backfilled student verifies exactly
 * as they did before — one template, same score, same outcome. They gain
 * nothing until they add a second template under different lighting (that is
 * the progressive top-up flow in the app), and that is the honest position:
 * the schema move alone buys no accuracy.
 *
 * `enroll_luma_mean` is set to NULL for backfilled templates, not 0. These
 * were captured before illumination telemetry existed, so their lighting is
 * genuinely unknown — and 0 would read as "pitch black" to every spread check
 * and delta computation downstream.
 */
import { readFileSync } from "node:fs";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const APPLY = process.argv.includes("--apply");
const EMBEDDING_DIM = 256;

const key = JSON.parse(
  readFileSync(process.env.GOOGLE_APPLICATION_CREDENTIALS, "utf8")
);
initializeApp({ credential: cert(key), projectId: key.project_id });
const db = getFirestore("default");

const snap = await db.collection("students").get();

let legacyOnly = 0;
let alreadyArray = 0;
let notEnrolled = 0;
const coverage = {};
const spreads = [];
const toFix = [];

snap.forEach((doc) => {
  const d = doc.data();
  const hasArray = Array.isArray(d.embeddings) && d.embeddings.length > 0;
  const hasLegacy =
    Array.isArray(d.embedding) && d.embedding.length === EMBEDDING_DIM;

  if (hasArray) {
    alreadyArray++;
    const n = d.embeddings.length;
    coverage[n] = (coverage[n] || 0) + 1;
    const lumas = d.embeddings
      .map((e) => e && e.enroll_luma_mean)
      .filter((v) => typeof v === "number");
    if (lumas.length >= 2) spreads.push(Math.max(...lumas) - Math.min(...lumas));
  } else if (hasLegacy) {
    legacyOnly++;
    coverage[1] = (coverage[1] || 0) + 1;
    toFix.push({ ref: doc.ref, id: doc.id, d });
  } else {
    notEnrolled++;
  }
});

console.log(`students: ${snap.size}`);
console.log(`  not enrolled            ${notEnrolled}`);
console.log(`  legacy single embedding ${legacyOnly}   <- backfill target`);
console.log(`  already embeddings[]    ${alreadyArray}`);

console.log("\nTEMPLATE COVERAGE (this is what predicts the FRR improvement):");
for (const n of Object.keys(coverage).sort()) {
  console.log(`  ${n} template(s): ${coverage[n]}`);
}
if (spreads.length) {
  spreads.sort((a, b) => a - b);
  const mean = spreads.reduce((a, b) => a + b, 0) / spreads.length;
  const med = spreads[Math.floor(spreads.length / 2)];
  const weak = spreads.filter((x) => x < 18).length;
  console.log(`\nLIGHTING SPREAD across templates (n=${spreads.length}):`);
  console.log(`  mean ${mean.toFixed(1)}  median ${med.toFixed(1)}  ` +
    `min ${spreads[0].toFixed(1)}  max ${spreads[spreads.length - 1].toFixed(1)}`);
  console.log(`  under the 18-luma bar: ${weak}/${spreads.length}` +
    (weak ? "  <- these students gain little from multi-template" : ""));
} else if (alreadyArray) {
  console.log("\nNo multi-template student records a luma yet — spread unknown.");
}

if (!toFix.length) {
  console.log("\nNothing to backfill.");
  process.exit(0);
}

if (!APPLY) {
  console.log(`\nDRY RUN. ${toFix.length} student(s) would be backfilled. ` +
    `Re-run with --apply to write.`);
  process.exit(0);
}

let done = 0;
for (let i = 0; i < toFix.length; i += 400) {
  const batch = db.batch();
  for (const { ref, d } of toFix.slice(i, i + 400)) {
    batch.set(
      ref,
      {
        embeddings: [
          {
            vec: d.embedding,
            hand_side: d.hand_side ?? null,
            model_version: d.model_version ?? null,
            // NULL, not 0 — the lighting was never recorded, and 0 would read
            // as "pitch black" to every downstream spread and delta check.
            enroll_luma_mean:
              (d.enroll_illumination && typeof d.enroll_illumination.luma_mean === "number")
                ? d.enroll_illumination.luma_mean
                : null,
            enroll_luma_std:
              (d.enroll_illumination && typeof d.enroll_illumination.luma_std === "number")
                ? d.enroll_illumination.luma_std
                : null,
            captured_at: d.created_at ?? new Date().toISOString(),
            source: "enrollment",
          },
        ],
        embedding_count: 1,
        // The legacy `embedding` field is deliberately LEFT IN PLACE. Removing
        // it in the same pass would break any client still running the previous
        // build, and there is no reason to make the migration a flag day.
        updated_at: new Date().toISOString(),
      },
      { merge: true }
    );
    done++;
  }
  await batch.commit();
}
console.log(`\nBackfilled ${done} student(s) into embeddings[].`);
console.log("Legacy `embedding` left in place — older clients keep working.");
