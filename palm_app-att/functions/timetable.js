/**
 * Timetable, venue resolution, per-year breaks and Wi-Fi profile matching.
 *
 * SCOPE — YEAR 3 ONLY. Every export here is reached only after the caller has
 * confirmed the student's section is year 3 (see `isYear3Section`). Years 1, 2
 * and 4 must never enter these paths; they keep the pre-existing behaviour
 * unchanged. The year check is done on the SECTION document, server-side, and
 * failing to resolve a year means "not year 3" — i.e. the new logic is opt-in,
 * never a default.
 *
 * Nothing in this file touches the palm model, the threshold, the ROI crop or
 * the verification math. Model work is on hold.
 */

const IST_OFFSET_MIN = 330; // Asia/Kolkata, no DST

/** Minutes since midnight for "HH:MM". */
export function hhmmToMinutes(s) {
  const m = /^(\d{2}):(\d{2})$/.exec(String(s || ""));
  if (!m) return null;
  return Number(m[1]) * 60 + Number(m[2]);
}

/**
 * SERVER time, expressed in the campus timezone.
 *
 * Never accept a client clock for a period/break/session decision — a phone
 * with a wound-back clock would otherwise walk through a break window. Cloud
 * Functions run in UTC, so the offset is applied explicitly rather than relying
 * on the container's locale.
 */
export function campusNow(nowMs = Date.now()) {
  const d = new Date(nowMs + IST_OFFSET_MIN * 60000);
  return {
    date: d.toISOString().slice(0, 10), // YYYY-MM-DD, campus-local
    minutes: d.getUTCHours() * 60 + d.getUTCMinutes(),
    weekday: d.getUTCDay() === 0 ? 7 : d.getUTCDay(), // 1=Mon .. 7=Sun
  };
}

/**
 * The section document, or null. This is the ONLY place a year is established.
 *
 * Returns null rather than throwing when the section does not exist, because a
 * missing section must mean "not year 3" (fall back to legacy behaviour), not
 * "crash the attendance path for everybody".
 */
export async function loadSection(db, sectionId) {
  if (!sectionId) return null;
  try {
    const snap = await db.doc(`sections/${sectionId}`).get();
    return snap.exists ? { id: snap.id, ...snap.data() } : null;
  } catch (_) {
    return null;
  }
}

/**
 * THE YEAR GATE. Everything new in this build hangs off this returning true.
 *
 * Deliberately strict: only an explicit `year === 3` on the section document
 * opens the new path. Unknown section, missing year, or any other year keeps
 * the student on the existing logic — which is what makes years 1/2/4
 * unreachable from here.
 */
export function isYear3Section(section) {
  return !!section && Number(section.year) === 3;
}

/** The per-year period/break template. Years without one simply have no new logic. */
export async function loadScheduleTemplate(db, year) {
  try {
    const snap = await db.doc(`schedule_templates/${year}`).get();
    return snap.exists ? snap.data() : null;
  } catch (_) {
    return null;
  }
}

/**
 * Is campus-local `minutes` inside one of this year's break windows?
 *
 * Breaks are PER YEAR by design: two sections in the same building can
 * legitimately be in different states at the same moment, so there is
 * deliberately no global break window anywhere in this codebase.
 */
export function breakAt(template, minutes) {
  if (!template || !Array.isArray(template.breaks)) return null;
  for (const b of template.breaks) {
    const s = hhmmToMinutes(b.start);
    const e = hhmmToMinutes(b.end);
    if (s === null || e === null) continue;
    if (minutes >= s && minutes < e) return b;
  }
  return null;
}

/** The period containing campus-local `minutes`, or null (between/outside periods). */
export function periodAt(template, minutes) {
  if (!template || !Array.isArray(template.periods)) return null;
  for (const p of template.periods) {
    const s = hhmmToMinutes(p.start);
    const e = hhmmToMinutes(p.end);
    if (s === null || e === null) continue;
    if (minutes >= s && minutes < e) return p;
  }
  return null;
}

export function periodByNo(template, periodNo) {
  if (!template || !Array.isArray(template.periods)) return null;
  return template.periods.find((p) => Number(p.no) === Number(periodNo)) || null;
}

/**
 * Resolve the venue for (section, date, period, student), in the brief's
 * precedence order:
 *
 *   1. OD assignment for this student on this date  -> OD venue
 *   2. Venue override for (section, date, period)   -> override venue
 *   3. Weekly timetable default (section, weekday, period)
 *   4. nothing -> null, and the caller MUST reject `venue_not_resolved`
 *
 * There is deliberately no fallback to `students.assigned_classroom` here. A
 * silent fall back to a default room is exactly the failure the brief forbids:
 * it would validate a student against the Wi-Fi of a room the class is not in,
 * and do it invisibly.
 *
 * `reads` may be a transaction (tx.get) or the db itself; both expose .get().
 */
