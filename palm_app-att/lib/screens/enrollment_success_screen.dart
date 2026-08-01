import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vibration/vibration.dart';

import '../config/app_theme.dart';
import '../models/student_profile.dart';
import '../providers/providers.dart';
import '../services/hand_detector.dart';
import '../widgets/particle_background.dart';

/// Success screen shown after palm capture completes.
///
/// Saves the enrollment (local-first → Firestore background sync),
/// shows a celebration animation, and displays enrollment summary.
class EnrollmentSuccessScreen extends ConsumerStatefulWidget {
  const EnrollmentSuccessScreen({super.key});

  @override
  ConsumerState<EnrollmentSuccessScreen> createState() =>
      _EnrollmentSuccessScreenState();
}

class _EnrollmentSuccessScreenState
    extends ConsumerState<EnrollmentSuccessScreen>
    with TickerProviderStateMixin {
  late final AnimationController _check;
  late final AnimationController _confetti;
  bool _saving = true;
  bool _saved = false;
  String? _error;

  /// Route arguments, read ONCE in didChangeDependencies — see the same field
  /// on CaptureScreen for why calling `ModalRoute.of(context)` from the
  /// post-frame callback below is what trips
  /// `InheritedElement.debugDeactivated()`'s `assert(_dependents.isEmpty)`.
  Map? _routeArgs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeArgs ??= ModalRoute.of(context)?.settings.arguments as Map?;
  }

  @override
  void initState() {
    super.initState();
    _check = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _confetti = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );

    // Haptic celebration
    Vibration.hasVibrator().then((has) {
      if (has == true) {
        Vibration.vibrate(duration: 100, amplitude: 128);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _save());
  }

  Future<void> _save() async {
    try {
      final args = _routeArgs;
      if (args == null) throw StateError('Missing enrollment arguments');
      final template = args['template'] as Float32List;
      final handSide = args['handSide'] as HandSide;
      final consentAt = args['consentAt'] as DateTime;

      final user = ref.read(currentUserProvider);
      if (user == null) throw StateError('Not signed in');

      final auth = ref.read(authServiceProvider);
      final cfg = await ref.read(deployConfigProvider.future);
      final svc = await ref.read(studentServiceProvider.future);

      // Preserve any existing roster fields (department/year/section/classroom)
      // from a prior enrollment so a re-enroll re-sends identical values —
      // firestore.rules rejects any CHANGE to them from a student client.
      //
      // NOTE: the device binding is deliberately NOT set here. `bound_device_id`
      // is not student-writable (a writable binding would let one phone re-bind
      // per student and mark a whole section present); the server binds it
      // trust-on-first-use during the first successful attendance submission.
      final existing = await svc.getProfile(auth.studentIdFor(user));

      final profile = StudentProfile.fromTemplate(
        studentId: auth.studentIdFor(user),
        department: existing?.department,
        year: existing?.year,
        section: existing?.section,
        assignedClassroom: existing?.assignedClassroom,
        handSide: handSide,
        template: template,
        modelVersion: cfg.modelVersion,
        consentAt: consentAt,
      );

      await svc.saveProfile(profile);

      setState(() {
        _saving = false;
        _saved = true;
      });

      // Play animations
      _check.forward();
      _confetti.forward();

      // Invalidate profile cache
      ref.invalidate(studentProfileProvider);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _check.dispose();
    _confetti.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ParticleBackground(
        particleCount: 60,
        color: AppTheme.successGreen,
        child: Stack(
          children: [
            // Confetti particles
            if (_saved)
              AnimatedBuilder(
                animation: _confetti,
                builder: (context, _) => CustomPaint(
                  size: Size.infinite,
                  painter: _ConfettiPainter(progress: _confetti.value),
                ),
              ),

            SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppTheme.spacingXl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_saving) ...[
                        const SizedBox(
                          width: 64,
                          height: 64,
                          child: CircularProgressIndicator(
                            color: AppTheme.accentCyan,
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(height: AppTheme.spacingLg),
                        Text('Saving enrollment…',
                            style: AppTheme.headlineMedium),
                      ] else if (_error != null) ...[
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.errorRed.withOpacity(0.15),
                          ),
                          child: const Icon(Icons.error_outline,
                              size: 40, color: AppTheme.errorRed),
                        ),
                        const SizedBox(height: AppTheme.spacingLg),
                        Text('Save Failed', style: AppTheme.headlineLarge),
                        const SizedBox(height: AppTheme.spacingSm),
                        Text(_error!, style: AppTheme.bodySmall,
                            textAlign: TextAlign.center),
                        const SizedBox(height: AppTheme.spacingXl),
                        ElevatedButton(
                          onPressed: () {
                            setState(() {
                              _saving = true;
                              _error = null;
                            });
                            _save();
                          },
                          child: const Text('Retry'),
                        ),
                      ] else ...[
                        // Success check mark
                        AnimatedBuilder(
                          animation: _check,
                          builder: (context, _) {
                            return Transform.scale(
                              scale: 0.5 + 0.5 * Curves.elasticOut.transform(
                                  _check.value.clamp(0.0, 1.0)),
                              child: Container(
                                width: 110,
                                height: 110,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const RadialGradient(
                                    colors: [
                                      AppTheme.successGreen,
                                      AppTheme.accentTeal,
                                    ],
                                  ),
                                  boxShadow: AppTheme.glowShadow(
                                      AppTheme.successGreen,
                                      blur: 30),
                                ),
                                child: const Icon(
                                  Icons.check_rounded,
                                  size: 56,
                                  color: AppTheme.backgroundDark,
                                ),
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: AppTheme.spacingXl),

                        Text(
                          'Enrollment Complete!',
                          style: AppTheme.displayMedium,
                          textAlign: TextAlign.center,
                        )
                            .animate()
                            .fadeIn(delay: 300.ms, duration: 500.ms)
                            .slideY(begin: 0.2),

                        const SizedBox(height: AppTheme.spacingSm),

                        Text(
                          'Your palm has been securely enrolled',
                          style: AppTheme.bodyMedium,
                        )
                            .animate()
                            .fadeIn(delay: 500.ms, duration: 400.ms),

                        const SizedBox(height: AppTheme.spacingXl),

                        // Summary card
                        _buildSummary()
                            .animate()
                            .fadeIn(delay: 700.ms, duration: 400.ms)
                            .slideY(begin: 0.1),

                        const SizedBox(height: AppTheme.spacingXl),

                        // Done button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).pushNamedAndRemoveUntil(
                                  '/home', (_) => false);
                            },
                            icon: const Icon(Icons.home_outlined),
                            label: const Text('Go to Dashboard'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 18),
                            ),
                          ),
                        )
                            .animate()
                            .fadeIn(delay: 900.ms, duration: 400.ms),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummary() {
    final args = _routeArgs ?? const {};
    final handSide = args['handSide'] as HandSide;
    final isLeft = handSide == HandSide.left;
    final user = ref.read(currentUserProvider);
    final auth = ref.read(authServiceProvider);
    final studentId = user != null ? auth.studentIdFor(user) : '—';

    return Container(
      padding: const EdgeInsets.all(AppTheme.spacingLg),
      decoration: AppTheme.glassDecoration(),
      child: Column(
        children: [
          _summaryRow('Student ID', studentId),
          const Divider(color: AppTheme.cardGlass, height: 24),
          _summaryRow('Hand', '${isLeft ? 'Left' : 'Right'} Palm'),
          const Divider(color: AppTheme.cardGlass, height: 24),
          _summaryRow('Status', 'Saved locally, syncing…'),
          const Divider(color: AppTheme.cardGlass, height: 24),
          _summaryRow('Model', 'fp32 (reference)'),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppTheme.bodySmall),
        Flexible(
          child: Text(
            value,
            style: AppTheme.bodyLarge.copyWith(fontSize: 14),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

/// Simple confetti particles for celebration.
class _ConfettiPainter extends CustomPainter {
  final double progress;
  final _rng = math.Random(42); // fixed seed for consistent visuals

  _ConfettiPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress == 0) return;
    final count = 40;
    for (var i = 0; i < count; i++) {
      final x = _rng.nextDouble() * size.width;
      final startY = -20.0;
      final endY = size.height + 20;
      final y = startY + (endY - startY) * progress +
          math.sin(i * 0.5 + progress * 10) * 20;
      final radius = _rng.nextDouble() * 4 + 2;
      final color = [
        AppTheme.accentCyan,
        AppTheme.accentTeal,
        AppTheme.accentPurple,
        AppTheme.successGreen,
        AppTheme.warningAmber,
      ][i % 5];
      final paint = Paint()
        ..color = color.withOpacity((1 - progress).clamp(0.0, 1.0) * 0.8);
      canvas.drawCircle(Offset(x, y % size.height), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) =>
      old.progress != progress;
}
