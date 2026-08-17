# PalmPay Attendance — Mobile App

> ## ⚠️ SCOPED ROLLOUT — THIRD YEAR ONLY, and not production-grade security
>
> **Scope.** The timetable / venue-resolution / role work is gated on
> `sections/{id}.year == 3`. Years 1, 2 and 4 keep the pre-existing behaviour
> and never enter the new code paths — the gate is opt-in, so an unknown
> section or a missing year falls back to the old logic rather than the new.
> See `STEP0_AUDIT.md` for the blast-radius analysis, including the two changes
> that could **not** be cleanly gated by year.
>
> **What Wi-Fi verification actually proves — read this before trusting it.**
> Routers on this campus are roof-mounted and rooms are roughly 7 m × 6 m × 3 m.
> Adjacent rooms on the same floor therefore see nearly the same access points
> at nearly the same signal strength. Matching is done on the RSSI-ranked
> profile (strongest-AP overlap *plus* signal strength within tolerance), not on
> bare BSSID presence, which is a real improvement — but it still gives
> **building / floor / zone-level confidence, NOT reliable room-level proof**.
> It cannot be relied on to tell room 301 from room 302, and nothing in this
> repository should be read as claiming otherwise.
>
> **The real presence anchor is the staff-opened, palm-verified, time-boxed
> session.** A member of staff authorised for that period palm-verifies on the
> spot, which opens a 5-minute window for that section. Wi-Fi is a supporting
> check inside that window, not the primary one.
>
> **The palm layer is not a standalone gate either.** `issue.md` records genuine
> pairs losing ~0.22 cosine to a lighting change and ~0.19 to palm angle,
> against an operating margin of 0.077. Expect false rejects.
>
> **Manual marking by the session opener (Absent / OD / Other + reason) remains
> the backstop** and is deliberately not removed. Device binding is still **not
> enforced**.

Single mobile app for **both** palm enrollment and daily attendance marking, on
the student's own phone. Verification is **server-side and 1:1**.

> **Architecture note:** this supersedes the earlier design where attendance
> lived in a separate laptop/web app. That app, and its Firestore handoff doc,
> are gone — everything is in this app plus a Cloud Functions backend.

---

## 1. Architecture

```
Student's own phone                  Firebase                  Advisor's phone
-------------------                  --------                  ---------------
ENROLL (once)
 palm → template  ──write──>  students/{id}                     Opens session
                                                                     │
                              attendance_sessions  <──create────────┘
MARK ATTENDANCE (daily)              │
 session open? <─────────────────────┘
 palm scan → embedding
 wifi scan + gps
      ──────send──────>  submitAttendance()  (Cloud Function)
                          · fetches THIS student's template
                          · 1 cosine comparison
                          · checks wifi / gps / session / device
                          · decides, writes record
                                     │
                              attendance/{id}  ──> advisor sees live list
```

**Identity model.** The student is signed in on their own device, so
`student_id` comes from the auth token — never the request payload.
Verification is **1:1**: fetch that one student's stored template, do **one**
cosine comparison. No gallery search, no 1:N. The palm answers a single
question: *"is the person holding this phone the owner of this account?"*

**The phone never decides.** A patched APK can enable any button and assert any
boolean, so the client sends *evidence* (embedding, Wi-Fi scan, GPS, device id)
and the server returns a *verdict*. There is no `palm_verified` field in the
request, and clients cannot write the `attendance` collection at all.

---

## 2. Tech stack

| Layer | Choice |
|---|---|
| App | Flutter (Android first; see §8 for the iOS caveat) |
| Model runtime | `onnxruntime` — loads `palm_256_l2_fp32.onnx` on-device |
| Camera | `camera`, YUV420/BGRA frame streaming |
| Palm detection | MediaPipe Hands (`hand_detection`) — ROI + handedness |
| Auth | Firebase Auth, `@citchennai.net` only, email-verified |
| Database | Cloud Firestore — **`asia-south1`** (confirmed) |
| Server logic | Cloud Functions gen2 (`functions/`), region `asia-south1` |
| Presence | `wifi_scan` (primary), `geolocator` (coarse), `device_info_plus` |
| State | Riverpod |

