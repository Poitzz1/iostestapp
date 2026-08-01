import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_ref.dart';

import '../models/attendance_record.dart';
import '../models/attendance_session.dart';

/// Advisor-side session control (spec §7). The advisor opens an attendance
/// window for their section, watches the live marked list, closes early, and
/// applies manual marking (absent / od / other) for students who fail or don't
/// attempt — preserving the human oversight the old advisor-device flow had.
///
/// Session docs use SERVER timestamps; the server enforces the window on every
/// submission regardless of what the client shows.
class SessionService {
  final FirebaseFirestore _firestore;
  SessionService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? appFirestore;

  CollectionReference<Map<String, dynamic>> get _sessions =>
      _firestore.collection('attendance_sessions');

  Future<AttendanceSession> openSession({
    required String classroomId,
    required String section,
    required String advisorId,
    Duration window = const Duration(minutes: 10),
    String? rotatingCode,
  }) async {
    final ref = _sessions.doc();
    final closesAt = Timestamp.fromDate(DateTime.now().add(window));
    await ref.set({
      'classroom_id': classroomId,
      'section': section,
      'advisor_id': advisorId,
      'opened_at': FieldValue.serverTimestamp(),
      'closes_at': closesAt,
      'status': 'open',
      if (rotatingCode != null) 'rotating_code': rotatingCode,
    });
    final snap = await ref.get();
    return AttendanceSession.fromFirestore(snap.data()!, ref.id);
  }

  Future<void> closeSession(String sessionId) async {
    await _sessions.doc(sessionId).update({'status': 'closed'});
  }

  /// The advisor's currently open session, if any.
  Future<AttendanceSession?> myOpenSession(String advisorId) async {
    final snap = await _sessions
        .where('advisor_id', isEqualTo: advisorId)
        .where('status', isEqualTo: 'open')
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return AttendanceSession.fromFirestore(snap.docs.first.data(), snap.docs.first.id);
  }

  /// Live marked list for a session (attendance records as they land).
  Stream<List<AttendanceRecord>> liveRecords(String sessionId) {
    return _firestore
        .collection('attendance')
        .where('session_id', isEqualTo: sessionId)
        .snapshots()
        .map((s) => s.docs
            .map((d) => AttendanceRecord.fromFirestore(d.data(), d.id))
            .toList());
  }

  /// Manual marking (absent / od / other) — the advisor updates the human
  /// oversight fields. Rules allow staff to update `attendance`, but the server
  /// is the only writer of a "present" palm decision.
  Future<void> manualMark({
    required String attendanceId,
    required String status, // absent | od | other
    required String reason,
    required String advisorId,
  }) async {
    await _firestore.collection('attendance').doc(attendanceId).update({
      'status': status,
      'decision_reason': 'manual_$status',
      'manual_reason': reason,
      'marked_by_advisor': advisorId,
      'manual_marked_at': FieldValue.serverTimestamp(),
    });
  }
}
