/**
 * PalmPay Attendance — server-side verification (unified spec §6).
 *
 * THE PHONE NEVER DECIDES. The client sends evidence (an averaged palm
 * embedding, a Wi-Fi scan, GPS, a device id); this function fetches the
 * student's own stored template, runs ONE 1:1 cosine comparison, checks the
 * presence signals, and writes the attendance record. Clients cannot write
 * the `attendance` collection directly (see firestore.rules).
 *
 * Region: asia-south1 (matches Firestore / data-localization, spec §10).
 *
 * Deploy requires the Blaze billing plan (Cloud Functions gen2). If billing is
 * not yet enabled on the project this file is correct but undeployable — see
 * README.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import crypto from "node:crypto";

import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { getAuth } from "firebase-admin/auth";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { setGlobalOptions } from "firebase-functions/v2";
import {
  campusNow, loadSection, isYear3Section, loadScheduleTemplate,
  breakAt, periodAt, periodByNo, resolveVenue, resolveAuthorisedOpeners,
  matchWifiProfile, regenerateDayPlan,
} from "./timetable.js";
import { adaptiveCandidate } from "./adaptive.js";

initializeApp();
// This project's Firestore database is literally named `default`, NOT the
// conventional `(default)`, so it must be named explicitly — a bare
// getFirestore() targets `(default)` and fails with NOT_FOUND. Mirrors
// lib/services/firestore_ref.dart and the "database" key in firebase.json.
const db = getFirestore("default");
setGlobalOptions({ region: "asia-south1", maxInstances: 10 });

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── Config: threshold + model version ──────────────────────────────────────
// Prefer a Firestore `config/model` doc (changeable without redeploy) and fall
// back to the bundled deploy_config.json copy.
const FILE_CONFIG = JSON.parse(
  readFileSync(join(__dirname, "deploy_config.json"), "utf8")
);

async function loadModelConfig() {
  try {
    const snap = await db.doc("config/model").get();
    if (snap.exists) {
      const d = snap.data();
      return {
        threshold:
          Number(d.verification_threshold_FAR_0_1pct ?? d.threshold) ||
          FILE_CONFIG["verification_threshold_FAR_0.1pct"],
        modelVersion: d.model_version || FILE_CONFIG.model_version,
        // §4: OFF unless explicitly enabled. A missing field must mean off.
        adaptiveEnabled: d.adaptive_templates_enabled === true,
        adaptiveThreshold: Number(d.adaptive_threshold) || 0.75,
      };
    }
  } catch (_) {
    /* fall through to bundled file */
  }
  return {
    threshold: FILE_CONFIG["verification_threshold_FAR_0.1pct"],
    modelVersion: FILE_CONFIG.model_version,
    adaptiveEnabled: false,
    adaptiveThreshold: 0.75,
  };
}

// NOTE: there is no longer a section allowlist. Attendance used to be gated on
// `config/pilot.sections` while the build was scoped to one supervised section;
// that gate is gone. Which sections are live is now decided entirely by what
// the coordinator/advisor has assigned via assignStudent — a student with no
// section assigned is rejected as `section_not_assigned` in submitAttendance.
// The `config/pilot` document is dead data and is no longer read.

const NONCE_TTL_MS = 2 * 60 * 1000; // 2 minutes
const GPS_MAX_ACCURACY_M = 100; // beyond this, GPS is too coarse to trust as a sanity check

// ── Helpers ────────────────────────────────────────────────────────────────

function requireAuth(request) {
  const auth = request.auth;
  if (!auth) throw new HttpsError("unauthenticated", "Sign in first.");
  const email = auth.token.email || "";
  if (!/@citchennai\.net$/i.test(email)) {
    throw new HttpsError("permission-denied", "College accounts only.");
  }
  if (!auth.token.email_verified) {
    throw new HttpsError("permission-denied", "Verify your email first.");
  }
  // Student id derived from the token, NOT the client payload (spec §6.2.5).
  const studentId = email.split("@")[0].toUpperCase();
  return { uid: auth.uid, email, studentId };
}

/** Cosine similarity of two equal-length vectors (defensive re-normalization). */
function cosine(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return null;
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  const denom = Math.sqrt(na) * Math.sqrt(nb);
  return denom === 0 ? 0 : dot / denom;
}