export async function resolveVenue(db, { sectionId, date, periodNo, studentId, weekday }, reads = null) {
  const get = async (path) => {
    const ref = db.doc(path);
    const snap = reads ? await reads.get(ref) : await ref.get();
    return snap.exists ? snap.data() : null;
  };

  // 1. OD assignment — whole-day, so it wins for every period that day.
  if (studentId) {
    const od = await get(`od_assignments/${date}_${studentId}`);
    if (od && od.venue_id) {
      return { venueId: od.venue_id, source: "od", wasOd: true, wasSubstitute: false, reason: od.reason ?? null };
    }
  }

  // 2. Per-period override (the "class moved to a lab today" case).
  const ov = await get(`venue_overrides/${sectionId}_${date}_${periodNo}`);
  if (ov && ov.venue_id) {
    return { venueId: ov.venue_id, source: "override", wasOd: false, wasSubstitute: false, reason: ov.reason ?? null };
  }

  // 3. Weekly recurring default.
  const tt = await get(`timetable/${sectionId}/entries/${weekday}_${periodNo}`);
  if (tt && tt.venue_id) {
    return { venueId: tt.venue_id, source: "timetable", wasOd: false, wasSubstitute: false, staffUid: tt.staff_uid ?? null, subject: tt.subject ?? null };
  }

  return null;
}

/** Who is allowed to open (section, date, period): timetabled staff, advisor, or recorded substitute. */
export async function resolveAuthorisedOpeners(db, { sectionId, date, periodNo, weekday, section }) {
  const out = new Set();
  if (section?.advisor_uid) out.add(section.advisor_uid);

  const tt = await db.doc(`timetable/${sectionId}/entries/${weekday}_${periodNo}`).get();
  if (tt.exists && tt.data().staff_uid) out.add(tt.data().staff_uid);

  const sub = await db.doc(`staff_substitutions/${sectionId}_${date}_${periodNo}`).get();
  const substituteUid = sub.exists ? sub.data().substitute_staff_uid : null;
  if (substituteUid) out.add(substituteUid);

  return { openers: out, substituteUid };
}

/**
 * Wi-Fi match on the RSSI-RANKED PROFILE, not bare BSSID set overlap.
 *
 * Why: routers here are roof-mounted and rooms are ~7x6x3 m, so room 301 and
 * room 302 see nearly the same APs at nearly the same strength. Presence-only
 * matching cannot separate them, and saying it can would be a false claim about
 * what this proves.
 *
 * The score is deliberately reported for EVERY attempt (including failures) so
 * `rssi_tolerance` can be tuned from real data later instead of guessed.
 *
 * Returns { ok, score, matched, rankOverlap, withinTolerance, registeredCount }.
 * `score` is 0..1 — the mean of rank overlap and RSSI agreement.
 *
 * HONEST LIMIT: this gives building/floor/zone-level confidence, not reliable
 * room-level proof. The real presence anchor is the staff-opened, palm-verified,
 * time-boxed session; Wi-Fi is a supporting check.
 */