---

## 3. The model

- **Use `palm_256_l2_fp32.onnx`.** Never any `palm_int8_*.onnx` — INT8
  post-training quantization corrupts this backbone (~0.70 self-cosine vs
  fp32); deferred until quantization-aware training.
- Output is **already L2-normalized** — never normalize again.
- Similarity = **cosine**. Threshold currently **0.70 — an INTERIM value, not
  the v4 eval's 0.5084 and not FAR-derived** despite the field name. Read from
  `deploy_config.json` / Firestore `config/model`; **never hardcoded**.

  **Why it was raised (measured on-device, 2026-07-28, v4 + ROI crop, 2 people):**

  | Comparison | Score |
  |---|---|
  | Genuine — person A | 0.7593 |
  | Genuine — person B | 0.8437 |
  | Live impostor scan | ~0.63 |
  | Cross-person enrolled templates | 0.5696 |

  The v4 eval threshold `0.5084` sat **below the entire impostor range**, so the
  palm layer accepted anyone — two different people's stored templates alone
  scored 0.5696 against each other. `0.70` separates this sample, verified live
  (impostor rejected at 0.5696).

  **Caveats — read before trusting this number.** It is fitted to **n = 2
  people**. Margins are thin: person A's genuine 0.7593 clears by only 0.06, so
  expect false rejects on others. **Re-derive from 10+ identities before
  widening the pilot**, and do not lower it back toward 0.5084 without new
  evidence.
- Currently shipped weights: `model_version` = **`palm_256_l2_fp32_v4`**
  (ROI-aligned). Bump this whenever the weights change so old and new
  embeddings stay distinguishable (see `assets/models/README.txt`).

### v4: the ROI crop is load-bearing

v4 was retrained on **MediaPipe-cropped palm ROIs** — the same input the app
produces — to close a train/deploy domain mismatch. The previous model was
trained on full-hand images while the app fed it crops; measured on real phone
photos, impostor scores averaged **0.514** (should be near 0) with **~29%**
false accepts. Retraining on ROI crops moved false rejects 14% → **0%** and
false accepts 29% → **~14%**.

That means **inference must reproduce the training crop exactly** or the gap
comes straight back, silently, with nothing failing loudly:

| | |
|---|---|
| Landmarks | `0, 1, 2, 5, 9, 13, 17` (wrist, thumb_cmc, thumb_mcp, index/middle/ring/pinky mcp) |
| Centre | mean of those points, in pixels |
| Half-size | `1.1 × distance(wrist(0) → middle_mcp(9))` |
| Crop | square `[centre − half, centre + half]`, clipped to bounds — **not re-squared** after clipping |
| Fallback | centre square `min(h,w)` when no hand is detected |

Implemented in `MediaPipeHandDetector.palmRoiFrom` (geometry, unit-tested in
`test/palm_roi_test.dart`) and applied in `PalmPreprocessor._cropPalmRoi`.
`CaptureController` passes the detected ROI through on every frame.

Preprocessing constants (`input_size` 224, RGB, NCHW, `divide_by_255`,
ImageNet mean/std) are all read from `assets/models/deploy_config.json` via
`DeployConfig` — nothing about the pipeline is hardcoded in Dart.

**Threshold on the server.** `functions/` keeps its own copy of the threshold
in `functions/deploy_config.json`, and prefers a Firestore `config/model` doc
if present (so it can change without redeploying). **Keep the server copy in
sync with the app's `deploy_config.json` on every retrain.**

---

## 4. Capture (shared by enrollment and attendance)

Both flows use the exact same routine — `CaptureController` + the shared
`PalmPreprocessor`. Only what happens to the resulting vector differs.
Divergence here would silently corrupt every comparison.

