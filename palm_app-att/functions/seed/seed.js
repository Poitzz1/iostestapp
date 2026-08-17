#!/usr/bin/env node
/**
 * PalmPay seed script — provisions advisors and classroom skeletons.
 *
 * These records CANNOT be created from the app: firestore.rules make
 * `staff/*` client-unwritable entirely, and `classrooms/*` admin-only, so this
 * runs with the Admin SDK (which bypasses rules).
 *
 * IDEMPOTENT — safe to re-run:
 *  - staff docs are merged (edit the JSON, re-run, values update).
 *  - classrooms are merged and an already-captured `wifi_fingerprint` is
 *    NEVER overwritten (that's captured in-app by an admin standing in the
 *    room). A fingerprint only gets seeded as [] the first time the classroom
 *    is created.
 *
 * USAGE
 *   cd functions
 *   npm install
 *   # one-time: get a service account key from
 *   #   Firebase Console → Project Settings → Service Accounts → Generate key
 *   export GOOGLE_APPLICATION_CREDENTIALS=/abs/path/serviceAccountKey.json
 *   cp seed/seed-data.example.json seed/seed-data.json   # then edit it
 *   node seed/seed.js                 # apply
 *   node seed/seed.js --dry-run       # preview only, writes nothing
 *   node seed/seed.js --file other.json
 *
 * Advisor `uid` must be the Firebase Auth UID of an already-registered
 * account (Console → Authentication → Users). The app looks up staff by UID,
 * so a wrong UID silently means "not staff".
 *
 * You only need this script to bootstrap the FIRST coordinator (or admin) on
 * a fresh project. After that, a coordinator adds every advisor from inside
 * the app (Manage Advisors screen) — no further console work or re-run of
 * this script is needed for ordinary advisor onboarding.
 */

import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, isAbsolute } from "node:path";

import { initializeApp, cert, applicationDefault } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── args ───────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const DRY_RUN = args.includes("--dry-run");
const fileArgIdx = args.indexOf("--file");
const dataFileArg = fileArgIdx !== -1 ? args[fileArgIdx + 1] : "seed-data.json";
const dataPath = isAbsolute(dataFileArg) ? dataFileArg : join(__dirname, dataFileArg);

const PROJECT_ID = process.env.GCLOUD_PROJECT || "attcit-52e7d";
// This project's database is literally named `default`, not `(default)`.
const DATABASE_ID = process.env.FIRESTORE_DATABASE_ID || "default";

function fail(msg) {
  console.error(`\n✖ ${msg}\n`);
  process.exit(1);
}

// ── load input ─────────────────────────────────────────────────────────────
if (!existsSync(dataPath)) {
  fail(
    `No seed file at ${dataPath}\n` +
      `  Copy the example first:  cp seed/seed-data.example.json seed/seed-data.json`
  );
}

let data;
try {
  data = JSON.parse(readFileSync(dataPath, "utf8"));
} catch (e) {
  fail(`${dataPath} is not valid JSON — check for a missing comma or quote.\n  ${e.message}`);
}

const advisors = data.advisors || [];
const classrooms = data.classrooms || [];

// ── validate before touching the database ──────────────────────────────────
const problems = [];

advisors.forEach((a, i) => {
  const where = `advisors[${i}] (${a.name || a.staff_id || "unnamed"})`;
  if (!a.uid || String(a.uid).startsWith("REPLACE_")) {
    problems.push(`${where}: uid is missing or still the placeholder. Use the Firebase Auth UID.`);
  }
  if (!a.staff_id) problems.push(`${where}: staff_id is required.`);
  // Advisors must own at least one section (that's what they open sessions
  // for). An admin or coordinator may have none — a coordinator only manages
  // the advisor roster (see assignAdvisor in functions/index.js) and never
  // opens a session itself.
  const exemptFromSections = a.role === "admin" || a.role === "coordinator";
  if (!Array.isArray(a.sections) || a.sections.length === 0) {
    if (!exemptFromSections) {
      problems.push(`${where}: sections must be a non-empty list, e.g. ["CSE-A"].`);
    }
  }
  if (a.role && !["advisor", "admin", "coordinator"].includes(a.role)) {
    problems.push(`${where}: role must be "advisor", "admin", or "coordinator" (got "${a.role}").`);
  }
});

