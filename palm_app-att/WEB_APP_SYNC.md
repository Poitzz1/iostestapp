# PalmPay — Web App Sync Reference

> **⚠️ Pilot build.** Scoped to sections in `config/pilot.sections` (currently
> `["CSE-F"]`), model `palm_256_l2_fp32_v4`, threshold `0.70`. The palm layer
> is **not** a standalone gate (~14% false accepts); it is one layer alongside
> Wi-Fi fingerprint + session window, with advisor manual marking as the
> backstop. Device binding is logged but **not enforced**. Don't present this
> as production-grade security.
>
> **Changed in v4 — action required if you read these fields:**
> - `model_version` is now `palm_256_l2_fp32_v4`; pre-v4 templates are
>   incomparable and rejected with `model_version_mismatch`.
> - `palm_threshold_used` is now `0.70` (interim) (was `0.7`/`0.561`).
> - Two new `decision_reason` values: `model_version_mismatch`,
>   `section_not_in_pilot`.
> - **Rejected submissions now write `attendance` rows too** (they previously
>   wrote nothing). Filtering on `status == "present"` is now essential — see
>   §3.

What your web app needs to read the same Firebase project as the mobile app
and stay consistent with it. Everything here reflects what is **actually
deployed right now**, not just the design intent — several items below were
real bugs found and fixed in the mobile app; if your web app writes any of
these same fields, it can hit the identical bugs.

---

## 1. Project basics

| | |
|---|---|
| Firebase project | `attcit-52e7d` |
| Firestore database ID | **`default`** — not the usual `(default)`. See §5. |
| Region (Firestore + Functions) | `asia-south1` |
| Auth | Firebase Auth, email/password, **`@citchennai.net` only**, **must be email-verified** |

If you use the Firebase JS SDK, be explicit about both of these — most
snippets you'll find assume the defaults, which are wrong for this project:

```js
import { initializeApp } from "firebase/app";
import { getFirestore } from "firebase/firestore";
import { getFunctions } from "firebase/functions";

const app = initializeApp({ /* config from Firebase Console */ });
const db = getFirestore(app, "default");           // <-- name it explicitly
const functions = getFunctions(app, "asia-south1"); // <-- region matters for callables
```

---

## 2. Auth requirements

- Only `@citchennai.net` addresses can sign in or read/write anything — enforced
  in `firestore.rules` (`isAllowedDomain()`), not just client-side, so this
  applies to your web app too regardless of what it does client-side.
