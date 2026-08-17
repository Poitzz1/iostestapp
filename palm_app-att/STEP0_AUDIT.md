# Step 0 audit — timetable / venue resolution / roles brief

**Date:** 2026-08-16
**Project audited:** `attcit-52e7d`, Firestore database `default` (the one this
app is wired to)
**Method:** live Admin SDK reads of every collection, plus source review of
`functions/index.js`, `firestore.rules`, and the Flutter client.

**Verdict: do not start building yet.** Two of the brief's load-bearing premises
do not match the live project, and one of them trips the brief's own
"cannot be cleanly gated by year → say so and stop" rule. Details in §A and §B.

---

## A. BLOCKER 1 — the "8,000+ students, live college-wide" premise

The brief's risk framing, and most of its hard constraints, rest on:

> "The app is ALREADY LIVE college-wide: 8,000+ students, all years, attendance
> running ~8 times a day today."

That is not what is in this project. Measured, not estimated:

| quantity | brief assumes | actually in `attcit-52e7d` |
|---|---|---|
| students | 8,000+, all years | **37** (17 one schema + 20 another, see §C) |
| students with a palm template | implied all | **3** |
| attendance records, all time | ~8/day × 8,000 | **58 total, across 5 distinct days** |
| distinct attendance days ever | daily | 2026-07-27, 07-28, 07-29, 08-13, 08-16 |
| classrooms | many, fingerprinted | **1** (`C202`), fingerprint has **1 AP** |
| years represented | 1,2,3,4 | **no student has a `year` field at all** |

There is a second body of activity — `verificationEvents`, 256 docs — but it is
from a **different application and a different model family**
(`palm-mnv3l-256-v1…v4`, 1:N cohort matching with `runnerUpId`/`cohortSize`),
spanning 2026-07-15 to 2026-07-23 only. It is not this app's attendance path.

**Why this matters, and why I stopped.** The brief's most expensive requirements
— "years 1/2/4 provably untouched", "blast radius on a live 8,000-student
system", "gate everything on year == 3" — are risk controls sized for a large
live deployment. If that deployment exists, **it is in a different Firebase
project than the one this repository deploys to**, and I have not seen it. In
that case the entire audit below is against the wrong system and needs redoing
against the right one.

If instead the 8,000 figure describes an intended future scale, the constraints
are still worth honouring as design discipline, but "provably untouched for
8,000 live students" is not a thing that can be demonstrated here, and I should
not claim it.

**Needed before build: which project is the live one?**

---

## B. BLOCKER 2 — year-gating is not implementable today

The brief is explicit and repeated: every new path must be gated on
`section.year == 3`, and *"If a change cannot be cleanly gated by year, say so
and stop rather than shipping it globally."*

That condition is met right now. The year cannot be resolved for the students
this app actually serves:

1. **No student document has a `year` field.** 0 of 37.
2. A `sections` collection **does** exist (17 docs) and every one has `year: 3`.
   Its document ids are single letters: `A B C D E F G H I J K L M N O P Q`.
3. The students this mobile app serves carry `section: "CSE-F"`.
4. **Overlap between the app's section values and `sections/` ids: zero.**

So `student → section → sections/{id} → year` is a broken chain: `"CSE-F"` is
not a document in `sections/`. There is no path from a mobile student to a year.

This is fixable, but it is a **prerequisite**, not an implementation detail. It
needs a decision (§F, Q3) about which section namespace is authoritative, and a
migration. Building venue resolution before that would mean either shipping it
ungated (explicitly forbidden) or gating it on a value that is always absent
(so it would never activate, and would silently do nothing).

---

## C. Two parallel systems share this project

This is the single most important structural finding, and nothing in the brief
accounts for it.

**Students are split across two disjoint schemas** — 17 snake_case, 20
camelCase, **zero documents carrying both**:

| | mobile app (this repo) | web app |
|---|---|---|
| identity | `student_id` | `studentId` |
| section | `section` (`"CSE-F"`) | `sectionId` (`"A"`, `"B"`) |
| consent | `consent`, `consent_at` | `consentGiven`, `consentTimestamp` |
| status | derived from `embedding` | `enrollmentStatus` |
| biometric | `embedding`, `hand_side`, `model_version` | (not in this collection) |
| count | 17 | 20 |

