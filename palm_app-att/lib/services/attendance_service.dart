import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_ref.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/attendance_record.dart';
import '../models/attendance_session.dart';
import '../services/hand_detector.dart';
import 'location_service.dart';
import 'wifi_scan_service.dart';

/// Everything the attendance FLOW does client-side (spec §5). The client only
/// gathers evidence and calls the server — it never decides pass/fail. All
/// verdict logic lives in the `submitAttendance` Cloud Function.
class AttendanceService {
  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;

  AttendanceService({FirebaseFunctions? functions, FirebaseFirestore? firestore})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'asia-south1'),
        _firestore = firestore ?? appFirestore;

  /// Finds the open session for a section, or null. Read-only; the server still
  /// re-checks the window on submit (this is a UX convenience only, spec §5.2).
  Future<AttendanceSession?> openSessionFor(String section) async {
    final snap = await _firestore
        .collection('attendance_sessions')
        .where('section', isEqualTo: section)
        .where('status', isEqualTo: 'open')
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    final s = AttendanceSession.fromFirestore(snap.docs.first.data(), snap.docs.first.id);
    return s.isOpen ? s : null;
  }

  /// Single-use replay-protection token from the server (spec §5.3).
  Future<String> requestNonce() async {
    final res = await _functions.httpsCallable('requestNonce').call();
    return (res.data as Map)['nonce'] as String;
  }

  /// Submit the gathered evidence. Returns the server's decision — the client
  /// renders it, it does not compute it.
  Future<AttendanceDecision> submit({
    required String sessionId,
    required String nonce,
    required Float32List probeEmbedding,
    required HandSide handSide,
    required List<WifiAccessPointInfo> wifi,
    GpsReading? gps,
    required bool isMockLocation,
    required String deviceId,
  }) async {
    final res = await _functions.httpsCallable('submitAttendance').call({
      'session_id': sessionId,
      'nonce': nonce,
      'probe_embedding': probeEmbedding.toList(),
      'hand_side': handSide.label,
      'wifi_scan': wifi.map((a) => a.toPayload()).toList(),
      'gps': gps?.toPayload(),
      'is_mock_location': isMockLocation,
      'device_id': deviceId,
      'client_timestamp': DateTime.now().toIso8601String(),
    });
    return AttendanceDecision.fromMap((res.data as Map).cast<String, dynamic>());
  }

  /// The student's own attendance history (spec §8 — students read only their
  /// own records).
  Stream<List<AttendanceRecord>> myRecords(String studentId) {
    return _firestore
        .collection('attendance')
        .where('student_id', isEqualTo: studentId)
        .snapshots()
        .map((s) => s.docs
            .map((d) => AttendanceRecord.fromFirestore(d.data(), d.id))
            .toList()
          ..sort((a, b) => (b.serverTimestamp ?? DateTime(0))
              .compareTo(a.serverTimestamp ?? DateTime(0))));
  }
}

/// The server's decision, mirrored client-side for display.
class AttendanceDecision {
  final String status; // present | rejected
  final String reason; // decision_reason
  final String? attendanceId;
  final double? palmScore;
  final int? wifiMatchCount;

  const AttendanceDecision({
    required this.status,
    required this.reason,
    this.attendanceId,
    this.palmScore,
    this.wifiMatchCount,
  });

  bool get isPresent => status == 'present';

  factory AttendanceDecision.fromMap(Map<String, dynamic> m) => AttendanceDecision(
        status: m['status'] as String? ?? 'rejected',
        reason: m['decision_reason'] as String? ?? 'unknown',
        attendanceId: m['attendance_id'] as String?,
        palmScore: (m['palm_score'] as num?)?.toDouble(),
        wifiMatchCount: (m['wifi_match_count'] as num?)?.toInt(),
      );

  /// UI message per reason (matches AttendanceRecord.reasonMessage).
  String get message => switch (reason) {
        'ok' => 'Attendance marked present.',
        'outside_session' => 'Attendance is not open for your section right now.',
        'wifi_mismatch' =>
          "You don't appear to be in the classroom. Move inside and try again.",
        'palm_below_threshold' =>
          "Palm didn't match your enrolled template closely enough.",
        'hand_side_mismatch' => 'Wrong hand — you enrolled the other palm.',
        'device_not_bound' => 'This device is not the one registered to your account.',
        'duplicate' => 'You have already been marked for this session.',
        'gps_out_of_campus' => "You don't appear to be on campus.",
        'classroom_not_configured' =>
          'Classroom not configured. Contact your advisor.',
        'not_enrolled' => 'You have not enrolled your palm yet.',
        'model_version_mismatch' =>
          'The palm model has been updated. Please re-enroll your palm — your '
              'previous scan is no longer compatible.',
        'section_not_in_pilot' =>
          'Palm attendance is not yet enabled for your section. Your advisor '
              'will mark attendance manually.',
        'invalid_nonce' => 'Session expired — please try again.',
        _ => 'Attendance could not be verified.',
      };
}
