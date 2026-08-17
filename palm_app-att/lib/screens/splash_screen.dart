import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../providers/providers.dart';
import '../widgets/particle_background.dart';

/// Splash screen with animated logo, model loading, and auto-navigation.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _rotateCtrl;
  String _status = 'Initializing…';
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _rotateCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _loadAndNavigate();
  }

  Future<void> _loadAndNavigate() async {
    try {
      // Load config
      setState(() => _status = 'Loading model config…');
      await ref.read(deployConfigProvider.future);

      // Load ONNX model
      setState(() => _status = 'Loading palm model…');
      await ref.read(palmModelProvider.future);

      // Init student profile service
      setState(() => _status = 'Ready');
      await ref.read(studentServiceProvider.future);

      // Short delay for UX
      await Future.delayed(const Duration(milliseconds: 800));

      if (!mounted) return;

      // Navigate based on auth state. AWAIT the first auth event rather than
      // reading currentUserProvider: Firebase restores the saved session from
      // disk asynchronously, and reading before that finishes reports null for
      // a signed-in user, bouncing them to /signin on every restart.
      setState(() => _status = 'Restoring session…');
      final user = await ref.read(authStateProvider.future);
      if (!mounted) return;
      if (user == null) {
        Navigator.of(context).pushReplacementNamed('/signin');
        return;
      }

      // emailVerified is cached from sign-in time and won't reflect a
      // verification completed elsewhere, so refresh it from the server.
      final auth = ref.read(authServiceProvider);
      final verified = await auth.reloadAndCheckVerified();
      if (!mounted) return;
      if (!verified) {
        Navigator.of(context).pushReplacementNamed('/verify-email');
        return;
      }

      // Coordinators land on the advisor list (that's their whole job);
      // advisors/admins go to their session home; everyone else is a student.
      final staff = await ref.read(staffProfileProvider.future);
      if (!mounted) return;
      final route = staff == null
          ? '/home'
          : (staff.isCoordinator ? '/manage-advisors' : '/advisor');
      Navigator.of(context).pushReplacementNamed(route);
    } catch (e) {
      // Without a way forward this is a dead end that reads to the user as
      // "the app logged me out" — the staff lookup and model load both depend
      // on the network, which is exactly what is flaky on campus.
      if (mounted) {
        setState(() {
          _status = 'Could not start: $e';
          _failed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _rotateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ParticleBackground(
        particleCount: 40,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 3D rotating palm icon
              AnimatedBuilder(
                animation: _rotateCtrl,
                builder: (context, child) {
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.001)
                      ..rotateY(math.sin(_rotateCtrl.value * math.pi * 2) * 0.3)
                      ..rotateX(math.cos(_rotateCtrl.value * math.pi * 2) * 0.1),
                    child: child,
                  );
                },
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      colors: [
                        AppTheme.accentCyan,
                        AppTheme.accentTeal,
                      ],
                    ),
                    boxShadow: AppTheme.glowShadow(AppTheme.accentCyan, blur: 30),
                  ),
                  child: const Icon(
                    Icons.back_hand_rounded,
                    size: 56,
                    color: AppTheme.backgroundDark,
                  ),
                ),
              )
                  .animate()
                  .fadeIn(duration: 600.ms)
                  .scale(begin: const Offset(0.5, 0.5), curve: Curves.elasticOut, duration: 900.ms),

              const SizedBox(height: AppTheme.spacingXl),

              // App name
              Text('Cit Attendance', style: AppTheme.displayLarge)
                  .animate()
                  .fadeIn(delay: 300.ms, duration: 500.ms)
                  .slideY(begin: 0.3, curve: Curves.easeOutCubic),

              const SizedBox(height: AppTheme.spacingSm),

              Text(
                'Biometric Enrollment',
                style: AppTheme.bodyMedium.copyWith(
                  color: AppTheme.accentTeal,
                  letterSpacing: 3,
                  fontSize: 13,
                ),
              )
                  .animate()
                  .fadeIn(delay: 500.ms, duration: 500.ms),

              const SizedBox(height: AppTheme.spacingXxl),

              // Status
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _status,
                  key: ValueKey(_status),
                  style: AppTheme.bodySmall,
                ),
              ),

              const SizedBox(height: AppTheme.spacingMd),

              if (_failed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _failed = false;
                          _status = 'Retrying…';
                        });
                        _loadAndNavigate();
                      },
                      icon: const Icon(Icons.refresh, color: AppTheme.accentCyan),
                      label: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: () =>
                          Navigator.of(context).pushReplacementNamed('/signin'),
                      child: const Text('Sign in again'),
                    ),
                  ],
                )
              else
                // Loading indicator
                SizedBox(
                  width: 160,
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.white.withOpacity(0.08),
                    valueColor: const AlwaysStoppedAnimation(AppTheme.accentCyan),
                    minHeight: 2,
                  ),
                )
                    .animate()
                    .fadeIn(delay: 400.ms),
            ],
          ),
        ),
      ),
    );
  }
}
