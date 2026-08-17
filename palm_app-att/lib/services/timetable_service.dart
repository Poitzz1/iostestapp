import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hand_detector.dart';

/// One period of a section's day, as the server resolved it.
class DayPlanPeriod {
  final int no;
  final String start;
  final String end;

  /// The RESOLVED venue — override or timetable default, already applied
  /// server-side. Null means nothing resolves for this period, and attendance
  /// for it will be rejected `venue_not_resolved` rather than falling back to
  /// some default room.
  final String? venueId;
  final String? venueName;
  final String? staffUid;
  final String? subject;
  final bool isOverride;
  final bool isSubstitute;

  const DayPlanPeriod({
    required this.no,
    required this.start,
    required this.end,
    this.venueId,
    this.venueName,
    this.staffUid,
    this.subject,
    this.isOverride = false,
    this.isSubstitute = false,
  });

  factory DayPlanPeriod.fromMap(Map m) => DayPlanPeriod(
        no: (m['no'] as num).toInt(),
        start: m['start'] as String? ?? '',
        end: m['end'] as String? ?? '',
        venueId: m['venue_id'] as String?,
        venueName: m['venue_name'] as String?,
        staffUid: m['staff_uid'] as String?,
        subject: m['subject'] as String?,
        isOverride: m['is_override'] as bool? ?? false,
        isSubstitute: m['is_substitute'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'no': no, 'start': start, 'end': end,
        'venue_id': venueId, 'venue_name': venueName,
        'staff_uid': staffUid, 'subject': subject,
        'is_override': isOverride, 'is_substitute': isSubstitute,
      };
}

/// The one small document per section per day (build brief §3).
///
/// Deliberately contains NO Wi-Fi fingerprint data — fingerprints are matching
/// secrets and never leave the server. The phone scans, sends what it saw, and
/// the server compares.
class DayPlan {
  final String sectionId;
  final String date;
  final int year;
  final int version;
  final List<DayPlanPeriod> periods;
  final List<Map<String, dynamic>> breaks;
  final int studentWindowMinutes;

  const DayPlan({
    required this.sectionId,
    required this.date,
    required this.year,
    required this.version,
    required this.periods,
    required this.breaks,
    required this.studentWindowMinutes,
  });

