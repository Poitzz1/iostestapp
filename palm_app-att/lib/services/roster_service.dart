import 'package:cloud_functions/cloud_functions.dart';

/// Advisor-facing roster management (add students to a section, view the live
/// roster). Both operations go through Cloud Functions because the roster
/// fields (`section`, `assigned_classroom`) are NOT student-writable and
/// setting them + emailing a verification link needs the Admin SDK.
class RosterService {
  final FirebaseFunctions _functions;
  RosterService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'asia-south1');

  /// Add a student to [section] (and optionally a classroom). The server
  /// creates the account if needed and emails a setup/verification link.
  Future<AssignResult> assignStudent({
    required String studentEmail,
    required String section,
    String? assignedClassroom,
  }) async {
    final res = await _functions.httpsCallable('assignStudent').call({
      'student_email': studentEmail,
      'section': section,
      if (assignedClassroom != null) 'assigned_classroom': assignedClassroom,
    });
    return AssignResult.fromMap((res.data as Map).cast<String, dynamic>());
  }

  Future<List<RosterEntry>> sectionRoster(String section) async {
    final res = await _functions
        .httpsCallable('listSectionRoster')
        .call({'section': section});
    final list = ((res.data as Map)['roster'] as List?) ?? [];
    return list
        .map((e) => RosterEntry.fromMap((e as Map).cast<String, dynamic>()))
        .toList();
  }
}

class AssignResult {
  final String studentId;
  final String section;
  final bool accountCreated;
  final bool emailVerified;
  final String emailSent; // password_setup | verification | none | failed

  const AssignResult({
    required this.studentId,
    required this.section,
    required this.accountCreated,
    required this.emailVerified,
    required this.emailSent,
  });

  factory AssignResult.fromMap(Map<String, dynamic> m) => AssignResult(
        studentId: m['student_id'] as String? ?? '',
        section: m['section'] as String? ?? '',
        accountCreated: m['account_created'] as bool? ?? false,
        emailVerified: m['email_verified'] as bool? ?? false,
        emailSent: m['email_sent'] as String? ?? 'none',
      );

  String get summary {
    final id = studentId;
    switch (emailSent) {
      case 'password_setup':
        return '$id added — a setup email was sent to activate the account.';
      case 'verification':
        return '$id added — a verification email was sent.';
      case 'none':
        return emailVerified
            ? '$id added — account already active.'
            : '$id added.';
      case 'failed':
        return '$id added to the section, but the email could not be queued '
            '(is the Trigger Email extension installed?).';
      default:
        return '$id added.';
    }
  }
}

class RosterEntry {
  final String studentId;
  final String? email;
  final String? assignedClassroom;
  final bool enrolled; // palm template captured
  final bool accountExists;
  final bool emailVerified;

  const RosterEntry({
    required this.studentId,
    this.email,
    this.assignedClassroom,
    required this.enrolled,
    required this.accountExists,
    required this.emailVerified,
  });

  factory RosterEntry.fromMap(Map<String, dynamic> m) => RosterEntry(
        studentId: m['student_id'] as String? ?? '',
        email: m['email'] as String?,
        assignedClassroom: m['assigned_classroom'] as String?,
        enrolled: m['enrolled'] as bool? ?? false,
        accountExists: m['account_exists'] as bool? ?? false,
        emailVerified: m['email_verified'] as bool? ?? false,
      );

  /// Roster status for the advisor's list.
  String get status {
    if (!accountExists) return 'Invited';
    if (!emailVerified) return 'Pending verification';
    return enrolled ? 'Active · palm enrolled' : 'Verified · no palm yet';
  }
}