- The account's email must be verified (`request.auth.token.email_verified ==
  true` in the security rules). A freshly-created account is NOT verified —
  see `assignStudent` in §4 for how the mobile app handles that.
- **Role = presence of a `staff/{uid}` document**, not a custom claim. Fields:
  `role` (`"advisor"` | `"admin"`), `sections` (array), `section` (convenience:
  `sections[0]`), `classroom_id`, `name`, `staff_id`, `department`.
  - `advisor`: can open/close sessions and add students **for their own
    `sections`** only.
  - `admin`: same, plus can write `classrooms/*` (Wi-Fi fingerprints) and call
    `assignStudent`/`listSectionRoster` for **any** section.
  - Students have no `staff/{uid}` doc at all.
  - **`staff/*` cannot be created or edited by any client** (mobile or web) —
    only via the Admin SDK (the seed script, or a backend you write). If your
    web app needs to provision staff, do it server-side with a service
    account, the same way `functions/seed/seed.js` does.

---

## 3. Firestore schema — as actually deployed

### `students/{student_id}`

One document per student. `student_id` = **uppercase local-part of the email**
(`23csea001@citchennai.net` → `23CSEA001`) — compute it the same way if you
need to derive the doc ID from an email.

```json
{
  "student_id": "23CSEA001",
  "department": "CSE",                 // optional
  "year": "2",                         // optional, currently unused by the app
  "section": "CSE-A",                  // set by assignStudent / seed script
  "assigned_classroom": "C302",        // optional, set the same way
  "hand_side": "left",                 // "left" | "right"
  "embedding": [ /* 256 floats */ ],
  "model_version": "palm_256_l2_fp32_v4",
  "consent": true,
  "consent_at": "2026-07-27T11:59:48.278769",
  "bound_device_id": "abc123...",      // NOT set/enforced in this pilot build
  "device_bound_at": "2026-07-27T12:00:00.000Z",
  "created_at": "2026-07-27T06:27:44.872Z",
  "updated_at": "2026-07-27T12:00:11.059118",
  "roster_email": "23csea001@citchennai.net",   // set by assignStudent
  "roster_assigned_by": "<staff uid>",
  "roster_assigned_at": <Firestore Timestamp>
}
```

- **A doc can exist with NO palm yet** — an advisor adding a student via the
  roster screen creates a doc with only `student_id`/`section`/roster_*
  fields. `embedding` is absent or `[]` until the student actually enrolls in
  the mobile app. **Check `embedding.length === 256`** to know if a student is
  actually enrolled, not just "does the doc exist".
- **Field-level write permissions** (mobile client can only touch some
  fields): `embedding`, `hand_side`, `model_version`, `consent`, `consent_at`,
  `updated_at`, and `created_at` (only on create/first-touch) are
  student-writable. `section`, `assigned_classroom`, `department`, `year`,
  `student_id`, `bound_device_id` are **admin/Cloud-Function only** — a
  student can never change which section or classroom they're validated
  against. If your web app writes to `students/*` as a staff user, you're
  bypassing this restriction legitimately (staff have full write); just don't
  build a *student-facing* web flow that tries to set these fields as the
  student — the rules will reject it.
- **Timestamp fields here are ISO8601 STRINGS, not Firestore Timestamps** —
  `created_at`, `updated_at`, `consent_at`, `device_bound_at` are all plain
  strings (e.g. `"2026-07-27T12:00:11.059118"`). **This is load-bearing, not
  cosmetic**: `firestore.rules` has a hard check (`created_at is string`) on
  every student write, and writing any of these as a Firestore `Timestamp`
  object instead will **permanently block all future writes to that
  document** (this exact bug happened in production — the advisor's roster
  tool created a doc with a `Timestamp`, and the student's own enrollment
  write was rejected forever after). **If your web app ever writes to
  `students/*`, use ISO strings for these four fields, always.**

### `classrooms/{classroom_id}`

Read-only to any signed-in client; write requires `role: "admin"`.

```json
{
  "classroom_id": "C302",
  "building": "C Block", "room": "C302", "floor": 3,
  "latitude": 13.083652, "longitude": 80.270843,   // OPTIONAL — see below
  "campus_radius_m": 300,
  "wifi_fingerprint": [
    { "bssid": "aa:bb:cc:dd:ee:ff", "ssid": "CIT-Wifi", "typical_rssi": -52 }
  ],
  "min_bssid_matches": 2,
  "created_at": "2026-07-27T...", "updated_at": "2026-07-27T..."
}
```

- `latitude`/`longitude` are optional. **If absent, the server skips the GPS
  check entirely** for that room — Wi-Fi fingerprint is the real presence
  gate, GPS is only ever a coarse "on campus" sanity check. Don't invent
  coordinates; a wrong guess rejects every student in that room with
  `gps_out_of_campus`.
- `wifi_fingerprint` starts as `[]` and is populated by an admin physically
  standing in the room using the mobile app's capture screen. Until it has
  **at least `min_bssid_matches` (default 2) entries**, every attendance
  submission for that room returns `classroom_not_configured`.
- Same timestamp caveat as students: `created_at`/`updated_at` are ISO
  strings, not Timestamps.

### `attendance_sessions/{session_id}`

```json
{
  "classroom_id": "C302",
  "section": "CSE-A",
  "advisor_id": "<staff uid>",
  "opened_at": <Firestore Timestamp>,
  "closes_at": <Firestore Timestamp>,
  "status": "open",                    // "open" | "closed"
  "rotating_code": "482913"             // optional, unused currently
}
```

- **These ARE real Firestore Timestamps** (`opened_at`, `closes_at`) — unlike
  `students`/`classrooms`. This is an intentional asymmetry in the current
  schema, not an oversight to "fix" — just be aware the convention differs by
  collection. Read them with `.toDate()` in your web SDK, not string parsing.
- Created directly by advisor/admin clients (not a Cloud Function) — rules
  require `advisor_id == request.auth.uid` on create, and only the same
  advisor can update/close it.
- Any signed-in user (student or staff) can **read** sessions — the mobile app
  uses this to find "is there an open session for my section right now."

### `attendance/{attendance_id}`

**Written ONLY by the `submitAttendance` Cloud Function** (Admin SDK — bypasses
rules). No client, including your web app, can create/delete these directly;
`firestore.rules` denies it outright. Staff can `update` (manual marking only
— see below).

```json
{
  "session_id": "XZZ6KBSEFtHtEB3Tu05h",
  "student_id": "23CSEA001",
  "classroom_id": "C302",
  "status": "present",
  "decision_reason": "ok",
  "palm_score": 0.847,
  "palm_threshold_used": 0.5084,
  "model_version": "palm_256_l2_fp32_v4",
  "probe_embedding_hash": "sha256 hex, for replay detection",
  "wifi_matched_bssids": ["aa:bb:cc:dd:ee:ff", "..."],
  "wifi_match_count": 2,
  "gps_lat": 13.08, "gps_lng": 80.27, "gps_accuracy_m": 12.4,
  "gps_campus_distance_m": 42.1,
  "is_mock_location": false,
  "device_id": "abc123...",
  "submitted_by_uid": "<student's auth uid>",
  "server_timestamp": <Firestore Timestamp>,
  "client_timestamp": "2026-07-27T12:00:00.000Z"   // ISO string, audit-only, never trust for logic
}
```

- **`status` values**: `"present"` | `"rejected"` | `"absent"` | `"od"` |
  `"other"`. The last three come from advisor **manual marking** (a separate
  write path, see below), not from `submitAttendance`.
- **`decision_reason` enum**: `ok`, `outside_session`, `wifi_mismatch`,
  `palm_below_threshold`, `hand_side_mismatch`, `device_not_bound`,
  `duplicate`, `gps_out_of_campus`, `classroom_not_configured`,
  `not_enrolled`, `invalid_nonce`, `bad_embedding`, `model_version_mismatch`, `section_not_in_pilot`. For manual marks it's
  `manual_absent` / `manual_od` / `manual_other`.
- **⚠️ Multiple documents can exist for the same `(session_id, student_id)`
  pair.** Every submission attempt writes its own record — a student who fails
  once (bad Wi-Fi, palm mismatch, etc.) and retries successfully will have
  **two** attendance docs for that session: one `rejected`, one `present`.
  **Only a `status == "present"` document counts as "this student attended
  this session."** If your web app renders a "who's present" list, filter on
  `status == "present"` — don't just count docs per student, and don't assume
  the newest doc per student is authoritative without checking its status.
  (This was a real bug fixed just now: the duplicate-guard used to block on
  *any* prior record regardless of outcome, which meant one bad Wi-Fi read on
  attempt 1 permanently locked the student out of that session. Now it only
  blocks when a prior `present` record already exists.)
- Manual marking (`absent`/`od`/`other`) is a plain client `update()` by a
  staff user — rules allow any staff `update` on `attendance` (they cannot
  `create`/`delete`). There's nothing stopping a manual mark from being
  applied even after a `present` record exists; if your web app adds manual
  marking, decide deliberately whether that should be allowed to override an
  automated `present`.

### `staff/{uid}`

Doc ID = Firebase Auth UID (not derived from email). Only readable by the
staff member themself (`get` where `uid == request.auth.uid`); no client can
`list` all staff or write to this collection at all. Provision via
`functions/seed/seed.js` or your own Admin-SDK script — see §4.

### `nonces/{nonce}`, `mail/{id}`

Both entirely denied to every client (`allow read, write: if false`) — these
are Cloud-Function-internal (replay-protection tokens, and the outbound email
queue for the "Trigger Email from Firestore" extension). Your web app has no
reason to touch either; don't try.

---

## 4. Cloud Functions (callable, region `asia-south1`)

All four are `onCall` functions — call them with the Firebase Functions SDK's
`httpsCallable`, not raw HTTP, unless you have a specific reason not to (the
callable protocol handles auth token propagation for you).

| Function | Who can call | Purpose |
|---|---|---|
| `requestNonce()` | any signed-in verified student | Issues a single-use, 2-minute token required by `submitAttendance`. No args. Returns `{ nonce, expires_in_ms }`. |
| `submitAttendance(data)` | any signed-in verified student | Runs all server-side checks (§6 in README) and writes the `attendance` record. See request/response shape below. |
| `assignStudent(data)` | staff only | Adds a student to a section: creates their Auth account if needed, writes `section`/`assigned_classroom` to `students/{id}`, queues a setup/verification email. `{ student_email, section, assigned_classroom? }` → `{ student_id, section, assigned_classroom, account_created, email_verified, email_sent }`. Advisors are restricted to their own `sections`; admins can target any section. |
| `listSectionRoster(data)` | staff only | `{ section }` → `{ section, count, roster: [{ student_id, email, section, assigned_classroom, enrolled, account_exists, email_verified }] }`. Cross-references Auth's live `emailVerified` (which a client can't read directly for another user). |

**`submitAttendance` request** (what the mobile app sends — mirror this shape
if your web app ever needs to simulate/replay a submission, though normally
only the student's own phone would call this):

```json
{
  "session_id": "...",
  "nonce": "...",
  "probe_embedding": [ /* 256 floats */ ],
  "hand_side": "left",
  "wifi_scan": [{ "bssid": "aa:bb:cc:dd:ee:ff", "rssi": -52 }],
  "gps": { "lat": 13.08, "lng": 80.27, "accuracy_m": 12.4 },
  "is_mock_location": false,
  "device_id": "...",
  "client_timestamp": "2026-07-27T12:00:00.000Z"
}
```

**Response** (also what gets written to the `attendance` doc, see §3):
`{ status, decision_reason, attendance_id, palm_score, palm_threshold_used,
wifi_match_count }`.

Note `student_id` is **never** part of the request — the function derives it
from the caller's own auth token, always. There is no way to submit
attendance on behalf of another student through this API, by design.

---

## 5. The `default`-vs-`(default)` database gotcha

This project's Firestore database is literally named `default`. Almost every
SDK, code sample, and the `firebase` CLI itself assumes the conventional
`(default)` database unless told otherwise. Get this wrong and you'll see:

```
NOT_FOUND: The database (default) does not exist for project attcit-52e7d
```

This exact error caused a real outage earlier. Always pass the database name
explicitly:

- **Firebase JS SDK**: `getFirestore(app, "default")` (see §1).
- **Admin SDK (Node)**: `getFirestore("default")`.
- **Firebase CLI**: `firebase.json` needs `"firestore": [{ "database":
  "default", ... }]`, and — separately important — **`firebase deploy --only
  firestore:rules` can silently no-op** on this project (prints "Deploy
  complete!" without actually uploading anything). Always deploy with
  **`firebase deploy --only firestore`** (unscoped) and, if it matters,
  confirm the ruleset's `updateTime` actually moved via the Firebase Rules
  REST API — don't trust the CLI's success message alone.

---

## 6. Config that changes over time — don't hardcode

`assets/models/deploy_config.json` (mobile) and `functions/deploy_config.json`
(server) are the source of truth for:

- `verification_threshold_FAR_0.1pct` — currently `0.7`. This is a manually
  raised value (was `0.560699999332428`, the FAR≈0.1% figure from the last
  identity-disjoint evaluation) — trading a higher false-rejection rate for a
  lower false-accept rate. It is not tied to any specific FAR anymore, and
  will change again (to a real re-evaluated number) after the next retrain.
- `model_version` — currently `palm_256_l2_fp32_v4` (ROI-aligned). Pre-v4 templates are rejected, not scored.

If your web app ever needs the threshold (e.g. to display a match-confidence
UI), read it from Firestore `config/model` if that doc exists (the function
checks there first) or from the bundled JSON — don't copy the number into your
own code, it will drift.

---

## 7. Quick checklist before you write anything

- [ ] Firestore client points at database `"default"`, not `(default)`.
- [ ] Auth restricted to `@citchennai.net`, verified only.
- [ ] Any timestamp you write to `students/*` or `classrooms/*` is an **ISO
      string**, never a `Timestamp`/`serverTimestamp()`.
- [ ] `attendance_sessions.opened_at`/`closes_at` ARE real Timestamps — the one
      exception to the above.
- [ ] Reading "who's present" filters `attendance` by `status == "present"`,
      not just "does a doc exist for this student in this session."
- [ ] You are not trying to write `attendance` directly — that collection is
      Cloud-Function-only from every client.
- [ ] You are not trying to write `staff/*` from any client — Admin SDK only.