  factory DayPlan.fromMap(Map m) => DayPlan(
        sectionId: m['section_id'] as String,
        date: m['date'] as String,
        year: (m['year'] as num?)?.toInt() ?? 0,
        version: (m['version'] as num?)?.toInt() ?? 0,
        periods: ((m['periods'] as List?) ?? const [])
            .map((e) => DayPlanPeriod.fromMap(e as Map))
            .toList(),
        breaks: ((m['breaks'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList(),
        studentWindowMinutes:
            (m['student_window_minutes'] as num?)?.toInt() ?? 5,
      );

  Map<String, dynamic> toJson() => {
        'section_id': sectionId, 'date': date, 'year': year, 'version': version,
        'periods': periods.map((p) => p.toJson()).toList(),
        'breaks': breaks,
        'student_window_minutes': studentWindowMinutes,
      };
}

/// Result of a staff member palm-opening a period.
class OpenedSession {
  final String sessionId;
  final int periodNo;
  final String date;
  final String resolvedVenueId;
  final String venueSource;
  final DateTime closesAt;
  final int windowMinutes;
  final double staffPalmScore;

  const OpenedSession({
    required this.sessionId,
    required this.periodNo,
    required this.date,
    required this.resolvedVenueId,
    required this.venueSource,
    required this.closesAt,
    required this.windowMinutes,
    required this.staffPalmScore,
  });

  factory OpenedSession.fromMap(Map m) => OpenedSession(
        sessionId: m['session_id'] as String,
        periodNo: (m['period_no'] as num).toInt(),
        date: m['date'] as String,
        resolvedVenueId: m['resolved_venue_id'] as String,
        venueSource: m['venue_source'] as String? ?? 'timetable',
        closesAt:
            DateTime.fromMillisecondsSinceEpoch((m['closes_at_ms'] as num).toInt()),
        windowMinutes: (m['window_minutes'] as num?)?.toInt() ?? 5,
        staffPalmScore: (m['staff_palm_score'] as num?)?.toDouble() ?? 0,
      );
}

/// Client for the YEAR-3 timetable / venue / session endpoints.
///
/// Every call here reaches a function that re-checks the year server-side, so a
/// year-1/2/4 section cannot be driven through these paths even if the UI
/// somehow offered it. The client decides nothing: not the venue, not the
/// authorisation, not whether it is break time.
class TimetableService {
  final FirebaseFunctions _functions;
  TimetableService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'asia-south1');

  static String _cacheKey(String sectionId, String date) =>
      'day_plan_${sectionId}_$date';

  /// Today's plan for a section, cached locally and revalidated by VERSION.
  ///
  /// On a bad connection the common case must be cheap: we send the cached
  /// `version` and the server answers `{changed:false}` — a few bytes — instead
  /// of shipping the whole document again. The full plan only crosses the wire
  /// when it has actually changed.
  Future<DayPlan?> dayPlan(String sectionId, {String? date, bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final d = date ?? _todayIst();
    final key = _cacheKey(sectionId, d);

    DayPlan? cached;
    final raw = prefs.getString(key);
    if (raw != null && !forceRefresh) {
      try {
        cached = DayPlan.fromMap(jsonDecode(raw) as Map);
      } catch (_) {
        await prefs.remove(key);
      }
    }

    try {
      final res = await _functions.httpsCallable('getDayPlan').call({
        'section_id': sectionId,
        'date': d,
        if (cached != null && !forceRefresh) 'known_version': cached.version,
      });
      final m = (res.data as Map).cast<String, dynamic>();
      if (m['changed'] == false && cached != null) return cached;
      final plan = DayPlan.fromMap((m['plan'] as Map));
      await prefs.setString(key, jsonEncode(plan.toJson()));
      return plan;
    } catch (e) {
      // Offline or the call failed: a cached plan is far better than nothing,
      // since it still tells staff which period and venue to expect.
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// Palm-verify as the period's staff member and open the student window.
  ///
  /// The 5-minute window starts HERE — the session's life is anchored to a
  /// verified human being present at the start of it, not to a wall clock.
  Future<OpenedSession> openSessionWithPalm({
    required String sectionId,
    required int periodNo,
    required Float32List probeEmbedding,
    required HandSide handSide,
  }) async {
    final res = await _functions.httpsCallable('openSession').call({
      'section_id': sectionId,
      'period_no': periodNo,
      'probe_embedding': probeEmbedding.toList(),
      'hand_side': handSide.label,
    });
    return OpenedSession.fromMap((res.data as Map));
  }

  /// Enrol this staff member's palm. Reuses the student capture pipeline
  /// unchanged; only the destination document differs (`staff/{uid}.palm`).
  Future<void> enrollStaffPalm({
    required Float32List template,
    required HandSide handSide,
    required String modelVersion,
    Map<String, dynamic>? illumination,
    Map<String, dynamic>? pose,
  }) async {
    await _functions.httpsCallable('enrollStaffPalm').call({
      'embedding': template.toList(),
      'hand_side': handSide.label,
      'model_version': modelVersion,
      'illumination': illumination,
      'pose': pose,
    });
  }

  Future<int?> setVenueOverride({
    required String sectionId,
    required String date,
    required int periodNo,
    String? venueId,
    String? reason,
    bool clear = false,
  }) async {
    final res = await _functions.httpsCallable('setVenueOverride').call({
      'section_id': sectionId, 'date': date, 'period_no': periodNo,
      'venue_id': venueId, 'reason': reason, 'clear': clear,
    });
    return ((res.data as Map)['day_plan_version'] as num?)?.toInt();
  }

  Future<int?> setODAssignment({
    required String sectionId,
    required String date,
    required String studentId,
    String? venueId,
    String? reason,
    bool clear = false,
  }) async {
    final res = await _functions.httpsCallable('setODAssignment').call({
      'section_id': sectionId, 'date': date, 'student_id': studentId,
      'venue_id': venueId, 'reason': reason, 'clear': clear,
    });
    return ((res.data as Map)['day_plan_version'] as num?)?.toInt();
  }

  Future<int?> setSubstitution({
    required String sectionId,
    required String date,
    required int periodNo,
    String? substituteStaffUid,
    String? originalStaffUid,
    bool clear = false,
  }) async {
    final res = await _functions.httpsCallable('setStaffSubstitution').call({
      'section_id': sectionId, 'date': date, 'period_no': periodNo,
      'substitute_staff_uid': substituteStaffUid,
      'original_staff_uid': originalStaffUid, 'clear': clear,
    });
    return ((res.data as Map)['day_plan_version'] as num?)?.toInt();
  }

  /// Campus-local date (Asia/Kolkata). Only used to pick a cache key and to
  /// default a request — every decision that matters uses SERVER time.
  static String _todayIst() {
    final ist = DateTime.now().toUtc().add(const Duration(minutes: 330));
    return ist.toIso8601String().substring(0, 10);
  }

  /// Human-readable message for the year-3 rejection codes.
  static String messageFor(Object e) {
    if (e is FirebaseFunctionsException) {
      final m = e.message ?? e.code;
      return switch (m) {
        'not_authorised_for_period' =>
          "You aren't the staff member for this period. Only the timetabled "
              'staff, the section advisor, or a recorded substitute can open it.',
        'staff_not_enrolled' =>
          'Enrol your palm first — tap "Enrol my palm" below.',
        'model_version_mismatch' =>
          'The palm model changed since you enrolled. Please re-enrol your palm.',
        'palm_below_threshold' =>
          "Your palm didn't match closely enough. Try again in even lighting, "
              'holding your hand square to the camera.',
        'venue_not_resolved' =>
          'No venue is set for this period. Add a timetable entry or an '
              'override before opening it.',
        'venue_not_fingerprinted' =>
          "That room has no Wi-Fi fingerprint yet, so every student would fail. "
              'Fingerprint it first.',
        'during_break' => "It's a break for this year — sessions can't open now.",
        'hand_side_mismatch' => 'Wrong hand — you enrolled the other palm.',
        _ => m,
      };
    }
    return '$e';
  }
}
