/// One attendance decision (spec §8). Written ONLY by the `submitAttendance`
/// Cloud Function — clients can never write this collection directly. The
/// client reads its own records back to show the result and evidence trail.
class AttendanceRecord {
  final String attendanceId;
  final String sessionId;
  final String studentId;
  final String? classroomId;
  final String status; // present | rejected | absent | od | other
  final String decisionReason;
  final double? palmScore;
  final double? palmThresholdUsed;
  final String? modelVersion;
  final List<String> wifiMatchedBssids;
  final int? wifiMatchCount;
  final double? gpsCampusDistanceM;
  final bool? isMockLocation;
  final DateTime? serverTimestamp;

  const AttendanceRecord({
    required this.attendanceId,
    required this.sessionId,
    required this.studentId,
    this.classroomId,
    required this.status,
    required this.decisionReason,
    this.palmScore,
    this.palmThresholdUsed,
    this.modelVersion,
    this.wifiMatchedBssids = const [],
    this.wifiMatchCount,
    this.gpsCampusDistanceM,
    this.isMockLocation,
    this.serverTimestamp,
  });

  bool get isPresent => status == 'present';

  /// Human-readable explanation for the UI, keyed off `decision_reason`.
  String get reasonMessage => switch (decisionReason) {
        'ok' => 'Attendance marked present.',
        'outside_session' => 'Attendance is not open for your section right now.',
        'wifi_mismatch' =>
          "You don't appear to be in the classroom. Move inside and try again.",
        'palm_below_threshold' =>
          "Palm didn't match your enrolled template closely enough.",
        'hand_side_mismatch' =>
          'Wrong hand — you enrolled the other palm.',
        'device_not_bound' =>
          'This device is not the one registered to your account.',
        'duplicate' => 'You have already been marked for this session.',
        'gps_out_of_campus' => "You don't appear to be on campus.",
        'model_version_mismatch' =>
          'Enrolled under an older palm model — re-enrollment required.',
        'section_not_in_pilot' =>
          'Palm attendance is not yet enabled for this section.',
        _ => 'Attendance could not be verified.',
      };

  factory AttendanceRecord.fromFirestore(Map<String, dynamic> d, String id) {
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      try {
        return (v as dynamic).toDate() as DateTime;
      } catch (_) {
        return DateTime.tryParse(v.toString());
      }
    }

    return AttendanceRecord(
      attendanceId: id,
      sessionId: d['session_id'] as String? ?? '',
      studentId: d['student_id'] as String? ?? '',
      classroomId: d['classroom_id'] as String?,
      status: d['status'] as String? ?? 'rejected',
      decisionReason: d['decision_reason'] as String? ?? 'unknown',
      palmScore: (d['palm_score'] as num?)?.toDouble(),
      palmThresholdUsed: (d['palm_threshold_used'] as num?)?.toDouble(),
      modelVersion: d['model_version'] as String?,
      wifiMatchedBssids:
          ((d['wifi_matched_bssids'] as List?) ?? []).map((e) => e.toString()).toList(),
      wifiMatchCount: (d['wifi_match_count'] as num?)?.toInt(),
      gpsCampusDistanceM: (d['gps_campus_distance_m'] as num?)?.toDouble(),
      isMockLocation: d['is_mock_location'] as bool?,
      serverTimestamp: parseTs(d['server_timestamp']),
    );
  }
}