const warnings = [];
classrooms.forEach((c, i) => {
  const where = `classrooms[${i}] (${c.classroom_id || "no id"})`;
  if (!c.classroom_id) problems.push(`${where}: classroom_id is required, e.g. "C302".`);
  // lat/lng are OPTIONAL. GPS is only a coarse campus sanity check (spec §7)
  // and the server skips it entirely when a classroom has no coordinates —
  // the Wi-Fi fingerprint is the real presence gate. Better to omit them than
  // to guess wrong coordinates, which would reject everyone with
  // `gps_out_of_campus`.
  if ((c.latitude == null) !== (c.longitude == null)) {
    problems.push(`${where}: set BOTH latitude and longitude, or neither.`);
  }
  if (c.latitude == null) {
    warnings.push(`${where}: no coordinates — the GPS campus check will be skipped for this room.`);
  }
  if (c.min_bssid_matches != null && c.min_bssid_matches < 1) {
    problems.push(`${where}: min_bssid_matches must be at least 1 (2 is recommended).`);
  }
});

const seenUids = new Set();
advisors.forEach((a) => {
  if (a.uid && seenUids.has(a.uid)) problems.push(`Duplicate advisor uid: ${a.uid}`);
  seenUids.add(a.uid);
});
const seenRooms = new Set();
classrooms.forEach((c) => {
  if (c.classroom_id && seenRooms.has(c.classroom_id)) {
    problems.push(`Duplicate classroom_id: ${c.classroom_id}`);
  }
  seenRooms.add(c.classroom_id);
});

if (problems.length) {
  console.error("\n✖ Problems in the seed file — nothing was written:\n");
  problems.forEach((p) => console.error("  • " + p));
  console.error("");
  process.exit(1);
}

if (advisors.length === 0 && classrooms.length === 0) {
  fail("Seed file has no advisors and no classrooms — nothing to do.");
}

if (warnings.length) {
  console.warn("\n! Warnings (not fatal):");
  warnings.forEach((w) => console.warn("  • " + w));
}

// ── connect ────────────────────────────────────────────────────────────────
initializeApp({
  credential: process.env.GOOGLE_APPLICATION_CREDENTIALS
    ? cert(JSON.parse(readFileSync(process.env.GOOGLE_APPLICATION_CREDENTIALS, "utf8")))
    : applicationDefault(),
  projectId: PROJECT_ID,
});
const db = getFirestore(DATABASE_ID);