export function matchWifiProfile(fingerprint, scan, opts = {}) {
  const topN = opts.top_n ?? 4;
  const tolerance = opts.rssi_tolerance ?? 12; // dB
  const minMatches = opts.min_bssid_matches ?? 1;

  const fp = (fingerprint || [])
    .filter((a) => a && a.bssid)
    .map((a) => ({ bssid: String(a.bssid).toLowerCase(), rssi: Number(a.typical_rssi ?? a.rssi ?? NaN) }));
  const sc = (scan || [])
    .filter((a) => a && a.bssid)
    .map((a) => ({ bssid: String(a.bssid).toLowerCase(), rssi: Number(a.rssi ?? a.level ?? NaN) }));

  if (fp.length === 0) {
    return { ok: false, score: 0, matched: [], rankOverlap: 0, withinTolerance: 0, registeredCount: 0 };
  }

  const scByBssid = new Map(sc.map((a) => [a.bssid, a.rssi]));
  const matched = fp.filter((a) => scByBssid.has(a.bssid)).map((a) => a.bssid);

  // Rank overlap: of the fingerprint's strongest topN APs, how many are seen?
  // Note a fingerprint may list one physical AP twice (2.4 GHz + 5 GHz), and
  // only one band is usually visible, so this is a fraction of what EXISTS,
  // never an assumption that all N are separate radios.
  const strongest = [...fp].sort((a, b) => (b.rssi || -999) - (a.rssi || -999)).slice(0, Math.min(topN, fp.length));
  const rankHits = strongest.filter((a) => scByBssid.has(a.bssid)).length;
  const rankOverlap = strongest.length ? rankHits / strongest.length : 0;

  // RSSI agreement over the APs we actually saw.
  let within = 0, comparable = 0;
  for (const a of fp) {
    const seen = scByBssid.get(a.bssid);
    if (seen === undefined || !isFinite(seen) || !isFinite(a.rssi)) continue;
    comparable++;
    if (Math.abs(seen - a.rssi) <= tolerance) within++;
  }
  const rssiAgreement = comparable ? within / comparable : 0;

  // No usable RSSI on either side (older fingerprints) -> fall back to overlap
  // alone rather than scoring 0 and locking everyone out.
  const score = comparable ? (rankOverlap + rssiAgreement) / 2 : rankOverlap;

  const ok =
    matched.length >= minMatches &&
    rankOverlap >= (opts.min_rank_overlap ?? 0.5) &&
    (comparable === 0 || rssiAgreement >= (opts.min_rssi_agreement ?? 0.5));

  return {
    ok,
    score: Math.round(score * 1000) / 1000,
    matched,
    rankOverlap: Math.round(rankOverlap * 1000) / 1000,
    withinTolerance: within,
    registeredCount: fp.length,
  };
}

/**
 * Build the one-document-per-section-per-day plan the client caches (§3).
 *
 * NEVER include wifi_fingerprint. Fingerprints are matching secrets: shipping
 * them bloats the payload and hands an attacker the exact target to spoof. The
 * client scans and sends what it sees; the server alone compares.
 */
export async function buildDayPlan(db, { sectionId, date }) {
  const section = await loadSection(db, sectionId);
  if (!isYear3Section(section)) return null;

  const template = await loadScheduleTemplate(db, section.year);
  if (!template) return null;

  const d = new Date(`${date}T00:00:00Z`);
  const weekday = d.getUTCDay() === 0 ? 7 : d.getUTCDay();

  const periods = [];
  for (const p of template.periods || []) {
    const [ttSnap, ovSnap, subSnap] = await Promise.all([
      db.doc(`timetable/${sectionId}/entries/${weekday}_${p.no}`).get(),
      db.doc(`venue_overrides/${sectionId}_${date}_${p.no}`).get(),
      db.doc(`staff_substitutions/${sectionId}_${date}_${p.no}`).get(),
    ]);
    const tt = ttSnap.exists ? ttSnap.data() : null;
    const ov = ovSnap.exists ? ovSnap.data() : null;
    const sub = subSnap.exists ? subSnap.data() : null;

    const venueId = ov?.venue_id ?? tt?.venue_id ?? null;
    let venueName = null;
    if (venueId) {
      const room = await db.doc(`classrooms/${venueId}`).get();
      // Name only — deliberately NOT the fingerprint.
      if (room.exists) venueName = room.data().room ?? venueId;
    }

    periods.push({
      no: p.no,
      start: p.start,
      end: p.end,
      venue_id: venueId,
      venue_name: venueName,
      staff_uid: sub?.substitute_staff_uid ?? tt?.staff_uid ?? null,
      subject: tt?.subject ?? null,
      is_override: !!ov,
      is_substitute: !!sub,
    });
  }

  const odSnap = await db.collection("od_assignments").where("section_id", "==", sectionId).where("date", "==", date).get();
  const od = odSnap.docs.map((x) => ({ student_id: x.data().student_id, venue_id: x.data().venue_id }));

  return {
    section_id: sectionId,
    date,
    year: section.year,
    periods,
    breaks: (template.breaks || []).map((b) => ({ start: b.start, end: b.end, label: b.label ?? null })),
    od,
    student_window_minutes: template.student_window_minutes ?? 5,
    generated_at: new Date().toISOString(),
  };
}

/** Write the day plan, bumping `version` so clients can cheaply detect staleness. */
export async function regenerateDayPlan(db, { sectionId, date }) {
  const plan = await buildDayPlan(db, { sectionId, date });
  if (!plan) return null;
  const ref = db.doc(`day_plans/${sectionId}_${date}`);
  const prev = await ref.get();
  const version = (prev.exists ? Number(prev.data().version ?? 0) : 0) + 1;
  await ref.set({ ...plan, version }, { merge: false });
  return { ...plan, version };
}