1. Camera preview; MediaPipe locates the palm (open palm required).
2. **Quality gate on every frame** (`QualityGate`) — an actual gate: failing
   frames are never embedded and never counted.
   - **Overexposure (strict):** rejects when **>2.5% of pixels are
     near-saturated (≥250)** — *localized blowout*, not mean brightness, since
     real glare is patchy specular highlight.
   - **Underexposure (lenient):** low mean-luma floor only. The model handles
     darkening well (~0.935 same-palm cosine at −40%) but degrades under
     brightening (~0.704 at +40%), so the gate is deliberately **asymmetric**.
   - Plus focus, centering, and three-layer liveness (motion, texture,
     embedding variance).
   - Rejections give specific guidance ("Too bright — step out of direct
     light"), never a generic retry.
3. Capture **5–8 gated-good frames** → embed each → **average → L2-normalize
   once**.

> **Never compare single-shot embeddings.** Same-palm single-image scores
> ranged 0.75–0.93; averaging turns that noise into a stable ~0.86. This is the
> single biggest robustness lever in the app.

---

## 5. Flows

### Enrollment (once)
Sign in → **consent** (standalone, blocking, timestamped) → hand side
(explicit) → §4 capture → save to `students/{student_id}`, binding this device.
Re-enrollment **updates** the doc (preserves `created_at`, bumps `updated_at`)
— never creates a duplicate. One-tap delete removes it.

### Attendance (daily, student-initiated)
`AttendanceScreen`: confirm enrolled → find an **open session for my section**
→ **Wi-Fi scan** + **GPS** → request a **single-use nonce** → §4 palm capture →
`submitAttendance` → render the server's verdict. The button may be disabled
before pre-checks pass, but that is **UX convenience only** — the real gate is
server-side.

### Advisor / admin
`AdvisorHomeScreen`: open an attendance window for the section, watch the
**live marked list**, close early, and **manually mark** absent / OD / other
with a reason. Admins additionally get `WifiFingerprintScreen` to capture a
classroom's Wi-Fi fingerprint. Role comes from a `staff/{uid}` document
provisioned out-of-band; students have none.

`AssignStudentScreen` (roster): an advisor adds a student to a section by
email. The `assignStudent` Cloud Function creates the Auth account if it
doesn't exist, writes `section`/`assigned_classroom` onto `students/{id}`
(fields students can't self-write), and **queues a setup/verification email**
to the student via the `mail/` collection. The advisor sees a live roster with
each student's status (Invited → Pending verification → Verified → palm
enrolled), read back through `listSectionRoster` (which cross-references Auth's
`emailVerified`, since the client can't). Advisors are scoped to their own
`sections`; admins may assign to any.

> **Email delivery needs the Firebase "Trigger Email from Firestore"
> extension** + an SMTP/SendGrid config. `assignStudent` writes the mail doc;
> the extension sends it. **Until the extension is installed, students are
> still created and rostered and the mail simply queues in `mail/` unsent.**
> A brand-new account gets a password-setup link (setting the password also
> verifies the email); an existing-but-unverified account gets a verification
> link.

---

## 6. Server checks (in order) — `functions/index.js`

1. **Nonce** valid, unused, unexpired, belongs to this student.
2. **Session** exists, `status == "open"`, server time inside the window,
   section matches the student.
2b. **Model version** — the stored template's `model_version` must equal the
   deployed one, else `model_version_mismatch` (see §6a).
2c. **Pilot allowlist** — student's `section` must be in
   `config/pilot.sections`, else `section_not_in_pilot` (see §6b).
3. ~~Device binding~~ — **deliberately not enforced in this build** (§5a).
4. **Duplicate** — no existing `present` record for this student + session.
5. **Palm 1:1** — hand-side gate first, then **one** cosine comparison against
   that student's own template, versus the config threshold.
6. **Wi-Fi fingerprint** — ≥ `min_bssid_matches` of the classroom's
   registered BSSIDs present in the scan.
7. **GPS coarse check** — inside the campus-wide radius, sane accuracy.
8. **Risk signals logged, not gated alone** — mock location, poor accuracy.
9. **Write** the record with the full evidence trail and `decision_reason`.

Server timestamps decide; `client_timestamp` is audit-only. A hash of the
probe embedding is stored so a replayed capture is detectable. Steps 1–4 run
inside a transaction so nonce consumption and the duplicate check can't race a
concurrent submission.

**Every submission writes an `attendance` record — accepted _or_ rejected**,
including early bails like `model_version_mismatch` and `section_not_in_pilot`.
Rejections previously wrote nothing, which would have left weekly pilot review
blind to exactly the false-reject complaints it exists to catch.

### §5a. Device binding — NOT enforced (deliberate, pilot-only)

`device_id` is still collected and written to every attendance record (useful
pilot signal: it shows if one handset submits for many students), but it does
**not** gate accept/reject, and no binding is written. The active layers for
this pilot are **palm + Wi-Fi fingerprint + session window**.

This is a temporary, intentional relaxation for pilot simplicity — not an
oversight. Re-enabling it is a candidate before any wider rollout; note that
`bound_device_id` is deliberately not student-writable (see `firestore.rules`)
precisely so a binding can't be reassigned from a handset.

### §6a. Model-version gate — re-enrollment after a model change

v4 changed the embedding space, so a template enrolled under an earlier model
is **not comparable** to a v4 probe — scoring it yields a meaningless number
that could land either side of the threshold. The server rejects the
comparison (`model_version_mismatch`) rather than performing it, and the app
mirrors the check (`StudentProfile.isUsableWith`) so home/attendance show
"Re-enrollment needed" instead of letting the student fail at the door.

**Existing pre-v4 templates must be re-enrolled.** Current enrolled accounts
are test accounts, so wiping/ignoring them and having the pilot section enroll
fresh under v4 is the practical path.

### §6b. Pilot allowlist

Attendance is accepted only for sections listed in Firestore
`config/pilot` → `sections: [...]`. It is **data, not code** — widen the pilot
by editing that document; no rebuild or redeploy. Missing/empty means nothing
is live, and submissions are rejected *explicitly* with
`section_not_in_pilot`, never silently. Currently: `["CSE-F"]`.

---

## 7. Firestore schema

```
students/{student_id}        student_id, department, year, section,
                             assigned_classroom, hand_side, embedding[256],
                             model_version, consent, consent_at,
                             bound_device_id, device_bound_at,
                             created_at, updated_at

classrooms/{classroom_id}    building, room, floor, latitude, longitude,
                             campus_radius_m (coarse only),
                             wifi_fingerprint: [{bssid, ssid, typical_rssi}],
                             min_bssid_matches, updated_at

attendance_sessions/{id}     classroom_id, section, advisor_id,
                             opened_at, closes_at (server ts),
                             status: open|closed, rotating_code?

attendance/{id}              session_id, student_id, classroom_id, status,
                             decision_reason, palm_score,
                             palm_threshold_used, model_version,
                             probe_embedding_hash,
                             wifi_matched_bssids, wifi_match_count,
                             gps_*, is_mock_location, device_id,
                             server_timestamp, client_timestamp

nonces/{nonce}               student_id, expires_at, used   (function-only)
staff/{uid}                  role: advisor|admin, section, classroom_id, name
```

`palm_threshold_used` + `model_version` are recorded on every decision — both
change on retrain, and you must be able to explain an old decision months later.

### Security rules (`firestore.rules`)
- Clients **cannot write `attendance`** — only the Cloud Function (Admin SDK,
  which bypasses rules).
- **Field-level writes on `students/{id}`.** A student may only change
  `embedding`, `hand_side`, `model_version`, `consent`, `consent_at`,
  `updated_at`. Everything that decides *where and as whom they are verified*
  — `section`, `assigned_classroom`, `department`, `year`, `student_id` — plus
  `bound_device_id` is admin/Cloud-Function-only. A student who could edit
  `assigned_classroom` would pick which room's Wi-Fi fingerprint validates
  them, defeating the whole presence layer.
- `bound_device_id` remains non-client-writable, but **no binding is written or
  enforced in this pilot build** — see §5a.
- A student reads only their own `students/{id}` and their own `attendance`.
  No student can list all students' embeddings.
- `classrooms` readable by any signed-in user, writable by admins only.
- `attendance_sessions` writable only by the owning advisor.
- `nonces` are function-only (denied to all clients).
- Everything requires a **verified `@citchennai.net`** account.
- **Written-but-undeployed rules protect nothing:**
  `firebase deploy --only firestore:rules,firestore:indexes`

---

## 8. Known limitations (per spec §12)

- **Wi-Fi is room/floor-level, not seat-level.** A student in the corridor may
  see the same APs. Advisor visual confirmation is the backstop.
- **BSSID cloning is possible** for a technically capable student with a
  router. A multi-AP fingerprint raises the bar a lot but doesn't eliminate it.
- **Mock-location detection is bypassable** on rooted Android; iOS has no
  equivalent API.
- **No liveness gate yet** — a printed palm photo may still pass, and this
  matters more now that the device is student-controlled. The capture pipeline
  has motion/texture/embedding-variance checks, but a dedicated liveness module
  is still a separate planned piece.
- **Lighting sensitivity.** Overexposure is the model's weak axis; the quality
  gate mitigates but doesn't eliminate it.
- **iOS**: BSSID reads need the paid-account **Access WiFi Information**
  entitlement. **Ship Android first.** Without it, iOS must fall back to
  GPS + rotating code and the record must be flagged as a weaker path — that
  fallback is **not implemented yet**.

---

## 9. Compliance

- Firestore in **`asia-south1`** (confirmed in the Firebase Console).
- Explicit standalone consent before capture, stored with timestamp.
- Only the embedding is stored — never the raw palm image.
- One-tap delete, propagated to Firestore.
- Pilot scoped to **18+** (consent screen requires age confirmation);
  under-18 enrollment needs verifiable parental consent first.
- The college is effectively a joint data fiduciary — get formal department
  approval before deployment.

> Engineering checklist, not legal advice.

---

## 10. Setup / deploy

```bash
flutter pub get
flutter run -d <device>            # Android

cd functions && npm install
firebase deploy --only firestore   # rules + indexes
firebase deploy --only functions   # gen2, needs Blaze
```

### ⚠️ This project's Firestore database is named `default`, not `(default)`

Every SDK targets `(default)` unless told otherwise, so a bare
`FirebaseFirestore.instance` / `getFirestore()` fails with
`NOT_FOUND: The database (default) does not exist` — this was the real cause of
the early "embeddings aren't saving" bug. It is pinned in three places; **keep
them consistent**:

| Where | How |
|---|---|
| Flutter | `lib/services/firestore_ref.dart` → `appFirestore` (never call `FirebaseFirestore.instance` directly) |
| Functions | `getFirestore("default")` in `functions/index.js` |
| CLI | `"database": "default"` in `firebase.json` |

### Seeding advisors and classrooms

`staff/*` is client-unwritable and `classrooms/*` is admin-only, so these are
provisioned with the Admin SDK:

```bash
cd functions && npm install
cp seed/seed-data.example.json seed/seed-data.json    # edit this file
export GOOGLE_APPLICATION_CREDENTIALS=/abs/path/key.json
node seed/seed.js --dry-run     # preview, writes nothing
node seed/seed.js               # apply
```

Idempotent: re-running updates rather than duplicating, and never clobbers a
`wifi_fingerprint` already captured in-app. `seed-data.json` and any service
account key are gitignored.

**Current status:**
- [x] Firestore **rules + indexes deployed** to the `default` database.
- [x] **Cloud Functions deployed** — `requestNonce` + `submitAttendance`,
      gen2, `asia-south1`.
- [x] Flutter deps resolved; `flutter analyze` reports **0 errors**.
- [x] **Staff provisioned** — `coordinator.cse@citchennai.net` (admin, no
      sections) and `hari27@citchennai.net` (admin over **CSE-A + CSE-B**,
      email-verified). Both in `functions/seed/seed-data.json`.
- [x] **Roster flow deployed + verified end-to-end** — `assignStudent` and
      `listSectionRoster` live; a test assignment created the account, wrote
      the roster fields, and queued the setup email in the correct format
      (test artifacts cleaned up).
- [ ] **Trigger Email extension not installed** — roster emails queue in
      `mail/` but won't send until you install the extension and configure
      SMTP. Everything else about the roster works without it.
- [x] **`coordinator.cse@citchennai.net` email-verified** via the Admin SDK
      (`emailVerified = true`). Needs a fresh sign-in for the new
      `email_verified` claim to appear in its ID token (rules read the token,
      not live Auth state).
- [x] **`hari27@citchennai.net` provisioned as admin** over **CSE-A + CSE-B**,
      email-verified, can open sessions and use the roster screen for both.
- [x] **Fixed: enrolling on top of a roster-assigned student silently failed.**
      An advisor assigning a student via `assignStudent` created a
      `students/{id}` doc with no `created_at`. The student's subsequent
      enrollment write got rejected by `firestore.rules` (permission-denied,
      swallowed by the background-sync error handler), so the app showed
      "enrolled" from local cache only — and the next refresh re-fetched the
      still-empty server doc and made the embedding appear to vanish. Root
      cause was actually two bugs: `created_at` wasn't in the student-writable
      field list, **and** where it *was* set server-side it was a Firestore
      `Timestamp` instead of the ISO string the rules/Dart model require —
      `isWellFormedStudent` checks `created_at is string` on every write, so
      the wrong type permanently blocked all further writes to that doc, not
      just ones touching `created_at`. Fixed in `firestore.rules` (`
      created_at` now student-writable) and `functions/index.js` (`
      assignStudent` writes an ISO string; `submitAttendance`'s device-binding
      write had the identical bug, fixed too). `StudentProfile.fromFirestore`
      is now also defensive against either type. Verified against the live
      project with the exact reported shape (roster-assigned, no
      `created_at`, empty embedding) — enrollment now succeeds and survives a
      simulated refresh.
- [x] **No `classrooms/{id}` needed manually** — the admin creates them in-app:
      the Wi-Fi fingerprint screen writes with merge, so typing a room id and
      capturing creates the classroom. Until a room has a fingerprint every
      submission there returns `classroom_not_configured`.
- [x] **Fixed the same Timestamp-vs-string bug in `classrooms`** —
      `seed/seed.js` was writing `created_at`/`updated_at` as Firestore
      Timestamps, which `Classroom.fromFirestore`'s `DateTime.tryParse(... as
      String)` would have thrown on the first time the app read a
      seed-created classroom. Fixed at the source (seed now writes ISO
      strings) and `Classroom.fromFirestore` is now defensive either way, same
      pattern as `StudentProfile`. No live classroom docs existed yet, so
      there was nothing to backfill.
- [ ] **Note on `@students.citchennai.net`** — deliberately NOT allowed. Only
      `@citchennai.net` may sign in, so any account on the students subdomain
      (e.g. `23csea001@students.citchennai.net`) is blocked by design.
- [ ] **Not yet run on-device since the rewrite.** It compiles, but no flow has
      been exercised on hardware.

### ⚠️ `firebase deploy --only firestore:rules` can silently no-op

On this project (named database `default`, not `(default)`), scoping the
deploy to `--only firestore:rules` sometimes skips the actual rules upload —
the CLI prints "Deploy complete!" but the *checking / compiling / uploading /
releasing* lines are missing, and the live ruleset genuinely does not change
(confirmed by reading it back via the Firebase Rules REST API). **Always
deploy with `firebase deploy --only firestore`** (rules + indexes together,
unscoped) and, if it matters, verify the release's `updateTime` moved. This
is exactly how the bug above stayed live through two "successful" rules
deploys before being caught.