// ── run ────────────────────────────────────────────────────────────────────
async function main() {
  console.log(`\nPalmPay seed`);
  console.log(`  project   : ${PROJECT_ID}`);
  console.log(`  database  : ${DATABASE_ID}`);
  console.log(`  input     : ${dataPath}`);
  console.log(`  mode      : ${DRY_RUN ? "DRY RUN (no writes)" : "APPLY"}\n`);

  let created = 0;
  let updated = 0;

  // staff/{uid}
  for (const a of advisors) {
    const ref = db.doc(`staff/${a.uid}`);
    const snap = await ref.get();
    const exists = snap.exists;

    const payload = {
      uid: a.uid,
      name: a.name ?? null,
      staff_id: a.staff_id,
      department: a.department ?? null,
      sections: Array.isArray(a.sections) ? a.sections : [],
      role: a.role || "advisor",
      // The advisor's default classroom for opening a session. Optional.
      classroom_id: a.classroom_id ?? null,
      // Convenience mirror of the first section — SessionService reads a single
      // `section` when opening a session. Null for an admin with no section:
      // they can still fingerprint classrooms, just not open a session.
      section: Array.isArray(a.sections) && a.sections.length ? a.sections[0] : null,
      updated_at: FieldValue.serverTimestamp(),
      ...(exists ? {} : { created_at: FieldValue.serverTimestamp() }),
    };

    console.log(
      `  ${exists ? "update" : "create"}  staff/${a.uid}  ${a.staff_id} · ${payload.role} · ` +
        `${payload.sections.length ? payload.sections.join(", ") : "no sections"}`
    );
    if (!DRY_RUN) await ref.set(payload, { merge: true });
    exists ? updated++ : created++;
  }

  // classrooms/{classroom_id}
  for (const c of classrooms) {
    const ref = db.doc(`classrooms/${c.classroom_id}`);
    const snap = await ref.get();
    const exists = snap.exists;
    const existingFp = exists ? snap.data().wifi_fingerprint : undefined;
    const keepFp = Array.isArray(existingFp) && existingFp.length > 0;

    const payload = {
      classroom_id: c.classroom_id,
      building: c.building ?? null,
      room: c.room ?? c.classroom_id,
      floor: c.floor ?? null,
      latitude: c.latitude,
      longitude: c.longitude,
      campus_radius_m: c.campus_radius_m ?? 300,
      min_bssid_matches: c.min_bssid_matches ?? 2,
      // ISO string, not FieldValue.serverTimestamp() — Classroom.fromFirestore
      // in the Dart app parses this with DateTime.tryParse(... as String),
      // which throws on a Firestore Timestamp. This is the same class of bug
      // as the students/created_at issue fixed above; see that note for the
      // full story.
      updated_at: new Date().toISOString(),
      // Only ever seed an EMPTY fingerprint, and only on first creation. A
      // fingerprint captured in-app must never be clobbered by a re-run.
      ...(keepFp ? {} : { wifi_fingerprint: [] }),
      ...(exists ? {} : { created_at: new Date().toISOString() }),
    };

    const fpNote = keepFp
      ? `keeping ${existingFp.length} captured APs`
      : "empty fingerprint — capture in-app";
    console.log(`  ${exists ? "update" : "create"}  classrooms/${c.classroom_id}  (${fpNote})`);
    if (!DRY_RUN) await ref.set(payload, { merge: true });
    exists ? updated++ : created++;
  }

  console.log(
    `\n${DRY_RUN ? "Would write" : "Wrote"}: ${created} created, ${updated} updated.\n`
  );

  if (!DRY_RUN) {
    const roomsNeedingFp = [];
    for (const c of classrooms) {
      const snap = await db.doc(`classrooms/${c.classroom_id}`).get();
      const fp = snap.data()?.wifi_fingerprint;
      if (!Array.isArray(fp) || fp.length === 0) roomsNeedingFp.push(c.classroom_id);
    }
    if (roomsNeedingFp.length) {
      console.log("Next step — capture Wi-Fi fingerprints (admin, standing in each room):");
      roomsNeedingFp.forEach((r) => console.log(`  • ${r}`));
      console.log(
        "\nUntil a room has a fingerprint, every attendance submission there\n" +
          "returns `classroom_not_configured`.\n"
      );
    }
  }
}

main().catch((e) => {
  console.error("\n✖ Seed failed:", e.message);
  if (/default credentials|could not load/i.test(e.message)) {
    console.error(
      "\n  This script needs a service account key to write to Firestore:\n" +
        "    1. Firebase Console → Project Settings → Service Accounts\n" +
        "    2. Click 'Generate new private key' — it downloads a .json file\n" +
        "    3. Point this script at it, then re-run:\n" +
        "         export GOOGLE_APPLICATION_CREDENTIALS=/abs/path/to/key.json\n" +
        "       (Windows PowerShell: $env:GOOGLE_APPLICATION_CREDENTIALS='C:\\path\\key.json')\n" +
        "\n  Keep that key private — never commit it.\n"
    );
  }
  if (String(e.message).includes("NOT_FOUND")) {
    console.error(
      "  Hint: this project's database is named `default`, not `(default)`.\n" +
        "  Set FIRESTORE_DATABASE_ID if you are targeting a different one."
    );
  }
  process.exit(1);
});
