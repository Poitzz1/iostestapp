import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../providers/providers.dart';
import '../services/hand_detector.dart';
import '../services/timetable_service.dart';
import '../widgets/animated_gradient_button.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// YEAR 3 ONLY — the staff side of §5.
///
/// Shows today's resolved plan for a section and lets the authorised staff
/// member palm-verify to open a period. That palm check is what starts the
/// 5-minute student window, so the window is anchored to a verified person
/// standing in the room rather than to a clock.
///
/// This screen decides nothing. Which venue a period is in, who may open it,
/// and whether it is currently a break are all resolved server-side; the UI
/// only renders the answer and relays the rejection reason.
class OpenPeriodScreen extends ConsumerStatefulWidget {
  const OpenPeriodScreen({super.key});

  @override
  ConsumerState<OpenPeriodScreen> createState() => _OpenPeriodScreenState();
}

class _OpenPeriodScreenState extends ConsumerState<OpenPeriodScreen> {
  DayPlan? _plan;
  bool _loading = true;
  bool _busy = false;
  String? _message;
  bool _messageOk = false;
  OpenedSession? _opened;
  String? _sectionId;

  Map? _args;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _args ??= ModalRoute.of(context)?.settings.arguments as Map?;
    if (_sectionId == null) {
      _sectionId = _args?['sectionId'] as String?;
      _load();
    }
  }

  Future<void> _load() async {
    final section = _sectionId;
    if (section == null) {
      setState(() {
        _loading = false;
        _message = 'No section selected.';
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final plan = await ref.read(timetableServiceProvider).dayPlan(section);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = TimetableService.messageFor(e);
        _messageOk = false;
      });
    }
  }

  Future<void> _openPeriod(DayPlanPeriod p) async {
    final section = _sectionId;
    if (section == null) return;

    if (p.venueId == null) {
      setState(() {
        _message = 'No venue is set for period ${p.no}. Add a timetable entry '
            'or an override before opening it.';
        _messageOk = false;
      });
      return;
    }

    // Capture the staff palm through the SAME pipeline students use.
    final captured = await Navigator.of(context).pushNamed<Object?>(
      '/capture',
      arguments: {'mode': 'staff-open', 'handSide': HandSide.right},
    );
    if (captured is! Map) return;
    final template = captured['template'];
    if (template is! Float32List) return;
    final handSide = (captured['handSide'] as HandSide?) ?? HandSide.right;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final opened = await ref.read(timetableServiceProvider).openSessionWithPalm(
            sectionId: section,
            periodNo: p.no,
            probeEmbedding: template,
            handSide: handSide,
          );
      if (!mounted) return;
      setState(() {
        _opened = opened;
        _busy = false;
        _messageOk = true;
        _message = 'Period ${opened.periodNo} open in ${opened.resolvedVenueId} — '
            'students have ${opened.windowMinutes} minutes.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageOk = false;
        _message = TimetableService.messageFor(e);
      });
    }
  }

  Future<void> _enrolMyPalm() async {
    final captured = await Navigator.of(context).pushNamed<Object?>(
      '/capture',
      arguments: {'mode': 'staff-enroll', 'handSide': HandSide.right},
    );
    if (captured is! Map) return;
    final template = captured['template'];
    if (template is! Float32List) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final cfg = await ref.read(deployConfigProvider.future);
      await ref.read(timetableServiceProvider).enrollStaffPalm(
            template: template,
            handSide: (captured['handSide'] as HandSide?) ?? HandSide.right,
            modelVersion: cfg.modelVersion,
            illumination:
                (captured['illumination'] as Map?)?.cast<String, dynamic>(),
            pose: (captured['pose'] as Map?)?.cast<String, dynamic>(),
          );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageOk = true;
        _message = 'Palm enrolled. You can now open your periods.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageOk = false;
        _message = TimetableService.messageFor(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(_sectionId == null ? 'Open a period' : 'Section $_sectionId'),
      ),
      extendBodyBehindAppBar: true,
      body: ParticleBackground(
        particleCount: 18,
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(AppTheme.spacingLg),
                  children: [
                    if (_message != null)
                      GlassmorphicCard(
                        margin: EdgeInsets.zero,
                        child: Text(
                          _message!,
                          style: AppTheme.bodyMedium.copyWith(
                            color: _messageOk ? Colors.greenAccent : Colors.orangeAccent,
                          ),
                        ),
                      ),
                    const SizedBox(height: AppTheme.spacingMd),
                    if (plan == null)
                      GlassmorphicCard(
                        margin: EdgeInsets.zero,
                        child: Text(
                          'No plan available for today. This screen is for '
                          'third-year sections only.',
                          style: AppTheme.bodyMedium,
                        ),
                      )
                    else ...[
                      Text('Today · ${plan.date}', style: AppTheme.headlineMedium),
                      Text(
                        'Students get ${plan.studentWindowMinutes} minutes once you '
                        'palm-verify. Venue shown is the resolved one.',
                        style: AppTheme.labelSmall,
                      ),
                      const SizedBox(height: AppTheme.spacingMd),
                      ...plan.periods.map(_periodTile),
                    ],
                    const SizedBox(height: AppTheme.spacingLg),
                    AnimatedGradientButton(
                      onPressed: _busy ? null : _enrolMyPalm,
                      label: 'Enrol my palm',
                      icon: Icons.back_hand_outlined,
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _periodTile(DayPlanPeriod p) {
    final isOpen = _opened?.periodNo == p.no;
    final unresolved = p.venueId == null;
    return GlassmorphicCard(
      margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('P${p.no}  ${p.start}–${p.end}',
                    style: AppTheme.headlineMedium.copyWith(fontSize: 15)),
                const SizedBox(height: 2),
                Text(
                  unresolved
                      ? 'No venue set'
                      : '${p.venueName ?? p.venueId}'
                          '${p.subject != null ? ' · ${p.subject}' : ''}',
                  style: AppTheme.labelSmall.copyWith(
                    color: unresolved ? Colors.orangeAccent : null,
                  ),
                ),
                if (p.isOverride || p.isSubstitute)
                  Text(
                    [
                      if (p.isOverride) 'moved',
                      if (p.isSubstitute) 'substitute',
                    ].join(' · '),
                    style: AppTheme.labelSmall.copyWith(color: Colors.cyanAccent),
                  ),
              ],
            ),
          ),
          if (isOpen)
            const Icon(Icons.check_circle, color: Colors.greenAccent)
          else
            TextButton(
              onPressed: _busy || unresolved ? null : () => _openPeriod(p),
              child: const Text('Open'),
            ),
        ],
      ),
    );
  }
}
