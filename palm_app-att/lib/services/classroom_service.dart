import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_ref.dart';

import '../models/classroom.dart';
import 'wifi_scan_service.dart';

/// Reads classrooms and writes the Wi-Fi fingerprint. STAFF ONLY — enforced by
/// firestore.rules, which no longer lets ordinary students read this collection
/// at all.
///
/// The reason is that these documents carry `wifi_fingerprint`, and a
/// fingerprint is a matching SECRET: handing it to a client tells an attacker
/// exactly which BSSIDs at which strengths to fake. Students never needed it —
/// the phone scans, sends what it saw, and `submitAttendance` does the
/// comparison server-side. The only in-app reader is the staff fingerprint
/// capture screen.
class ClassroomService {
  final FirebaseFirestore _firestore;
  ClassroomService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? appFirestore;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('classrooms');

  Future<Classroom?> get(String classroomId) async {
    final snap = await _col.doc(classroomId).get();
    if (!snap.exists) return null;
    return Classroom.fromFirestore(snap.data()!);
  }

  Future<List<Classroom>> all() async {
    final snap = await _col.get();
    return snap.docs.map((d) => Classroom.fromFirestore(d.data())).toList();
  }

  /// Admin fingerprint capture (§7): write the chosen AP set onto the
  /// classroom. Preserves existing geo/config fields via merge.
  ///
  /// [minBssidMatches] is clamped to the number of APs actually stored. The
  /// server rejects a submission unless it matches at least this many of the
  /// registered BSSIDs, so a fingerprint of 1 AP with a threshold of 2 is
  /// unsatisfiable — every student in the room would be refused with
  /// `wifi_mismatch` and nothing in the UI would explain why.
  Future<void> saveFingerprint(
    String classroomId,
    List<WifiAccessPointInfo> aps, {
    int minBssidMatches = 2,
  }) async {
    if (aps.isEmpty) {
      throw ArgumentError('Refusing to save an empty fingerprint for $classroomId');
    }
    final threshold = minBssidMatches.clamp(1, aps.length);
    await _col.doc(classroomId).set({
      'classroom_id': classroomId,
      'wifi_fingerprint': aps
          .map((a) => {'bssid': a.bssid.toLowerCase(), 'ssid': a.ssid, 'typical_rssi': a.rssi})
          .toList(),
      'min_bssid_matches': threshold,
      'updated_at': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }
}
