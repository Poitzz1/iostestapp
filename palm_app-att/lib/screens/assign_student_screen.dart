import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../providers/providers.dart';
import '../services/roster_service.dart';
import '../services/staff_service.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// Advisor/admin roster screen: add a student to a section by email (the server
/// creates the account if needed and emails a setup/verification link), and see
/// the live roster with each student's verification + enrollment status.
class AssignStudentScreen extends ConsumerStatefulWidget {
  const AssignStudentScreen({super.key});

  @override
  ConsumerState<AssignStudentScreen> createState() => _AssignStudentScreenState();
}

class _AssignStudentScreenState extends ConsumerState<AssignStudentScreen> {
  final _emailCtrl = TextEditingController();
  final _classroomCtrl = TextEditingController();
  StaffProfile? _staff;
  String? _section;
  bool _busy = false;
  String? _message;
  bool _messageOk = false;
  List<RosterEntry> _roster = [];
  bool _loadingRoster = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _classroomCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // See AdvisorHomeScreen._load() — staffProfileProvider caches its first
    // fetch, so invalidate before reading or an admin edit to this staff doc
    // (e.g. via the seed script) won't be picked up until app restart.
    ref.invalidate(staffProfileProvider);
    final staff = await ref.read(staffProfileProvider.future);
    if (!mounted) return;
    setState(() {
      _staff = staff;
      _section = (staff?.sections.isNotEmpty ?? false)
          ? staff!.sections.first
          : staff?.section;
      _classroomCtrl.text = staff?.classroomId ?? '';
    });
    if (_section != null) _refreshRoster();
  }

  Future<void> _refreshRoster() async {
    final section = _section;
    if (section == null) return;
    setState(() => _loadingRoster = true);
    try {
      final roster = await ref.read(rosterServiceProvider).sectionRoster(section);
      if (mounted) setState(() => _roster = roster);
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = _rosterErrorMessage(e);
          _messageOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingRoster = false);
    }
  }

  /// Cloud Functions errors reach the UI as a code plus a full async stack
  /// trace, which fills the screen and tells an advisor nothing. Translate the
  /// ones that actually happen in the field.
  ///
  /// `unavailable` in particular is a TRANSPORT failure — the request never
  /// reached Google, so it is never a server or deployment problem. On campus
  /// it almost always means the phone is on a Wi-Fi network with no route out
  /// (or Wi-Fi was toggled off during a fingerprint capture).
  String _rosterErrorMessage(Object e) {
    if (e is FirebaseFunctionsException) {
      switch (e.code) {
        case 'unavailable':
        case 'deadline-exceeded':
          return 'No connection to the server. Check that this phone has '
              'working internet — a campus Wi-Fi network without an internet '
              'route will do this — then tap refresh.';
        case 'unauthenticated':
          return 'Your session expired. Sign out and back in.';
        case 'permission-denied':
          return 'Your account is not authorised to view this section\'s roster.';
        case 'not-found':
          return 'The roster service is not available for this project. '
              'Contact the developer.';
        default:
          return 'Could not load roster: ${e.message ?? e.code}';
      }
    }
    return 'Could not load roster: $e';
  }

  Future<void> _add() async {
    final email = _emailCtrl.text.trim();
    final section = _section;
    if (email.isEmpty || section == null) {
      setState(() {
        _message = 'Enter a student email and pick a section.';
        _messageOk = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await ref.read(rosterServiceProvider).assignStudent(
            studentEmail: email,
            section: section,
            assignedClassroom:
                _classroomCtrl.text.trim().isEmpty ? null : _classroomCtrl.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        _message = result.summary;
        _messageOk = true;
        _emailCtrl.clear();
      });
      _refreshRoster();
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = _friendly(e.toString());
          _messageOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(String e) {
    if (e.contains('permission-denied')) return "You don't advise that section.";
    if (e.contains('invalid-argument')) {
      return 'Check the email — students must be @citchennai.net.';
    }
    return 'Could not add student. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final staff = _staff;
    final sections = staff?.sections ?? const [];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Section Roster'),
      ),
      extendBodyBehindAppBar: true,
      body: ParticleBackground(
        particleCount: 20,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.spacingLg),
            children: [
              GlassmorphicCard(
                margin: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Add a student', style: AppTheme.headlineMedium),
                    const SizedBox(height: AppTheme.spacingMd),
                    if (staff?.isAdmin ?? false)
                      // Admin can type any section.
                      TextFormField(
                        initialValue: _section,
                        style: AppTheme.bodyLarge,
                        decoration: const InputDecoration(
                          labelText: 'Section',
                          hintText: 'CSE-A',
                        ),
                        onChanged: (v) => _section = v.trim(),
                      )
                    else if (sections.isNotEmpty)
                      DropdownButtonFormField<String>(
                        value: _section,
                        decoration: const InputDecoration(labelText: 'Section'),
                        items: sections
                            .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                            .toList(),
                        onChanged: (v) {
                          setState(() => _section = v);
                          _refreshRoster();
                        },
                      ),
                    const SizedBox(height: AppTheme.spacingMd),
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      style: AppTheme.bodyLarge,
                      decoration: const InputDecoration(
                        labelText: 'Student college email',
                        hintText: '23csea001@citchennai.net',
                        prefixIcon: Icon(Icons.email_outlined, color: AppTheme.accentCyan),
                      ),
                    ),
                    const SizedBox(height: AppTheme.spacingMd),
                    TextField(
                      controller: _classroomCtrl,
                      textCapitalization: TextCapitalization.characters,
                      style: AppTheme.bodyLarge,
                      decoration: const InputDecoration(
                        labelText: 'Assigned classroom (optional)',
                        hintText: 'C302',
                        prefixIcon: Icon(Icons.meeting_room_outlined, color: AppTheme.accentCyan),
                      ),
                    ),
                    const SizedBox(height: AppTheme.spacingLg),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _busy ? null : _add,
                        icon: _busy
                            ? const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.person_add_alt_1),
                        label: Text(_busy ? 'Adding…' : 'Add & send invite'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accentCyan,
                          foregroundColor: AppTheme.backgroundDark,
                        ),
                      ),
                    ),
                    if (_message != null) ...[
                      const SizedBox(height: AppTheme.spacingMd),
                      Text(
                        _message!,
                        style: AppTheme.bodySmall.copyWith(
                          color: _messageOk ? AppTheme.successGreen : AppTheme.errorRed,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spacingLg),
              Row(
                children: [
                  Text('Roster${_section != null ? ' · $_section' : ''}',
                      style: AppTheme.headlineLarge),
                  const Spacer(),
                  IconButton(
                    onPressed: _loadingRoster ? null : _refreshRoster,
                    icon: const Icon(Icons.refresh, color: AppTheme.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spacingSm),
              if (_loadingRoster)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator(color: AppTheme.accentCyan)),
                )
              else if (_roster.isEmpty)
                Text('No students in this section yet.', style: AppTheme.bodyMedium)
              else
                ..._roster.map(_rosterTile),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rosterTile(RosterEntry e) {
    final verified = e.emailVerified;
    return GlassmorphicCard(
      margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
      padding: const EdgeInsets.all(AppTheme.spacingMd),
      child: Row(
        children: [
          Icon(
            e.enrolled
                ? Icons.verified_user
                : (verified ? Icons.check_circle_outline : Icons.hourglass_bottom),
            color: e.enrolled
                ? AppTheme.successGreen
                : (verified ? AppTheme.accentCyan : AppTheme.warningAmber),
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.studentId, style: AppTheme.headlineMedium.copyWith(fontSize: 15)),
                if (e.email != null)
                  Text(e.email!, style: AppTheme.labelSmall),
                Text(e.status, style: AppTheme.labelSmall.copyWith(
                  color: e.enrolled
                      ? AppTheme.successGreen
                      : (verified ? AppTheme.accentCyan : AppTheme.warningAmber),
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
