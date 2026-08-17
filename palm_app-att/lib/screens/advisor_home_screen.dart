import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../models/attendance_record.dart';
import '../models/attendance_session.dart';
import '../providers/providers.dart';
import '../services/staff_service.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// Advisor/admin home (spec §7). Open an attendance window for a section, watch
/// the live marked list as students submit, close early, and manually mark
/// students who fail or don't attempt. Admins also get the classroom Wi-Fi
/// fingerprint tool.
class AdvisorHomeScreen extends ConsumerStatefulWidget {
  const AdvisorHomeScreen({super.key});

  @override
  ConsumerState<AdvisorHomeScreen> createState() => _AdvisorHomeScreenState();
}

class _AdvisorHomeScreenState extends ConsumerState<AdvisorHomeScreen> {
  StaffProfile? _staff;
  AttendanceSession? _openSession;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // staffProfileProvider is a FutureProvider — `ref.read(...future)` alone
    // returns whatever it fetched once and cached. If an admin edits this
    // staff doc (e.g. assigns a section/classroom via the seed script) while
    // the app is already running, a cached read would keep showing the stale
    // pre-edit profile (e.g. classroom_id still null) and silently block
    // "Open attendance" via the guard below. Invalidate first so this screen
    // always sees the current staff doc.
    ref.invalidate(staffProfileProvider);
    final staff = await ref.read(staffProfileProvider.future);
    _staff = staff;
    if (staff != null) {
      _openSession = await ref.read(sessionServiceProvider).myOpenSession(staff.uid);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openSessionAction() async {
    final staff = _staff!;
    if (staff.section == null || staff.classroomId == null) {
      debugPrint('[AdvisorHomeScreen] cannot open session: uid=${staff.uid} '
          'section=${staff.section} classroomId=${staff.classroomId}');
      _snack('Your staff profile is missing a section or classroom. Contact an admin.');
      return;
    }
    setState(() => _busy = true);
    try {
      final session = await ref.read(sessionServiceProvider).openSession(
            classroomId: staff.classroomId!,
            section: staff.section!,
            advisorId: staff.uid,
          );
      setState(() => _openSession = session);
    } catch (e) {
      debugPrint('[AdvisorHomeScreen] openSession failed: $e');
      _snack('Could not open session: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeSessionAction() async {
    final s = _openSession;
    if (s == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(sessionServiceProvider).closeSession(s.sessionId);
      setState(() => _openSession = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manualMark(AttendanceRecord r, String status) async {
    final reason = await _askReason(status);
    if (reason == null) return;
    await ref.read(sessionServiceProvider).manualMark(
          attendanceId: r.attendanceId,
          status: status,
          reason: reason,
          advisorId: _staff!.uid,
        );
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ParticleBackground(
        particleCount: 25,
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppTheme.accentCyan))
              : _content(),
        ),
      ),
    );
  }

  Widget _content() {
    final staff = _staff;
    if (staff == null) {
      return const Center(child: Text('Not authorized as staff.'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(staff.isAdmin ? 'Admin' : 'Advisor', style: AppTheme.bodyMedium),
                    Text(staff.name ?? staff.section ?? 'Staff', style: AppTheme.displayMedium),
                  ],
                ),
              ),
              // YEAR 3 ONLY. Opens the resolved day plan so the staff member
              // can palm-verify and start a period's 5-minute student window
              // (build brief §5). A section that is not year 3 gets a plain
              // refusal from the server rather than a different screen.
              IconButton(
                tooltip: 'Open a period (Year 3)',
                icon: const Icon(Icons.schedule, color: AppTheme.accentCyan),
                onPressed: () => Navigator.of(context).pushNamed(
                  '/open-period',
                  arguments: {
                    'sectionId': staff.section ??
                        (staff.sections.isNotEmpty ? staff.sections.first : null),
                  },
                ),
              ),
              IconButton(
                tooltip: 'Section roster',
                icon: const Icon(Icons.group_add_outlined, color: AppTheme.accentCyan),
                onPressed: () => Navigator.of(context).pushNamed('/assign-students'),
              ),
              if (staff.isAdmin)
                IconButton(
                  tooltip: 'Classroom Wi-Fi setup',
                  icon: const Icon(Icons.wifi_find_outlined, color: AppTheme.accentCyan),
                  onPressed: () => Navigator.of(context).pushNamed('/wifi-fingerprint'),
                ),
              IconButton(
                tooltip: 'Sign out',
                icon: const Icon(Icons.logout, color: AppTheme.textSecondary),
                onPressed: () async {
                  await ref.read(authServiceProvider).signOut();
                  if (mounted) Navigator.of(context).pushReplacementNamed('/signin');
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd),
          child: _sessionCard(staff),
        ),
        const SizedBox(height: AppTheme.spacingMd),
        Expanded(child: _liveList()),
      ],
    );
  }

  Widget _sessionCard(StaffProfile staff) {
    final open = _openSession != null;
    return GlassmorphicCard(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(open ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: open ? AppTheme.successGreen : AppTheme.textHint),
              const SizedBox(width: 8),
              Text(open ? 'Session open' : 'No open session',
                  style: AppTheme.headlineMedium.copyWith(fontSize: 16)),
            ],
          ),
          const SizedBox(height: 6),
          Text('Section ${staff.section ?? '—'} · Classroom ${staff.classroomId ?? '—'}',
              style: AppTheme.bodySmall),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : (open ? _closeSessionAction : _openSessionAction),
              icon: Icon(open ? Icons.stop_circle_outlined : Icons.play_circle_outline),
              label: Text(open ? 'Close session' : 'Open attendance'),
              style: ElevatedButton.styleFrom(
                backgroundColor: open ? AppTheme.errorRed : AppTheme.accentCyan,
                foregroundColor: open ? Colors.white : AppTheme.backgroundDark,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _liveList() {
    final session = _openSession;
    if (session == null) {
      return Center(
        child: Text('Open a session to see students marked live.',
            style: AppTheme.bodyMedium),
      );
    }
    return StreamBuilder<List<AttendanceRecord>>(
      stream: ref.read(sessionServiceProvider).liveRecords(session.sessionId),
      builder: (context, snap) {
        final records = snap.data ?? [];
        if (records.isEmpty) {
          return Center(child: Text('No submissions yet…', style: AppTheme.bodyMedium));
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd),
          itemCount: records.length,
          itemBuilder: (context, i) {
            final r = records[i];
            final present = r.isPresent;
            return GlassmorphicCard(
              margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
              padding: const EdgeInsets.all(AppTheme.spacingMd),
              child: Row(
                children: [
                  Icon(present ? Icons.check_circle : Icons.error_outline,
                      color: present ? AppTheme.successGreen : AppTheme.warningAmber, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.studentId, style: AppTheme.headlineMedium.copyWith(fontSize: 15)),
                        Text('${r.status} · ${r.decisionReason}', style: AppTheme.labelSmall),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, color: AppTheme.textSecondary),
                    onSelected: (v) => _manualMark(r, v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'absent', child: Text('Mark Absent')),
                      PopupMenuItem(value: 'od', child: Text('Mark OD')),
                      PopupMenuItem(value: 'other', child: Text('Mark Other')),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<String?> _askReason(String status) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text('Mark $status', style: AppTheme.headlineMedium),
        content: TextField(
          controller: ctrl,
          style: AppTheme.bodyLarge,
          decoration: const InputDecoration(labelText: 'Reason'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
