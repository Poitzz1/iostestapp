import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_ref.dart';

/// Advisor/admin role, backed by a `staff/{uid}` document provisioned
/// out-of-band (Firebase console / an admin tool). Its existence is authority;
/// `role` distinguishes advisor from admin. Students have no staff doc.
class StaffProfile {
  final String uid;
  final String role; // 'advisor' | 'admin'
  final List<String> sections; // all sections this advisor owns
  final String? section; // convenience: the primary section (sections[0])
  final String? classroomId; // advisor's default classroom
  final String? name;

  const StaffProfile({
    required this.uid,
    required this.role,
    this.sections = const [],
    this.section,
    this.classroomId,
    this.name,
  });

  bool get isAdmin => role == 'admin';
  bool get isAdvisor => role == 'advisor' || role == 'admin';

  factory StaffProfile.fromFirestore(Map<String, dynamic> d, String uid) {
    final sections = ((d['sections'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    return StaffProfile(
        uid: uid,
        role: d['role'] as String? ?? 'advisor',
        sections: sections,
        // Prefer the explicit `section` field; else the first of `sections`.
        section: (d['section'] as String?) ??
            (sections.isNotEmpty ? sections.first : null),
        classroomId: d['classroom_id'] as String?,
        name: d['name'] as String?,
      );
  }
}

class StaffService {
  final FirebaseFirestore _firestore;
  StaffService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? appFirestore;

  /// Returns the staff profile for a uid, or null if the user is not staff.
  Future<StaffProfile?> profileFor(String uid) async {
    final snap = await _firestore.collection('staff').doc(uid).get();
    if (!snap.exists) return null;
    return StaffProfile.fromFirestore(snap.data()!, uid);
  }
}
