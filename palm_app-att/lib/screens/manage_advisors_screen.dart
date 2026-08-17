import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../providers/providers.dart';
import '../services/advisor_service.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// Coordinator-only screen: the advisor list. A coordinator adds an advisor
/// by email + section(s) here and the server does everything else —
/// creates the account if needed, assigns the advisor role, and emails a
/// setup/verification link. No manual Firebase console step, ever.
class ManageAdvisorsScreen extends ConsumerStatefulWidget {
  const ManageAdvisorsScreen({super.key});

  @override
  ConsumerState<ManageAdvisorsScreen> createState() => _ManageAdvisorsScreenState();
}

class _ManageAdvisorsScreenState extends ConsumerState<ManageAdvisorsScreen> {
  final _emailCtrl = TextEditingController();
  final _sectionsCtrl = TextEditingController();
  final _classroomCtrl = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _messageOk = false;
  List<AdvisorEntry> _advisors = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _sectionsCtrl.dispose();
    _classroomCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final list = await ref.read(advisorServiceProvider).listAdvisors();
      if (mounted) setState(() => _advisors = list);
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = _errorMessage(e);
          _messageOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _errorMessage(Object e) {
    if (e is FirebaseFunctionsException) {
      switch (e.code) {
        case 'unavailable':
        case 'deadline-exceeded':
          return 'No connection to the server. Check your internet, then '
              'tap refresh.';
        case 'unauthenticated':
          return 'Your session expired. Sign out and back in.';
        case 'permission-denied':
          return 'Your account is not a coordinator.';
        case 'invalid-argument':
          return e.message ?? 'Check the email and section(s) entered.';
        default:
          return 'Could not complete the request: ${e.message ?? e.code}';
      }
    }
    return 'Could not complete the request: $e';
  }

  Future<void> _add() async {
    final email = _emailCtrl.text.trim();
    final sections = _sectionsCtrl.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (email.isEmpty || sections.isEmpty) {
      setState(() {
        _message = 'Enter the advisor\'s email and at least one section.';
        _messageOk = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await ref.read(advisorServiceProvider).assignAdvisor(
            advisorEmail: email,
            sections: sections,
            classroomId:
                _classroomCtrl.text.trim().isEmpty ? null : _classroomCtrl.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        _message = result.summary;
        _messageOk = true;
        _emailCtrl.clear();
        _sectionsCtrl.clear();
        _classroomCtrl.clear();
      });
      _refresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = _errorMessage(e);
          _messageOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Advisors'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout, color: AppTheme.textSecondary),
            onPressed: () async {
              await ref.read(authServiceProvider).signOut();
              if (context.mounted) {
                Navigator.of(context).pushReplacementNamed('/signin');
              }
            },
          ),
        ],
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
                    Text('Add an advisor', style: AppTheme.headlineMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Adding an email here automatically creates their '
                      'account (if needed), grants the advisor role, and '
                      'assigns the section(s) below — nothing to set up '
                      'manually.',
                      style: AppTheme.bodySmall,
                    ),
                    const SizedBox(height: AppTheme.spacingMd),
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      style: AppTheme.bodyLarge,
                      decoration: const InputDecoration(
                        labelText: 'Advisor college email',
                        hintText: 'akumar@citchennai.net',
                        prefixIcon: Icon(Icons.email_outlined, color: AppTheme.accentCyan),
                      ),
                    ),
                    const SizedBox(height: AppTheme.spacingMd),
                    TextField(
                      controller: _sectionsCtrl,
                      textCapitalization: TextCapitalization.characters,
                      style: AppTheme.bodyLarge,
                      decoration: const InputDecoration(
                        labelText: 'Section(s)',
                        hintText: 'CSE-A, CSE-B',
                        prefixIcon: Icon(Icons.groups_outlined, color: AppTheme.accentCyan),
                      ),
                    ),
                    const SizedBox(height: AppTheme.spacingMd),
                    TextField(
                      controller: _classroomCtrl,
                      textCapitalization: TextCapitalization.characters,
                      style: AppTheme.bodyLarge,
                      decoration: const InputDecoration(
                        labelText: 'Default classroom (optional)',
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
                  Text('Current advisors', style: AppTheme.headlineLarge),
                  const Spacer(),
                  IconButton(
                    onPressed: _loading ? null : _refresh,
                    icon: const Icon(Icons.refresh, color: AppTheme.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spacingSm),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator(color: AppTheme.accentCyan)),
                )
              else if (_advisors.isEmpty)
                Text('No advisors yet.', style: AppTheme.bodyMedium)
              else
                ..._advisors.map(_advisorTile),
            ],
          ),
        ),
      ),
    );
  }

  Widget _advisorTile(AdvisorEntry a) {
    return GlassmorphicCard(
      margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
      padding: const EdgeInsets.all(AppTheme.spacingMd),
      child: Row(
        children: [
          Icon(
            a.emailVerified ? Icons.verified_user : Icons.hourglass_bottom,
            color: a.emailVerified ? AppTheme.successGreen : AppTheme.warningAmber,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.email ?? a.uid, style: AppTheme.headlineMedium.copyWith(fontSize: 15)),
                Text(
                  '${a.role} · ${a.sections.isEmpty ? 'no sections' : a.sections.join(', ')}',
                  style: AppTheme.labelSmall,
                ),
                Text(a.status, style: AppTheme.labelSmall.copyWith(
                  color: a.emailVerified ? AppTheme.successGreen : AppTheme.warningAmber,
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
