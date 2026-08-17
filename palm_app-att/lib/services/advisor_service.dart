import 'package:cloud_functions/cloud_functions.dart';

/// Coordinator-facing advisor management. Adding an advisor is a single
/// Cloud Function call: the server creates the Auth account if needed,
/// assigns the advisor role + section(s), and emails a setup/verification
/// link — no console or seed-script step required. Both operations go
/// through Cloud Functions because `staff/*` is not client-writable and only
/// a coordinator may call them (see requireCoordinator in functions/index.js).
class AdvisorService {
  final FirebaseFunctions _functions;
  AdvisorService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'asia-south1');

  /// Add (or extend) an advisor by email. Sections are merged with whatever
  /// that advisor already owns — this never removes a section, and never
  /// downgrades an existing coordinator/admin.
  Future<AssignAdvisorResult> assignAdvisor({
    required String advisorEmail,
    required List<String> sections,
    String? classroomId,
  }) async {
    final res = await _functions.httpsCallable('assignAdvisor').call({
      'advisor_email': advisorEmail,
      'sections': sections,
      if (classroomId != null) 'classroom_id': classroomId,
    });
    return AssignAdvisorResult.fromMap((res.data as Map).cast<String, dynamic>());
  }

  Future<List<AdvisorEntry>> listAdvisors() async {
    final res = await _functions.httpsCallable('listAdvisors').call();
    final list = ((res.data as Map)['advisors'] as List?) ?? [];
    return list
        .map((e) => AdvisorEntry.fromMap((e as Map).cast<String, dynamic>()))
        .toList();
  }
}

class AssignAdvisorResult {
  final String email;
  final String role;
  final List<String> sections;
  final bool accountCreated;
  final bool emailVerified;
  final String emailSent; // password_setup | verification | none | failed

  const AssignAdvisorResult({
    required this.email,
    required this.role,
    required this.sections,
    required this.accountCreated,
    required this.emailVerified,
    required this.emailSent,
  });

  factory AssignAdvisorResult.fromMap(Map<String, dynamic> m) => AssignAdvisorResult(
        email: m['email'] as String? ?? '',
        role: m['role'] as String? ?? 'advisor',
        sections: ((m['sections'] as List?) ?? []).map((e) => e.toString()).toList(),
        accountCreated: m['account_created'] as bool? ?? false,
        emailVerified: m['email_verified'] as bool? ?? false,
        emailSent: m['email_sent'] as String? ?? 'none',
      );

  String get summary {
    switch (emailSent) {
      case 'password_setup':
        return '$email added as advisor — a setup email was sent to activate the account.';
      case 'verification':
        return '$email added as advisor — a verification email was sent.';
      case 'none':
        return emailVerified
            ? '$email added as advisor — account already active.'
            : '$email added as advisor.';
      case 'failed':
        return '$email added as advisor, but the email could not be queued '
            '(is the Trigger Email extension installed?).';
      default:
        return '$email added as advisor.';
    }
  }
}

class AdvisorEntry {
  final String uid;
  final String? email;
  final String role; // 'advisor' | 'admin'
  final List<String> sections;
  final String? classroomId;
  final bool emailVerified;

  const AdvisorEntry({
    required this.uid,
    this.email,
    required this.role,
    required this.sections,
    this.classroomId,
    required this.emailVerified,
  });

  factory AdvisorEntry.fromMap(Map<String, dynamic> m) => AdvisorEntry(
        uid: m['uid'] as String? ?? '',
        email: m['email'] as String?,
        role: m['role'] as String? ?? 'advisor',
        sections: ((m['sections'] as List?) ?? []).map((e) => e.toString()).toList(),
        classroomId: m['classroom_id'] as String?,
        emailVerified: m['email_verified'] as bool? ?? false,
      );

  String get status => emailVerified ? 'Active' : 'Pending verification';
}