**Roles exist twice, with different vocabularies:**

| | `staff/{uid}` (mobile reads this) | `users/{uid}` (web) |
|---|---|---|
| docs | 3 | 5 |
| roles present | `admin` ×3 | `advisor` ×2, `coordinator` ×1, `hod` ×1 |
| section link | `sections: []` | `assignedSection` |

**The brief's §7 role hierarchy already exists — in `users/`.** `advisor`,
`coordinator`, `hod` are exactly the three roles the brief specifies, already
modelled. But `firestore.rules` and every Cloud Function read `staff/`. Building
§7 into `staff/` would create a **third** source of truth for who someone is.

**Two incompatible palm models are in play:**

- mobile: `palm_256_l2_fp32_v5`, 1:1 verification, threshold 0.5508
- web: `palm-mnv3l-256-v1…v4`, 1:N cohort matching

**Live bug found while auditing.** `assignAdvisor` and `listAdvisors` (deployed
2026-08-16) gate on `requireCoordinator`, which demands
`staff/{uid}.role === "coordinator"`. All three `staff` documents have
`role: "admin"`. **No account can currently call either function.**

---

## D. What already exists (extend, do not duplicate)

| brief asks for | status |
|---|---|
| `sections/{section_id}` | **EXISTS** — 17 docs, `{sectionId, advisorUid, year, department}`. Missing `name`, `coordinator_uid`, `active`. Namespace clash with mobile (§B). |
| `staff/{uid}` roles | **PARTIAL** — collection exists, all `admin`. Real role set lives in `users/`. No `advisor_of`, no `coordinator_of_year`. |
| `classrooms/{venue_id}` | **EXISTS**, 1 doc. Already has `wifi_fingerprint` **with `typical_rssi`**, `min_bssid_matches`, `building`, `floor`, `room`, lat/lng. Missing `is_lab`, `rssi_tolerance`. |
| working-day calendar | **EXISTS, unasked-for** — `academicCalendar`, 122 dated docs `{date, isWorkingDay, reason}`, 2026-06-01 → 2026-09-30, 88 working days. **This answers §10 Q2 below.** |
| `attendance_sessions` | **EXISTS** — `{advisor_id, classroom_id, closes_at, opened_at, section, status}`. No `date`, `period_no`, `resolved_venue_id`, `opened_by_uid`, `opened_via_palm`. Created client-side under rule `isStaff() && advisor_id == uid` — **no palm check, no period concept**. |
| `attendance/{id}` | **EXISTS** — rich evidence trail already (palm score/threshold, wifi match count + matched BSSIDs, GPS, device, illumination + pose telemetry). No `period_no`, `date`, `resolved_venue_id`, `was_od`, `was_substitute`, `wifi_match_score`. |

**Does not exist at all:** any timetable / period / schedule concept;
`day_plans`; `venue_overrides`; `staff_substitutions`; `od_assignments`; staff
palm enrolment (no `palm` field on any staff doc); break windows.

**Client-side caching today:** `StudentService` caches the student's own profile
in `SharedPreferences` (local-first, background sync). The open session is a
**live Firestore query per attendance attempt**. There is no day-plan-shaped
cache and no `version`-keyed refetch — §3 is genuinely new work.

**Venue today:** confirmed as the brief suspected — a static
`students/{id}.assigned_classroom` string, set by `assignStudent` or the seed
script, never resolved.

---

## E. Blast-radius report (required by SCOPE)

Shared code paths a year-3 section would traverse differently from years 1/2/4:

| shared path | today | risk |
|---|---|---|
| **`submitAttendance`** (`functions/index.js`) | single entry point for **all** attendance, every year | **Highest.** Venue resolution + break enforcement land here. Must branch on year *before* any new logic, after loading the student. |
| `firestore.rules` → `students/{studentId}` | `studentWritableFields()` is a `hasOnly()` allowlist | Any new student field must be added or **the entire write is rejected silently**. Not year-gatable — rules apply to all years. |
| `firestore.rules` → `attendance_sessions` | `create: isStaff() && advisor_id == request.auth.uid` | §5 palm-verified opening must move creation server-side. Tightening this rule affects **all years'** session opening. |
| `firestore.rules` → `classrooms` | `get, list: if signedIn()` | Clients can currently read fingerprints. §3 forbids shipping them. Fixing that is **not year-gatable**. |
| `staff/{uid}` + `isAdmin()` | used by `assignStudent`, `classrooms` writes, `students` admin writes | Adding advisor/coordinator/hod changes authorisation for every year. |
| `AttendanceService.submit` (client) | one code path, no year concept | Adding `period_no`/day-plan fields changes the payload for all years. |
| `CaptureController` / `StudentProfile` | shared by enrolment and attendance | Staff palm enrolment (§5) reuses these. Destination doc differs only. |

**Cleanly gatable:** venue resolution, break enforcement, day-plan consumption,
OD/override/substitution lookup — all sit inside `submitAttendance` and can
branch on year immediately after the student doc is read.

**NOT cleanly gatable by year, flagged per the brief's instruction:**

1. **`classrooms` client read access.** §3 says fingerprints must never reach
   clients. That is a rules change affecting every year at once. Either accept a
   global change, or leave the leak in place for years 1/2/4 — please decide.
2. **`students` writable-field allowlist.** Rules cannot see a student's year
   without a `get()` on another document per write (expensive, and currently
   impossible per §B).
3. **`attendance_sessions` create rule.** Moving session creation server-side to
   enforce palm verification necessarily removes the client-create path for
   everyone.

---

## F. Questions that block the build

1. **§5 timing (brief says ask, do not guess).** Is attendance for period N
   marked **(a) during period N**, or **(b) after period N ends**, in the
   changeover before N+1? Determines the session window and the default period.

2. **Which Firebase project is the live 8,000-student system?** (§A) If it is
   this one, the numbers say otherwise and the scale constraints need
   re-framing. If it is another, this audit must be redone there.

3. **Which section namespace is authoritative?** (§B) `sections/{A..Q}` as used
   by the web app, or `"CSE-F"`-style strings as used by this app? Year gating
   is impossible until student → section → year resolves. Related: should
   `staff/` and `users/` be reconciled into one role source, or does the mobile
   app switch to reading `users/`?

4. **§10 Q3 — electives.** Can a student ever legitimately attend with a section
   other than their own? Current design assumes no; OD assignment is per-student
   per-day and would partly cover it.

**§10 Q2 (Saturdays) — answered by the data, please confirm:** `academicCalendar`
contains 17 Saturdays, **0 of them working days**. So weekday 6 never occurs and
the timetable needs Mon–Fri only. Flagging because the brief's schema says
`weekday (1=Mon..6=Sat)`.

---

## G. Other findings worth knowing before design

- **RSSI-profile matching (§6) has almost nothing to work with today.** The only
  fingerprinted room, `C202`, has **one** AP. "Require the strongest N APs to
  overlap" is not meaningful at N=1. Every venue needs re-fingerprinting with
  several APs before §6 can be evaluated at all — and the brief's own rule
  ("a venue cannot be an override target without a fingerprint") means **exactly
  one room in the system is currently a legal venue**.
- `min_bssid_matches` on C202 is 1, deliberately: its two recorded BSSIDs are the
  same AP on 2.4 GHz and 5 GHz, and only one is visible at a time. Any
  "strongest N APs" logic must not assume distinct physical APs.
- The brief says model work is on hold — noted, and nothing here touches the
  model, threshold, ROI crop, or verification math. Note though that `issue.md`
  records genuine pairs losing ~0.2 cosine to lighting and ~0.19 to palm angle
  against a 0.077 margin. Session opening in §5 adds **staff** palm verification
  on top of that, so staff will hit the same false-reject rate. Worth deciding
  now what happens when a legitimate advisor cannot open the session.
- `verificationEvents` shows the web app doing **1:N cohort matching**. If that
  app is the "live" one, its security properties differ fundamentally from this
  app's 1:1 verification, and §7's role rules would need writing for both.
