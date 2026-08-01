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
      };
    }
  } catch (_) {
    /* fall through to bundled file */
  }
  return {
    threshold: FILE_CONFIG["verification_threshold_FAR_0.1pct"],
    modelVersion: FILE_CONFIG.model_version,
  };
}

/**
 * Sections this pilot build will accept attendance for.
 *
 * Deliberately Firestore-backed (`config/pilot` -> `sections: [...]`) rather
 * than hardcoded, so widening the pilot is a console edit, not a redeploy.
 * Returns [] when unset — i.e. nothing is live yet — which submitAttendance
 * reports as an explicit `section_not_in_pilot` rather than silently
 * accepting or silently dropping submissions.
 */
async function loadPilotSections() {
  try {
    const snap = await db.doc("config/pilot").get();
    if (snap.exists) {
      const s = snap.data().sections;
      if (Array.isArray(s)) return s.map(String);
    }
  } catch (e) {
    console.error(`loadPilotSections failed: ${e.message}`);
  }
  return [];
}

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
  } = p;

  if (!session_id || !nonce || !Array.isArray(probe_embedding)) {
    throw new HttpsError("invalid-argument", "Missing session_id, nonce or probe_embedding.");
  }

  const { threshold, modelVersion } = await loadModelConfig();
  const pilotSections = await loadPilotSections();
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

    // Known as soon as we have the session + student, so every rejection from
    // here on records which room it was for.
    evClassroomId = sess.classroom_id || student.assigned_classroom || null;

    // A roster-only record (advisor added them but they haven't enrolled) or
    // one whose biometrics were erased still has section/classroom but no
    // embedding. Report that plainly instead of falling through to a cosine
    // against undefined, which would surface as the opaque "bad_embedding".
    if (!Array.isArray(student.embedding) || student.embedding.length !== 256) {
      return reject("not_enrolled");
    }

    // 2b. Model version gate. v4 changed the embedding space, so a template
    // enrolled under any earlier model is not comparable to a v4 probe —
    // scoring it would produce a meaningless number that could land either
    // side of the threshold. Treat it as not-enrolled so the student is
    // prompted to re-enroll instead.
    if (student.model_version !== modelVersion) {
      return reject("model_version_mismatch");
    }

    if (student.section && sess.section && student.section !== sess.section) {
      return reject("outside_session");
    }

    // 2c. PILOT ALLOWLIST. This build is scoped to 1-2 supervised sections
    // while real operating data is gathered — a deliberate blast-radius limit,
    // not a permanent restriction. The allowlist lives in Firestore
    // (config/pilot.sections) so it can be widened without a rebuild or
    // redeploy. An empty/missing config means "no section is live yet" and is
    // reported explicitly rather than silently accepting or rejecting.
    if (!pilotSections.includes(student.section)) {
      return reject("section_not_in_pilot");
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

    // 5. Palm 1:1 — hand-side gate, then ONE cosine comparison.
    if (student.hand_side && hand_side && student.hand_side !== hand_side) {
      return reject("hand_side_mismatch");
    }
    const score = cosine(probe_embedding, student.embedding);
    evScore = score;
    if (score === null) return reject("bad_embedding");
    const palmOk = score >= threshold;

    // 6. Wi-Fi fingerprint — ≥ min_bssid_matches of the classroom's BSSIDs.
    const classroomId = evClassroomId;
    const roomSnap = classroomId
      ? await tx.get(db.doc(`classrooms/${classroomId}`))
      : null;
    if (!roomSnap || !roomSnap.exists) return reject("classroom_not_configured");
    const room = roomSnap.data();
    const registered = new Set(
      (room.wifi_fingerprint || []).map((a) => String(a.bssid).toLowerCase())
    );
    const scanned = new Set(
      (wifi_scan || []).map((a) => String(a.bssid || "").toLowerCase())
    );
    const matched = [...registered].filter((b) => scanned.has(b));
    evMatched = matched;
    const minMatches = room.min_bssid_matches ?? 2;
    if (registered.size === 0) return reject("classroom_not_configured");
    const wifiOk = matched.length >= minMatches;

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
        enrolled: Array.isArray(s.embedding) && s.embedding.length === 256,
        account_exists: accountExists,
        email_verified: verified,
      };
    })
  );

  roster.sort((a, b) => a.student_id.localeCompare(b.student_id));
  return { section, count: roster.length, roster };
});