/** Great-circle distance in metres (haversine). */
function haversineMeters(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function sha256Hex(input) {
  return crypto.createHash("sha256").update(input).digest("hex");
}

/**
 * Flatten the client's illumination payload into scalar columns on the
 * attendance record, and — when the stored template carries the same stat —
 * the DELTA between them.
 *
 * `probe_vs_enroll_luma_delta` is the field this exists for. A genuine pair can
 * be rejected purely because it was enrolled in one light and verified in
 * another (one measured case: same palm, 0.407 against a 0.5508 threshold), and
 * until now nothing recorded the one variable most likely to explain it. With
 * this stored next to palm_score, the question "do low scores track a lighting
 * difference?" becomes a query over real attendance data instead of a manual
 * reproduction, one attempt at a time.
 *
 * Positive delta = the probe was BRIGHTER than the enrollment. That direction
 * matters: this model family degrades far more under brightening than under
 * darkening.
 *
 * These are MEASUREMENTS of whatever the camera's own auto-exposure settled on.
 * The app deliberately does not drive exposure — two attempts to do so (torch,
 * exposure compensation) both made capture worse; see the note in
 * lib/services/quality_gate.dart.
 *
 * Diagnostic only — nothing here influences the verdict.
 */
function illuminationFields(probeIll, enrollIll) {
  const num = (v) => (typeof v === "number" && isFinite(v) ? v : null);
  const probeMean = num(probeIll?.luma_mean);
  const enrollMean = num(enrollIll?.luma_mean);
  return {
    probe_luma_mean: probeMean,
    probe_luma_std: num(probeIll?.luma_std),
    probe_blowout_mean: num(probeIll?.blowout_mean),
    enroll_luma_mean: enrollMean,
    probe_vs_enroll_luma_delta:
      probeMean !== null && enrollMean !== null ? probeMean - enrollMean : null,
  };
}

/**
 * Same idea as illuminationFields, for palm GEOMETRY.
 *
 * v5's own diagnostic over 3,210 comparisons ranked the geometric nuisance
 * factors: in-plane rotation r=-0.322, out-of-plane tilt r=-0.169. The
 * rotation-aligned crop cancels the first. NOTHING cancels the second — a crop
 * cannot undo foreshortening — which is why a palm presented at a different
 * angle scores lower even under identical lighting (measured: 0.607 angled vs
 * 0.800 square-on, same palm, same room).
 *
 * `probe_vs_enroll_pose_ratio_delta` is the out-of-plane tilt difference and is
 * the field that should correlate with score.
 *
 * `probe_vs_enroll_tilt_delta` is a CONTROL: in-plane rotation is supposed to be
 * cancelled by the v5 crop, so it should show NO correlation. If it does, the
 * rotation alignment is not working and that is a bug, not a nuisance factor.
 *
 * Diagnostic only — nothing here influences the verdict.
 */
function poseFields(probePose, enrollPose) {
  const num = (v) => (typeof v === "number" && isFinite(v) ? v : null);
  const d = (a, b) => (a !== null && b !== null ? a - b : null);
  const pRatio = num(probePose?.pose_ratio_mean);
  const eRatio = num(enrollPose?.pose_ratio_mean);
  const pTilt = num(probePose?.tilt_deg_mean);
  const eTilt = num(enrollPose?.tilt_deg_mean);
  const pSize = num(probePose?.size_mean);
  const eSize = num(enrollPose?.size_mean);
  return {
    probe_pose_ratio: pRatio,
    probe_tilt_deg: pTilt,
    probe_size: pSize,
    enroll_pose_ratio: eRatio,
    probe_vs_enroll_pose_ratio_delta: d(pRatio, eRatio),
    probe_vs_enroll_tilt_delta: d(pTilt, eTilt),
    probe_vs_enroll_size_delta: d(pSize, eSize),
  };
}


// ── Multi-template enrolment ────────────────────────────────────────────────
//
// A student may hold SEVERAL templates, captured under different lighting, and
// verification takes max(cosine(probe, template_i)).
//
// Measured offline on 144 real crops / 18 participants at threshold 0.5508:
//
//   templates   genuine   FRR      impostor   FAR
//       1        0.614    28.7%     0.032     0.00%
//       2        0.680    23.6%     0.061     0.00%
//       3        0.724    11.1%     0.077     0.00%
//
// ~61% fewer false rejects with no measurable rise in false accepts.
//
// THE CATCH, and it is the whole design: that result depends on the templates
// spanning the person's LIGHTING RANGE. In the simulation they did so by
// construction (crops sorted by luma, then split). Three templates captured
// back-to-back in one room are three near-identical vectors and buy nothing.
// The enrolment flow must therefore induce and VERIFY a lighting spread — see
// the client's LightingSpread logic. This function only consumes the result.

/** Minimum embedding entries required before a student counts as enrolled. */
const EMBEDDING_DIM = 256;

/**
 * Every usable template for a student, from EITHER schema shape.
 *
 * Supports the legacy single `embedding` field and the new `embeddings[]`
 * array simultaneously, because 8,000+ students are already enrolled with one
 * template and forcing them all to re-enrol is not acceptable. A student with
 * one template verifies exactly as before — same score, same outcome.
 *
 * Filtering happens HERE so every caller gets the same rules:
 *  - wrong model_version is skipped (never compare across embedding spaces)
 *  - wrong hand_side is skipped (left and right palms are different identities)
 *  - malformed vectors are skipped rather than crashing the comparison
 */
function loadStudentTemplates(student, { modelVersion, handSide }) {
  const out = [];
  const push = (vec, meta, index) => {
    if (!Array.isArray(vec) || vec.length !== EMBEDDING_DIM) return;
    if ((meta.model_version ?? student.model_version) !== modelVersion) return;
    const side = meta.hand_side ?? student.hand_side;
    // Gate hand side PER TEMPLATE, before comparing. A student could in
    // principle hold templates for either hand; scoring a right-hand probe
    // against a left-hand template is meaningless.
    if (side && handSide && side !== handSide) return;
    out.push({
      index,
      vec,
      hand_side: side ?? null,
      enroll_luma_mean:
        typeof meta.enroll_luma_mean === "number" ? meta.enroll_luma_mean : null,
      source: meta.source ?? "enrollment",
    });
  };

  if (Array.isArray(student.embeddings) && student.embeddings.length) {
    student.embeddings.forEach((e, i) => {
      if (!e) return;
      push(e.vec ?? e.embedding, e, i);
    });
  } else if (Array.isArray(student.embedding)) {
    // Legacy shape. Index 0 so `matched_template_index` stays meaningful.
    push(student.embedding, student, 0);
  }
  return out;
}

/**
 * Score a probe against every template and return the BEST, plus the full
 * per-template breakdown.
 *
 * The breakdown is logged deliberately. If one index wins essentially always,
 * the other templates are near-duplicates and the lighting spread that makes
 * multi-template work is NOT happening in the field — which is invisible from
 * the final score alone.
 */
function scoreAgainstTemplates(probe, templates) {
  const per = templates.map((t) => ({
    index: t.index,
    score: cosine(probe, t.vec),
    source: t.source,
    enroll_luma_mean: t.enroll_luma_mean,
  }));
  const valid = per.filter((p) => typeof p.score === "number" && isFinite(p.score));
  if (!valid.length) return { best: null, matchedIndex: null, per };
  const best = valid.reduce((a, b) => (b.score > a.score ? b : a));
  return { best: best.score, matchedIndex: best.index, per };
}

// ── requestNonce ────────────────────────────────────────────────────────────
// Single-use, short-lived token bound to the student; consumed by
// submitAttendance to defeat replay of a captured payload (spec §5.3, §6.2.1).
export const requestNonce = onCall(async (request) => {
  const { studentId } = requireAuth(request);
  const nonce = crypto.randomBytes(24).toString("hex");
  await db.doc(`nonces/${nonce}`).set({
    student_id: studentId,
    created_at: FieldValue.serverTimestamp(),
    expires_at: Timestamp.fromMillis(Date.now() + NONCE_TTL_MS),
    used: false,
  });
  return { nonce, expires_in_ms: NONCE_TTL_MS };
});

// ── submitAttendance ─────────────────────────────────────────────────────────
// Runs the spec §6.2 checks IN ORDER and writes the record with a full
// evidence trail. Returns { status, decision_reason, attendance_id, ... }.
export const submitAttendance = onCall(async (request) => {
  const { uid, studentId } = requireAuth(request);
  const p = request.data || {};
  const {
    session_id,
    nonce,
    probe_embedding,
    hand_side,
    wifi_scan = [],
    gps = null,
    is_mock_location = false,
    device_id = null,
    client_timestamp = null,
    illumination = null,
    pose = null,
  } = p;

  if (!session_id || !nonce || !Array.isArray(probe_embedding)) {
    throw new HttpsError("invalid-argument", "Missing session_id, nonce or probe_embedding.");
  }

  const { threshold, modelVersion, adaptiveEnabled, adaptiveThreshold } =
    await loadModelConfig();
  const now = Timestamp.now();

  // Everything below runs in a transaction so nonce consumption and the
  // duplicate check can't race a second concurrent submission.
  const result = await db.runTransaction(async (tx) => {
    // Evidence accumulators. Populated as each check computes its value, so a
    // rejection at ANY stage still writes whatever was known at that point.
    // Pilot review depends on this: a student reporting "it wouldn't let me
    // in" must leave a record, and early bails (wrong hand, stale model
    // version, no open session) previously wrote nothing at all.
    let evClassroomId = null;
    let evScore = null;
    let evMatched = [];
    let evCampusDistanceM = null;
    // Enrollment illumination, once the student document has been read. Null
    // before that, and on templates enrolled before this was recorded.
    let evEnrollIll = null;
    let evEnrollPose = null;
    // Year-3 venue-resolution evidence. Stays null for years 1/2/4, which never
    // enter that path — so their records keep exactly the shape they had before
    // this build.
    let evPeriodNo = null;
    let evResolvedVenue = null;
    let evWasOd = false;
    let evWasSubstitute = false;
    let evWifiScore = null;
    let evDate = null;
    let evTemplateCount = null;
    let evMatchedIndex = null;
    let evPerTemplate = null;

    /**
     * Reject with a logged evidence record.
     *
     * Defined inside the transaction because it needs `tx`. Firestore requires
     * all reads before writes; every caller returns immediately after this, so
     * no read can follow the write.
     */
    function reject(reason) {
      const ref = db.collection("attendance").doc();
      tx.set(ref, {
        session_id,
        student_id: studentId,
        classroom_id: evClassroomId,
        status: "rejected",
        decision_reason: reason,
        palm_score: evScore,
        palm_threshold_used: threshold,
        model_version: modelVersion,
        probe_embedding_hash: sha256Hex(JSON.stringify(probe_embedding)),
        wifi_matched_bssids: evMatched,
        wifi_match_count: evMatched.length,
        gps_lat: gps?.lat ?? null,
        gps_lng: gps?.lng ?? null,
        gps_accuracy_m: gps?.accuracy_m ?? null,
        gps_campus_distance_m: evCampusDistanceM,
        is_mock_location: !!is_mock_location,
        ...illuminationFields(illumination, evEnrollIll),
        ...poseFields(pose, evEnrollPose),
        period_no: evPeriodNo,
        date: evDate,
        resolved_venue_id: evResolvedVenue,
        was_od: evWasOd,
        was_substitute: evWasSubstitute,
        wifi_match_score: evWifiScore,
      template_count: evTemplateCount,
      matched_template_index: evMatchedIndex,
      per_template_scores: evPerTemplate,
        template_count: evTemplateCount,
        matched_template_index: evMatchedIndex,
        per_template_scores: evPerTemplate,
        // Logged for pilot visibility only — device binding is NOT enforced.
        device_id: device_id ?? null,
        submitted_by_uid: uid,
        server_timestamp: FieldValue.serverTimestamp(),
        client_timestamp: client_timestamp ?? null,
      });
      return {
        status: "rejected",
        decision_reason: reason,
        attendance_id: ref.id,
        palm_score: evScore,
        palm_threshold_used: threshold,
        wifi_match_count: evMatched.length,
      };
    }

    // 1. Nonce valid, unused, unexpired, and belongs to this student.
    const nonceRef = db.doc(`nonces/${nonce}`);
    const nonceSnap = await tx.get(nonceRef);
    if (!nonceSnap.exists) return reject("invalid_nonce");
    const n = nonceSnap.data();
    if (n.used || n.student_id !== studentId || n.expires_at.toMillis() < Date.now()) {
      return reject("invalid_nonce");
    }

    // 2. Session open, within window, section matches the student.
    const sessSnap = await tx.get(db.doc(`attendance_sessions/${session_id}`));
    if (!sessSnap.exists) return reject("outside_session");
    const sess = sessSnap.data();
    const openNow =
      sess.status === "open" &&
      sess.opened_at.toMillis() <= Date.now() &&
      sess.closes_at.toMillis() >= Date.now();
    if (!openNow) return reject("outside_session");

    // Student profile (id from auth, never from payload).
    const studentSnap = await tx.get(db.doc(`students/${studentId}`));
    if (!studentSnap.exists) return reject("not_enrolled");
    const student = studentSnap.data();
    // Captured as soon as the template is in hand, so every rejection from here
    // on — including ones that never reach the palm comparison — still records
    // the enrollment-vs-probe lighting delta.
    evEnrollIll = student.enroll_illumination ?? null;
    evEnrollPose = student.enroll_pose ?? null;

    // ── YEAR GATE ─────────────────────────────────────────────────────────
    // Everything new in this build hangs off `year3` being true. The section
    // document is the ONLY place a year is established, and anything that does
    // not resolve to an explicit year 3 — unknown section, missing year, years
    // 1/2/4 — keeps the pre-existing behaviour untouched. The new logic is
    // opt-in, never a default, which is what makes the other years unreachable
    // from here rather than merely untested.
    const sectionId = student.section || sess.section || null;
    const section = await loadSection(db, sectionId);
    const year3 = isYear3Section(section);

    // Known as soon as we have the session + student, so every rejection from
    // here on records which room it was for. For year 3 this is REPLACED below
    // by the resolved venue — `assigned_classroom` is not authoritative there.
    evClassroomId = sess.classroom_id || student.assigned_classroom || null;

    let venue = null;
    if (year3) {
      const clock = campusNow();
      evDate = clock.date;

      const template = await loadScheduleTemplate(db, section.year);
      if (!template) return reject("schedule_not_configured");

      // Break enforcement, per year, on SERVER time. Breaks differ by year, so
      // two sections in the same building can legitimately be in different
      // states at the same moment — there is deliberately no global window.
      if (breakAt(template, clock.minutes)) return reject("during_break");

      // The period is taken from the SESSION the staff member opened, not from
      // the wall clock and never from the client: the 5-minute student window
      // can legitimately run past the end of its period.
      const periodNo = sess.period_no ?? periodAt(template, clock.minutes)?.no ?? null;
      if (periodNo == null) return reject("outside_session");
      evPeriodNo = periodNo;

      venue = await resolveVenue(
        db,
        { sectionId, date: evDate, periodNo, studentId, weekday: clock.weekday },
        tx
      );
      // No silent fallback to a default room: validating a student against the
      // Wi-Fi of a room the class is not in, invisibly, is the exact failure
      // this rule exists to prevent.
      if (!venue) return reject("venue_not_resolved");

      evResolvedVenue = venue.venueId;
      evWasOd = venue.wasOd;
      evWasSubstitute = !!sess.was_substitute;
      evClassroomId = venue.venueId;
    }

    // A roster-only record (advisor added them but they haven't enrolled) or
    // one whose biometrics were erased still has section/classroom but no
    // embedding. Report that plainly instead of falling through to a cosine
    // against undefined, which would surface as the opaque "bad_embedding".
    const hasLegacy =
      Array.isArray(student.embedding) && student.embedding.length === EMBEDDING_DIM;
    const hasArray =
      Array.isArray(student.embeddings) && student.embeddings.length > 0;
    if (!hasLegacy && !hasArray) {
      return reject("not_enrolled");
    }

    // 2b. Model version gate. v4 changed the embedding space, so a template
    // enrolled under any earlier model is not comparable to a v4 probe —
    // scoring it would produce a meaningless number that could land either
    // side of the threshold. Treat it as not-enrolled so the student is
    // prompted to re-enroll instead.
    // With embeddings[] the model_version lives PER TEMPLATE, so the gate moves
    // into loadStudentTemplates: it drops any template from another embedding
    // space and keeps the rest. Only when that leaves nothing usable is this a
    // version mismatch. The legacy single-embedding path is unchanged, because
    // there the doc-level model_version is the template's model_version.
    if (hasLegacy && !hasArray && student.model_version !== modelVersion) {
      return reject("model_version_mismatch");
    }

    // 2c. The student must actually be on a roster. There is no section
    // allowlist any more — the coordinator/advisor assigning a class IS the
    // gate. That makes this check load-bearing: without it a student whose
    // profile has no section would fall through the mismatch test below (which
    // short-circuits on a null section) and be accepted into ANY open session.
    if (!student.section) {
      return reject("section_not_assigned");
    }

    if (sess.section && student.section !== sess.section) {
      return reject("outside_session");
    }

    // 3. Device binding — DELIBERATELY NOT ENFORCED IN THIS PILOT BUILD.
    //
    // `device_id` is still collected and written to the attendance record
    // (useful pilot data: it shows whether one handset is submitting for many
    // students), but it does NOT gate accept/reject. The active layers for
    // this pilot are palm + Wi-Fi fingerprint + session window.
    //
    // This is a temporary, intentional relaxation for pilot simplicity — NOT
    // an oversight. Re-enabling a bound-device check is a candidate before any
    // wider rollout; if you do, note that `bound_device_id` is not
    // student-writable (see firestore.rules) precisely so the binding cannot
    // be reassigned from a handset.

    // 4. Duplicate — only a prior PRESENT mark blocks a resubmission. A
    // rejected attempt (wifi mismatch, palm below threshold, expired nonce,
    // etc.) must NOT lock the student out of the session for good — only a
    // genuinely completed attendance should. Without the status filter here,
    // one bad Wi-Fi read on attempt 1 would permanently prevent attempt 2 from
    // ever succeeding, because *a* record for (session, student) already
    // existed regardless of its outcome.
    const dupSnap = await tx.get(
      db.collection("attendance")
        .where("session_id", "==", session_id)
        .where("student_id", "==", studentId)
        .where("status", "==", "present")
        .limit(1)
    );
    if (!dupSnap.empty) return reject("duplicate");

    // 5. Palm — MAX over the student's templates.
    //
    // hand_side is gated per template inside loadStudentTemplates, before any
    // comparison, so a right-hand probe is never scored against a left-hand
    // template. If that filter removes everything but the student does hold
    // templates, the cause is the hand, not enrolment — report it as such
    // rather than as a generic failure.
    const templates = loadStudentTemplates(student, {
      modelVersion,
      handSide: hand_side,
    });
    if (!templates.length) {
      const anyIgnoringHand = loadStudentTemplates(student, {
        modelVersion,
        handSide: null,
      });
      if (anyIgnoringHand.length) return reject("hand_side_mismatch");
      return reject("model_version_mismatch");
    }

    const scored = scoreAgainstTemplates(probe_embedding, templates);
    const score = scored.best;
    evScore = score;
    evTemplateCount = templates.length;
    evMatchedIndex = scored.matchedIndex;
    // Per-template scores are logged for a specific diagnostic: if one index
    // wins essentially every time, the other templates are near-duplicates and
    // the lighting spread multi-template depends on is NOT happening in the
    // field. That is invisible from the final score alone.
    evPerTemplate = scored.per;
    if (score === null) return reject("bad_embedding");
    const palmOk = score >= threshold;

    // 6. Wi-Fi fingerprint — ≥ min_bssid_matches of the classroom's BSSIDs.
    const classroomId = evClassroomId;
    const roomSnap = classroomId
      ? await tx.get(db.doc(`classrooms/${classroomId}`))
      : null;
    if (!roomSnap || !roomSnap.exists) return reject("classroom_not_configured");
    const room = roomSnap.data();
    let matched;
    let wifiOk;
    if (year3) {
      // RSSI-RANKED PROFILE match. Roof-mounted routers and ~7x6x3 m rooms mean
      // adjacent rooms see nearly the same APs at nearly the same strength, so
      // set overlap alone cannot separate 301 from 302. The score is recorded on
      // every attempt — pass or fail — so rssi_tolerance can be tuned from real
      // data instead of guessed.
      const prof = matchWifiProfile(room.wifi_fingerprint, wifi_scan, {
        rssi_tolerance: room.rssi_tolerance,
        min_bssid_matches: room.min_bssid_matches,
        top_n: room.wifi_top_n,
      });
      if (prof.registeredCount === 0) return reject("classroom_not_configured");
      matched = prof.matched;
      evMatched = matched;
      evWifiScore = prof.score;
      wifiOk = prof.ok;
    } else {
      const registered = new Set(
        (room.wifi_fingerprint || []).map((a) => String(a.bssid).toLowerCase())
      );
      const scanned = new Set(
        (wifi_scan || []).map((a) => String(a.bssid || "").toLowerCase())
      );
      matched = [...registered].filter((b) => scanned.has(b));
      evMatched = matched;
      const minMatches = room.min_bssid_matches ?? 2;
      if (registered.size === 0) return reject("classroom_not_configured");
      wifiOk = matched.length >= minMatches;
    }

    // 7. GPS coarse campus check (generous radius, sanity only).
    let campusDistanceM = null;
    let gpsOk = true;
    if (room.latitude != null && room.longitude != null && gps &&
        gps.lat != null && gps.lng != null) {
      campusDistanceM = haversineMeters(gps.lat, gps.lng, room.latitude, room.longitude);
      evCampusDistanceM = campusDistanceM;
      const accuracyOk = (gps.accuracy_m ?? 9999) <= GPS_MAX_ACCURACY_M;
      gpsOk = campusDistanceM <= (room.campus_radius_m ?? 300) && accuracyOk;
    }

    // Decide. Order of reasons mirrors the check order so the first failing
    // gate is the reported reason.
    let status = "present";
    let reason = "ok";
    if (!palmOk) { status = "rejected"; reason = "palm_below_threshold"; }
    else if (!wifiOk) { status = "rejected"; reason = "wifi_mismatch"; }
    else if (!gpsOk) { status = "rejected"; reason = "gps_out_of_campus"; }

    // Consume the nonce regardless of outcome (single-use).
    tx.update(nonceRef, { used: true, used_at: now });

    // NOTE: no device binding is written here. Trust-on-first-use binding was
    // removed for the pilot along with the bound-device check (see check 3) —
    // recording a binding we never enforce would be misleading, and would
    // silently start rejecting students the moment the check is re-enabled.
    // `device_id` is still logged on the record below for pilot review.

    // 8b. §4 ADAPTIVE TEMPLATE ADDITION — off unless explicitly enabled.
    //
    // Only a verification that cleared the HIGH bar (0.75, well above the 0.5508
    // verification threshold) and that adds genuinely new lighting coverage is
    // kept. The gap between the two thresholds is what stops a false accept
    // writing an impostor's palm into this student's template set — close it
    // and the feature becomes an attack.
    //
    // Written inside the same transaction as the attendance record so a
    // half-applied state is impossible.
    if (status === "present") {
      const candidate = adaptiveCandidate({
        enabled: adaptiveEnabled,
        score,
        adaptiveThreshold,
        verifyThreshold: threshold,
        templates: Array.isArray(student.embeddings) ? student.embeddings : [],
        probeEmbedding: probe_embedding,
        probeLuma:
          illumination && typeof illumination.luma_mean === "number"
            ? illumination.luma_mean
            : null,
        handSide: hand_side ?? student.hand_side,
        modelVersion,
      });
      if (candidate) {
        const base = Array.isArray(student.embeddings) ? student.embeddings : [];
        tx.set(
          db.doc(`students/${studentId}`),
          {
            embeddings: [...base, candidate],
            embedding_count: base.length + 1,
            updated_at: new Date().toISOString(),
          },
          { merge: true }
        );
      }
    }

    // 9. Write the record with the full evidence trail (spec §8).
    const attendanceRef = db.collection("attendance").doc();
    tx.set(attendanceRef, {
      session_id,
      student_id: studentId,
      classroom_id: classroomId,
      status,
      decision_reason: reason,
      palm_score: score,
      palm_threshold_used: threshold,
      model_version: modelVersion,
      probe_embedding_hash: sha256Hex(JSON.stringify(probe_embedding)),
      wifi_matched_bssids: matched,
      wifi_match_count: matched.length,
      gps_lat: gps?.lat ?? null,
      gps_lng: gps?.lng ?? null,
      gps_accuracy_m: gps?.accuracy_m ?? null,
      gps_campus_distance_m: campusDistanceM,
      is_mock_location: !!is_mock_location,
      ...illuminationFields(illumination, evEnrollIll),
      ...poseFields(pose, evEnrollPose),
      period_no: evPeriodNo,
      date: evDate,
      resolved_venue_id: evResolvedVenue,
      was_od: evWasOd,
      was_substitute: evWasSubstitute,
      wifi_match_score: evWifiScore,
      device_id: device_id ?? null,
      submitted_by_uid: uid,
      server_timestamp: FieldValue.serverTimestamp(),
      client_timestamp: client_timestamp ?? null,
    });

    return {
      status,
      decision_reason: reason,
      attendance_id: attendanceRef.id,
      palm_score: score,
      palm_threshold_used: threshold,
      wifi_match_count: matched.length,
    };
  });

  return result;
});

// ── Staff roster management ──────────────────────────────────────────────────
//
// Advisors add students to their section by email. The roster fields
// (section, assigned_classroom) are NOT student-writable — that's the whole
// point of the presence layer — so they're written here with the Admin SDK.
//
// "Verification" is delivered by the Firebase "Trigger Email from Firestore"
// extension: this function writes a doc to the `mail/` collection and the
// extension sends it via the configured SMTP. If the extension isn't installed
// yet the assignment still succeeds and the mail doc simply waits.

const APP_NAME = "PalmPay Attendance";

/** Load the caller's staff profile, or throw if they're not staff. */
async function requireStaff(request) {
  const { uid } = requireAuth(request);
  const snap = await db.doc(`staff/${uid}`).get();
  if (!snap.exists) {
    throw new HttpsError("permission-denied", "Staff only.");
  }
  return { uid, staff: snap.data() };
}

function queueMail(to, subject, html) {
  // Document shape expected by the Trigger Email extension (default config).
  return db.collection("mail").add({
    to: [to],
    message: { subject, html },
    _meta: { app: APP_NAME, queued_at: FieldValue.serverTimestamp() },
  });
}

/**
 * assignStudent — advisor/admin adds a student to a section by email.
 *
 * data: { student_email, section, assigned_classroom? }
 *
 * - Advisor may only assign to a section they own; admin may assign to any.
 * - Ensures the student's Auth account exists (creates it with a random
 *   password if not — the student sets their own via the emailed link).
 * - Writes section + assigned_classroom to students/{id} (merge; never
 *   touches the biometric fields).
 * - Emails the student:
 *     · a PASSWORD-SETUP link for a brand-new account (setting the password
 *       via that link also marks the email verified in one step), or
 *     · a VERIFICATION link for an existing but unverified account.
 *   Already-verified accounts get no email.
 */
export const assignStudent = onCall(async (request) => {
  const { uid, staff } = await requireStaff(request);
  const { student_email, section, assigned_classroom = null } = request.data || {};

  if (!student_email || !section) {
    throw new HttpsError("invalid-argument", "student_email and section are required.");
  }
  const email = String(student_email).trim().toLowerCase();
  if (!/@citchennai\.net$/i.test(email)) {
    throw new HttpsError("invalid-argument", "Student email must be @citchennai.net.");
  }

  // Advisors are scoped to their own sections; admins may assign anywhere.
  const isAdmin = staff.role === "admin";
  const ownsSection = Array.isArray(staff.sections) && staff.sections.includes(section);
  if (!isAdmin && !ownsSection) {
    throw new HttpsError("permission-denied", `You don't advise section ${section}.`);
  }

  const studentId = email.split("@")[0].toUpperCase();

  // Ensure the Auth account exists.
  let authUser = null;
  let createdNow = false;
  try {
    authUser = await getAuth().getUserByEmail(email);
  } catch (e) {
    if (e.code === "auth/user-not-found") {
      authUser = await getAuth().createUser({
        email,
        emailVerified: false,
        password: crypto.randomBytes(18).toString("base64url"), // random; student resets
      });
      createdNow = true;
    } else {
      throw new HttpsError("internal", `Auth lookup failed: ${e.message}`);
    }
  }

  // Write roster fields (Admin SDK bypasses the field-level student rules).
  //
  // created_at MUST be an ISO string, not a Firestore Timestamp: the Dart
  // client and isWellFormedStudent() in firestore.rules both require
  // `created_at is string`. Writing it as FieldValue.serverTimestamp() (a
  // Timestamp) silently and PERMANENTLY blocked every later student write to
  // that doc — isWellFormedStudent checks the type of the FINAL merged
  // document on every write, so even a no-op update on an unrelated field
  // failed with permission-denied once created_at had the wrong type.
  //
  // Only set created_at if this student doc doesn't exist yet — otherwise a
  // second roster edit would reset it.
  const studentRef = db.doc(`students/${studentId}`);
  const existingStudentSnap = await studentRef.get();
  await studentRef.set(
    {
      student_id: studentId,
      section,
      assigned_classroom: assigned_classroom,
      roster_email: email,
      roster_assigned_by: uid,
      roster_assigned_at: FieldValue.serverTimestamp(),
      ...(existingStudentSnap.exists ? {} : { created_at: new Date().toISOString() }),
    },
    { merge: true }
  );

  // Send the appropriate email (best-effort — requires the Trigger Email
  // extension + SMTP; if absent, the mail doc just waits in `mail/`).
  let emailKind = "none";
  try {
    if (createdNow) {
      const link = await getAuth().generatePasswordResetLink(email);
      emailKind = "password_setup";
      await queueMail(
        email,
        `Set up your ${APP_NAME} account`,
        `<p>Your advisor added you to section <b>${section}</b> for ${APP_NAME}.</p>
         <p>Set your password to activate your account (this also verifies your email):</p>
         <p><a href="${link}">Set my password</a></p>`
      );
    } else if (!authUser.emailVerified) {
      const link = await getAuth().generateEmailVerificationLink(email);
      emailKind = "verification";
      await queueMail(
        email,
        `Verify your ${APP_NAME} email`,
        `<p>Your advisor added you to section <b>${section}</b> for ${APP_NAME}.</p>
         <p>Verify your email to activate your account:</p>
         <p><a href="${link}">Verify my email</a></p>`
      );
    }
  } catch (e) {
    // Don't fail the assignment just because the mail couldn't be queued.
    console.error(`assignStudent: mail step failed for ${email}: ${e.message}`);
    emailKind = "failed";
  }

  return {
    student_id: studentId,
    section,
    assigned_classroom,
    account_created: createdNow,
    email_verified: !!authUser.emailVerified,
    email_sent: emailKind, // password_setup | verification | none | failed
  };
});

/**
 * listSectionRoster — the live roster for a section, with each student's
 * current verified status pulled from Auth (which the advisor's client cannot
 * read directly). data: { section }.
 */
export const listSectionRoster = onCall(async (request) => {
  const { staff } = await requireStaff(request);
  const { section } = request.data || {};
  if (!section) throw new HttpsError("invalid-argument", "section is required.");

  const isAdmin = staff.role === "admin";
  const ownsSection = Array.isArray(staff.sections) && staff.sections.includes(section);
  if (!isAdmin && !ownsSection) {
    throw new HttpsError("permission-denied", `You don't advise section ${section}.`);
  }

  const snap = await db.collection("students").where("section", "==", section).get();
  const roster = await Promise.all(
    snap.docs.map(async (d) => {
      const s = d.data();
      const email = s.roster_email || null;
      let verified = false;
      let accountExists = false;
      if (email) {
        try {
          const u = await getAuth().getUserByEmail(email);
          verified = u.emailVerified;
          accountExists = true;
        } catch (_) {
          accountExists = false;
        }
      }
      return {
        student_id: d.id,
        email,
        section: s.section || null,
        assigned_classroom: s.assigned_classroom || null,
        // Either schema shape counts as enrolled — a legacy single-template
        // student must never show as "not enrolled" just because the field
        // moved.
        enrolled:
          (Array.isArray(s.embedding) && s.embedding.length === EMBEDDING_DIM) ||
          (Array.isArray(s.embeddings) && s.embeddings.length > 0),
        template_count: Array.isArray(s.embeddings)
          ? s.embeddings.length
          : (Array.isArray(s.embedding) && s.embedding.length === EMBEDDING_DIM ? 1 : 0),
        account_exists: accountExists,
        email_verified: verified,
      };
    })
  );

  roster.sort((a, b) => a.student_id.localeCompare(b.student_id));
  return { section, count: roster.length, roster };
});

// ── Advisor provisioning (coordinator-only) ──────────────────────────────────
//
// A coordinator adds an advisor by email from inside the app; there is no
// manual "look up their Auth UID and edit staff/{uid} by hand" step. This is
// the same pattern as assignStudent above, one level up the hierarchy:
// staff/* is not client-writable (firestore.rules), so these two functions —
// running with the Admin SDK — are the ONLY way an advisor gets provisioned
// once the first coordinator/admin exists (that bootstrap step still goes
// through the seed script or the Firebase console; see functions/seed).

/** Load the caller's staff profile, or throw if they're not a coordinator. */
async function requireCoordinator(request) {
  const { uid } = requireAuth(request);
  const snap = await db.doc(`staff/${uid}`).get();
  if (!snap.exists || snap.data().role !== "coordinator") {
    throw new HttpsError("permission-denied", "Coordinators only.");
  }
  return { uid, staff: snap.data() };
}

/**
 * assignAdvisor — coordinator adds (or extends) an advisor by email.
 *
 * data: { advisor_email, sections: string[], classroom_id? }
 *
 * - Ensures the advisor's Auth account exists (creates it with a random
 *   password if not — they set their own via the emailed link).
 * - Merges `role: 'advisor'` and the given sections into staff/{uid}. Sections
 *   are UNIONED with whatever that advisor already owns, never replaced, and
 *   an existing coordinator/admin is never downgraded to plain advisor.
 * - Emails the advisor a password-setup (new account) or verification
 *   (existing, unverified account) link, same as assignStudent.
 */
export const assignAdvisor = onCall(async (request) => {
  const { uid: coordinatorUid } = await requireCoordinator(request);
  const { advisor_email, sections, classroom_id = null } = request.data || {};

  const email = String(advisor_email || "").trim().toLowerCase();
  if (!email || !/@citchennai\.net$/i.test(email)) {
    throw new HttpsError("invalid-argument", "Advisor email must be @citchennai.net.");
  }
  const sectionList = Array.isArray(sections)
    ? [...new Set(sections.map((s) => String(s).trim()).filter(Boolean))]
    : [];
  if (sectionList.length === 0) {
    throw new HttpsError("invalid-argument", "At least one section is required.");
  }

  // Ensure the Auth account exists.
  let authUser = null;
  let createdNow = false;
  try {
    authUser = await getAuth().getUserByEmail(email);
  } catch (e) {
    if (e.code === "auth/user-not-found") {
      authUser = await getAuth().createUser({
        email,
        emailVerified: false,
        password: crypto.randomBytes(18).toString("base64url"), // random; advisor resets
      });
      createdNow = true;
    } else {
      throw new HttpsError("internal", `Auth lookup failed: ${e.message}`);
    }
  }

  const staffRef = db.doc(`staff/${authUser.uid}`);
  const existingSnap = await staffRef.get();
  const existing = existingSnap.exists ? existingSnap.data() : null;
  const mergedSections = [...new Set([...(existing?.sections || []), ...sectionList])];
  const role =
    existing && ["coordinator", "admin"].includes(existing.role) ? existing.role : "advisor";

  await staffRef.set(
    {
      uid: authUser.uid,
      email,
      staff_id: email.split("@")[0].toUpperCase(),
      role,
      sections: mergedSections,
      // Convenience mirror of the first section — SessionService reads a
      // single `section` when opening a session.
      section: mergedSections[0] || null,
      classroom_id: classroom_id ?? existing?.classroom_id ?? null,
      added_by: coordinatorUid,
      updated_at: FieldValue.serverTimestamp(),
      ...(existingSnap.exists ? {} : { created_at: FieldValue.serverTimestamp() }),
    },
    { merge: true }
  );

  // Send the appropriate email (best-effort — requires the Trigger Email
  // extension + SMTP; if absent, the mail doc just waits in `mail/`).
  let emailKind = "none";
  try {
    if (createdNow) {
      const link = await getAuth().generatePasswordResetLink(email);
      emailKind = "password_setup";
      await queueMail(
        email,
        `You've been added as an advisor — ${APP_NAME}`,
        `<p>You've been added as an advisor for section(s) <b>${mergedSections.join(", ")}</b> on ${APP_NAME}.</p>
         <p>Set your password to activate your account (this also verifies your email):</p>
         <p><a href="${link}">Set my password</a></p>`
      );
    } else if (!authUser.emailVerified) {
      const link = await getAuth().generateEmailVerificationLink(email);
      emailKind = "verification";
      await queueMail(
        email,
        `Verify your ${APP_NAME} email`,
        `<p>You've been added as an advisor for section(s) <b>${mergedSections.join(", ")}</b> on ${APP_NAME}.</p>
         <p>Verify your email to activate your account:</p>
         <p><a href="${link}">Verify my email</a></p>`
      );
    }
  } catch (e) {
    console.error(`assignAdvisor: mail step failed for ${email}: ${e.message}`);
    emailKind = "failed";
  }

  return {
    uid: authUser.uid,
    email,
    role,
    sections: mergedSections,
    account_created: createdNow,
    email_verified: !!authUser.emailVerified,
    email_sent: emailKind, // password_setup | verification | none | failed
  };
});

/**
 * listAdvisors — coordinator-only view of every advisor/admin staff doc, with
 * live email-verification status pulled from Auth (which the client cannot
 * read directly). This is the "list only available to coordinators".
 */
export const listAdvisors = onCall(async (request) => {
  await requireCoordinator(request);

  const snap = await db.collection("staff").where("role", "in", ["advisor", "admin"]).get();

  const advisors = await Promise.all(
    snap.docs.map(async (d) => {
      const s = d.data();
      let verified = false;
      try {
        const u = await getAuth().getUser(d.id);
        verified = u.emailVerified;
      } catch (_) {
        verified = false;
      }
      return {
        uid: d.id,
        email: s.email || null,
        role: s.role || "advisor",
        sections: s.sections || [],
        classroom_id: s.classroom_id || null,
        email_verified: verified,
      };
    })
  );

  advisors.sort((a, b) => (a.email || "").localeCompare(b.email || ""));
  return { count: advisors.length, advisors };
});

// ── openSession ──────────────────────────────────────────────────────────────
// YEAR 3 ONLY. Session opening for years 1/2/4 keeps whatever mechanism exists
// today (client-created sessions under firestore.rules); this function is an
// additional path, not a replacement for theirs.
//
// The staff member palm-verifies, and THAT is what opens the 5-minute window
// students may mark within. So the session's life is anchored to a verified
// human being physically present at the start of it, not to a wall clock.
export const openSession = onCall(async (request) => {
  const { uid } = requireAuth(request);
  const { section_id, period_no, probe_embedding, hand_side, date: clientDate } = request.data || {};

  if (!section_id || period_no == null || !Array.isArray(probe_embedding)) {
    throw new HttpsError("invalid-argument", "Missing section_id, period_no or probe_embedding.");
  }

  const section = await loadSection(db, section_id);
  if (!isYear3Section(section)) {
    // Deliberate: this endpoint does not exist for other years. Sending them
    // down it would be exactly the ungated rollout the brief forbids.
    throw new HttpsError("failed-precondition", "Palm-verified opening is year-3 only.");
  }

  const clock = campusNow();
  // Server date always wins; clientDate is accepted only as a mismatch signal.
  const date = clock.date;
  if (clientDate && clientDate !== date) {
    console.warn(`openSession: client date ${clientDate} != server ${date} (uid ${uid})`);
  }

  const template = await loadScheduleTemplate(db, section.year);
  if (!template) throw new HttpsError("failed-precondition", "No schedule template for this year.");

  // Opening is blocked during that year's breaks, same as marking.
  if (breakAt(template, clock.minutes)) {
    throw new HttpsError("failed-precondition", "during_break");
  }
  const period = periodByNo(template, period_no);
  if (!period) throw new HttpsError("invalid-argument", "Unknown period for this year.");

  // 1. AUTHORISATION — timetabled staff, the section's advisor, or the recorded
  //    substitute. Anyone else is refused before their palm is even compared.
  const { openers, substituteUid } = await resolveAuthorisedOpeners(db, {
    sectionId: section_id, date, periodNo: period_no, weekday: clock.weekday, section,
  });
  if (!openers.has(uid)) {
    throw new HttpsError("permission-denied", "not_authorised_for_period");
  }

  // 2. STAFF PALM — 1:1 against staff/{uid}.palm, server-side, same threshold
  //    and same model-version gate as students. The phone never decides.
  const staffSnap = await db.doc(`staff/${uid}`).get();
  const staff = staffSnap.exists ? staffSnap.data() : null;
  const palm = staff?.palm;
  if (!palm || !Array.isArray(palm.embedding) || palm.embedding.length !== 256) {
    throw new HttpsError("failed-precondition", "staff_not_enrolled");
  }
  const { threshold, modelVersion } = await loadModelConfig();
  if (palm.model_version !== modelVersion) {
    throw new HttpsError("failed-precondition", "model_version_mismatch");
  }
  if (palm.hand_side && hand_side && palm.hand_side !== hand_side) {
    throw new HttpsError("failed-precondition", "hand_side_mismatch");
  }
  const score = cosine(probe_embedding, palm.embedding);
  if (score === null) throw new HttpsError("invalid-argument", "bad_embedding");
  if (score < threshold) {
    // Logged so a staff member repeatedly unable to open is diagnosable rather
    // than just stuck. See issue.md: genuine pairs lose ~0.2 cosine to lighting
    // and palm angle against a 0.077 margin, so this WILL happen to real staff.
    console.warn(`openSession: staff palm below threshold uid=${uid} score=${score} thr=${threshold}`);
    throw new HttpsError("permission-denied", "palm_below_threshold");
  }

  // 3. RESOLVED venue — the same resolution students will be checked against,
  //    so the fingerprint compared is automatically the room the class is in.
  const venue = await resolveVenue(db, {
    sectionId: section_id, date, periodNo: period_no, studentId: null, weekday: clock.weekday,
  });
  if (!venue) throw new HttpsError("failed-precondition", "venue_not_resolved");

  const room = await db.doc(`classrooms/${venue.venueId}`).get();
  if (!room.exists || !(room.data().wifi_fingerprint || []).length) {
    // A venue with no fingerprint would fail every student in the room.
    throw new HttpsError("failed-precondition", "venue_not_fingerprinted");
  }

  const windowMin = Number(template.student_window_minutes ?? 5);
  const now = Timestamp.now();
  const closesAt = Timestamp.fromMillis(now.toMillis() + windowMin * 60000);

  // One session per (section, date, period) — a deterministic id makes a
  // double-tap idempotent instead of opening two overlapping windows.
  const sessionId = `${section_id}_${date}_P${period_no}`;
  await db.doc(`attendance_sessions/${sessionId}`).set({
    session_id: sessionId,
    section: section_id,
    section_id,
    date,
    period_no,
    classroom_id: venue.venueId,
    resolved_venue_id: venue.venueId,
    venue_source: venue.source,
    // advisor_id kept for the existing rules/queries that still read it.
    advisor_id: uid,
    opened_by_uid: uid,
    opened_via_palm: true,
    was_substitute: substituteUid === uid,
    opened_at: now,
    closes_at: closesAt,
    status: "open",
    year: section.year,
  }, { merge: true });

  return {
    session_id: sessionId,
    period_no,
    date,
    resolved_venue_id: venue.venueId,
    venue_source: venue.source,
    closes_at_ms: closesAt.toMillis(),
    window_minutes: windowMin,
    staff_palm_score: score,
  };
});

// ── getDayPlan ───────────────────────────────────────────────────────────────
// ONE small document per section per day (§3). The client caches it and, on
// reconnect, sends only `known_version` — a hit returns {changed:false} and
// nothing else, which is the whole point on a bad connection.
//
// NEVER returns wifi_fingerprint: fingerprints are matching secrets, and
// shipping them both bloats the payload and hands an attacker the target.
export const getDayPlan = onCall(async (request) => {
  requireAuth(request);
  const { section_id, date: reqDate, known_version } = request.data || {};
  if (!section_id) throw new HttpsError("invalid-argument", "Missing section_id.");

  const section = await loadSection(db, section_id);
  if (!isYear3Section(section)) {
    throw new HttpsError("failed-precondition", "Day plans are year-3 only.");
  }
  const date = reqDate || campusNow().date;

  const ref = db.doc(`day_plans/${section_id}_${date}`);
  let snap = await ref.get();
  if (!snap.exists) {
    const built = await regenerateDayPlan(db, { sectionId: section_id, date });
    if (!built) throw new HttpsError("failed-precondition", "Cannot build a day plan for this section.");
    snap = await ref.get();
  }
  const plan = snap.data();

  if (known_version != null && Number(known_version) === Number(plan.version)) {
    return { changed: false, version: plan.version };
  }
  return { changed: true, plan };
});

// ── §7 ROLE SCOPING ──────────────────────────────────────────────────────────
// Enforced HERE and in firestore.rules — never in the UI alone.
//
//   ADVISOR      own assigned section(s) only
//   COORDINATOR  every section in their assigned YEAR
//   HOD          all years, all sections
//
// Roles live on staff/{uid}.role and are designated by the web console. This is
// the single place that judgement is made, so a new endpoint cannot quietly
// invent its own weaker rule.
async function requireSectionAuthority(request, sectionId, { allow = ["advisor", "coordinator", "hod"] } = {}) {
  const { uid } = requireAuth(request);
  const snap = await db.doc(`staff/${uid}`).get();
  if (!snap.exists) throw new HttpsError("permission-denied", "Staff only.");
  const staff = snap.data();
  const role = staff.role;
  if (!allow.includes(role)) {
    throw new HttpsError("permission-denied", `Requires one of: ${allow.join(", ")}.`);
  }

  const section = await loadSection(db, sectionId);
  if (!section) throw new HttpsError("not-found", `Unknown section ${sectionId}.`);
  // The year gate applies to authority too: this build grants no new powers
  // over years 1/2/4, so even an HOD cannot drive these endpoints outside
  // year 3.
  if (!isYear3Section(section)) {
    throw new HttpsError("failed-precondition", "This build manages year-3 sections only.");
  }

  if (role === "hod") return { uid, staff, section };
  if (role === "coordinator") {
    if (Number(staff.coordinator_of_year) !== Number(section.year)) {
      throw new HttpsError("permission-denied", "Not your year.");
    }
    return { uid, staff, section };
  }
  // advisor
  const owns =
    (Array.isArray(staff.advisor_of) && staff.advisor_of.includes(sectionId)) ||
    section.advisor_uid === uid;
  if (!owns) throw new HttpsError("permission-denied", "Not your section.");
  return { uid, staff, section };
}

/** A venue may only be targeted if it is fingerprinted — otherwise every student in it fails. */
async function requireFingerprintedVenue(venueId) {
  const snap = await db.doc(`classrooms/${venueId}`).get();
  if (!snap.exists) throw new HttpsError("not-found", `Unknown venue ${venueId}.`);
  const fp = snap.data().wifi_fingerprint;
  if (!Array.isArray(fp) || fp.length === 0) {
    throw new HttpsError("failed-precondition", "venue_not_fingerprinted");
  }
  return snap.data();
}

// ── setVenueOverride (req 1) ─────────────────────────────────────────────────
export const setVenueOverride = onCall(async (request) => {
  const { section_id, date, period_no, venue_id, reason, clear } = request.data || {};
  if (!section_id || !date || period_no == null) {
    throw new HttpsError("invalid-argument", "Missing section_id, date or period_no.");
  }
  const { uid } = await requireSectionAuthority(request, section_id);
  const ref = db.doc(`venue_overrides/${section_id}_${date}_${period_no}`);

  if (clear) {
    await ref.delete();
  } else {
    if (!venue_id) throw new HttpsError("invalid-argument", "Missing venue_id.");
    await requireFingerprintedVenue(venue_id);
    await ref.set({
      section_id, date, period_no: Number(period_no), venue_id,
      reason: reason ?? null, set_by_uid: uid, set_at: new Date().toISOString(),
    });
  }
  const plan = await regenerateDayPlan(db, { sectionId: section_id, date });
  return { ok: true, day_plan_version: plan?.version ?? null };
});

// ── setStaffSubstitution (req 3) ─────────────────────────────────────────────
export const setStaffSubstitution = onCall(async (request) => {
  const { section_id, date, period_no, substitute_staff_uid, original_staff_uid, clear } = request.data || {};
  if (!section_id || !date || period_no == null) {
    throw new HttpsError("invalid-argument", "Missing section_id, date or period_no.");
  }
  const { uid } = await requireSectionAuthority(request, section_id);
  const ref = db.doc(`staff_substitutions/${section_id}_${date}_${period_no}`);

  if (clear) {
    await ref.delete();
  } else {
    if (!substitute_staff_uid) throw new HttpsError("invalid-argument", "Missing substitute_staff_uid.");
    const sub = await db.doc(`staff/${substitute_staff_uid}`).get();
    if (!sub.exists) throw new HttpsError("not-found", "Substitute is not a staff member.");
    await ref.set({
      section_id, date, period_no: Number(period_no),
      original_staff_uid: original_staff_uid ?? null,
      substitute_staff_uid, set_by_uid: uid, set_at: new Date().toISOString(),
    });
  }
  const plan = await regenerateDayPlan(db, { sectionId: section_id, date });
  return { ok: true, day_plan_version: plan?.version ?? null };
});

// ── setODAssignment (req 2) ──────────────────────────────────────────────────
// Whole-day: applies to every period that day, which is why it sits at the top
// of the venue precedence order.
export const setODAssignment = onCall(async (request) => {
  const { section_id, date, student_id, venue_id, reason, clear } = request.data || {};
  if (!section_id || !date || !student_id) {
    throw new HttpsError("invalid-argument", "Missing section_id, date or student_id.");
  }
  const { uid } = await requireSectionAuthority(request, section_id);
  const ref = db.doc(`od_assignments/${date}_${student_id}`);

  if (clear) {
    await ref.delete();
  } else {
    if (!venue_id) throw new HttpsError("invalid-argument", "Missing venue_id.");
    await requireFingerprintedVenue(venue_id);
    await ref.set({
      student_id, section_id, date, venue_id,
      reason: reason ?? null, set_by_uid: uid, set_at: new Date().toISOString(),
    });
  }
  const plan = await regenerateDayPlan(db, { sectionId: section_id, date });
  return { ok: true, day_plan_version: plan?.version ?? null };
});

// ── setTimetableEntry ────────────────────────────────────────────────────────
// The recurring weekly default. Regenerates the CURRENT day's plan; future days
// are built on demand by getDayPlan, so they pick this up automatically.
export const setTimetableEntry = onCall(async (request) => {
  const { section_id, weekday, period_no, venue_id, subject, staff_uid, clear } = request.data || {};
  if (!section_id || weekday == null || period_no == null) {
    throw new HttpsError("invalid-argument", "Missing section_id, weekday or period_no.");
  }
  await requireSectionAuthority(request, section_id);
  const ref = db.doc(`timetable/${section_id}/entries/${weekday}_${period_no}`);

  if (clear) {
    await ref.delete();
  } else {
    if (!venue_id) throw new HttpsError("invalid-argument", "Missing venue_id.");
    await requireFingerprintedVenue(venue_id);
    await ref.set({
      section_id, weekday: Number(weekday), period_no: Number(period_no),
      venue_id, subject: subject ?? null, staff_uid: staff_uid ?? null,
      updated_at: new Date().toISOString(),
    }, { merge: true });
  }
  const plan = await regenerateDayPlan(db, { sectionId: section_id, date: campusNow().date });
  return { ok: true, day_plan_version: plan?.version ?? null };
});

// ── setScheduleTemplate (§7: coordinator for own year, or HOD) ───────────────
// Advisors must NOT be able to change period/break timings.
export const setScheduleTemplate = onCall(async (request) => {
  const { uid } = requireAuth(request);
  const { year, periods, breaks, student_window_minutes } = request.data || {};
  if (year == null || !Array.isArray(periods) || !Array.isArray(breaks)) {
    throw new HttpsError("invalid-argument", "Missing year, periods or breaks.");
  }
  const snap = await db.doc(`staff/${uid}`).get();
  if (!snap.exists) throw new HttpsError("permission-denied", "Staff only.");
  const staff = snap.data();
  const isHod = staff.role === "hod";
  const isOwnYearCoordinator =
    staff.role === "coordinator" && Number(staff.coordinator_of_year) === Number(year);
  if (!isHod && !isOwnYearCoordinator) {
    throw new HttpsError("permission-denied", "Coordinator (own year) or HOD only.");
  }
  if (Number(year) !== 3) {
    throw new HttpsError("failed-precondition", "This build manages year 3 only.");
  }

  await db.doc(`schedule_templates/${year}`).set({
    year: Number(year), periods, breaks,
    student_window_minutes: Number(student_window_minutes ?? 5),
    timezone: "Asia/Kolkata",
    updated_by: uid, updated_at: new Date().toISOString(),
  }, { merge: true });
  return { ok: true };
});

// ── enrollStaffPalm (§5 prerequisite) ────────────────────────────────────────
// staff/ is entirely client-unwritable by design (see firestore.rules), so the
// palm template has to arrive through a function. The capture pipeline on the
// device is the SAME one students use — multi-frame average, same quality
// gates, same model-version gate; only the destination document differs.
export const enrollStaffPalm = onCall(async (request) => {
  const { uid } = requireAuth(request);
  const { embedding, hand_side, model_version, illumination, pose } = request.data || {};

  if (!Array.isArray(embedding) || embedding.length !== 256) {
    throw new HttpsError("invalid-argument", "Embedding must be 256 floats.");
  }
  if (!["left", "right"].includes(hand_side)) {
    throw new HttpsError("invalid-argument", "hand_side must be left or right.");
  }
  const snap = await db.doc(`staff/${uid}`).get();
  if (!snap.exists) throw new HttpsError("permission-denied", "Staff only.");

  const { modelVersion } = await loadModelConfig();
  if (model_version !== modelVersion) {
    // Refuse rather than store a template that can never be compared.
    throw new HttpsError("failed-precondition", "model_version_mismatch");
  }

  await db.doc(`staff/${uid}`).set({
    palm: {
      embedding, hand_side, model_version,
      enrolled_at: new Date().toISOString(),
      enroll_illumination: illumination ?? null,
      enroll_pose: pose ?? null,
    },
    updated_at: new Date().toISOString(),
  }, { merge: true });

  return { ok: true, model_version: modelVersion };
});
