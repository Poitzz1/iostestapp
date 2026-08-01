import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../providers/providers.dart';
import '../widgets/animated_gradient_button.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// Blocks entry into the app until the student proves they control the
/// college inbox behind their account. Reached after registration, or on
/// sign-in if a prior registration was never verified.
///
/// `firestore.rules` enforces `token.email_verified == true` server-side —
/// this screen exists purely so the student isn't stuck with a working
/// sign-in that silently can't read/write anything.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  bool _checking = false;
  bool _resending = false;
  int _resendCooldown = 0;
  Timer? _cooldownTimer;
  String? _message;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkVerified() async {
    setState(() {
      _checking = true;
      _message = null;
    });
    final auth = ref.read(authServiceProvider);
    final verified = await auth.reloadAndCheckVerified();
    if (!mounted) return;
    setState(() => _checking = false);
    if (verified) {
      Navigator.of(context).pushReplacementNamed('/home');
    } else {
      setState(() => _message = 'Not verified yet — check your inbox and tap the link.');
    }
  }

  Future<void> _resend() async {
    if (_resendCooldown > 0) return;
    setState(() {
      _resending = true;
      _message = null;
    });
    try {
      await ref.read(authServiceProvider).sendVerificationEmail();
      if (!mounted) return;
      setState(() {
        _message = 'Verification email sent.';
        _resendCooldown = 30;
      });
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel();
        setState(() => _resendCooldown--);
        if (_resendCooldown <= 0) t.cancel();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Could not resend right now — try again shortly.');
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.read(authServiceProvider);
    final email = auth.currentUser?.email ?? 'your college email';

    return Scaffold(
      body: ParticleBackground(
        particleCount: 25,
        color: AppTheme.accentTeal,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.spacingXl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.accentTeal.withOpacity(0.15),
                      border: Border.all(color: AppTheme.accentTeal.withOpacity(0.3)),
                    ),
                    child: const Icon(Icons.mark_email_unread_outlined,
                        size: 36, color: AppTheme.accentTeal),
                  ).animate().fadeIn(duration: 400.ms).scale(begin: const Offset(0.8, 0.8)),

                  const SizedBox(height: AppTheme.spacingLg),

                  Text('Verify your email', style: AppTheme.displayMedium)
                      .animate()
                      .fadeIn(delay: 150.ms),

                  const SizedBox(height: AppTheme.spacingSm),

                  Text(
                    'We sent a verification link to\n$email',
                    style: AppTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ).animate().fadeIn(delay: 250.ms),

                  const SizedBox(height: AppTheme.spacingXl),

                  GlassmorphicCard(
                    margin: EdgeInsets.zero,
                    padding: const EdgeInsets.all(AppTheme.spacingMd),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            color: AppTheme.accentCyan.withOpacity(0.7), size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'You can\'t enroll or view your data until this email is '
                            'verified. Tap the link, then come back here.',
                            style: AppTheme.bodySmall.copyWith(
                              color: AppTheme.textSecondary,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ).animate().fadeIn(delay: 350.ms),

                  if (_message != null) ...[
                    const SizedBox(height: AppTheme.spacingMd),
                    Text(_message!, style: AppTheme.bodySmall, textAlign: TextAlign.center),
                  ],

                  const SizedBox(height: AppTheme.spacingXl),

                  AnimatedGradientButton(
                    label: "I've verified — Continue",
                    icon: Icons.check_circle_outline,
                    loading: _checking,
                    onPressed: _checking ? null : _checkVerified,
                  ),

                  const SizedBox(height: AppTheme.spacingMd),

                  TextButton(
                    onPressed: (_resending || _resendCooldown > 0) ? null : _resend,
                    child: Text(
                      _resendCooldown > 0
                          ? 'Resend email (${_resendCooldown}s)'
                          : 'Resend verification email',
                      style: AppTheme.bodyMedium.copyWith(
                        color: (_resending || _resendCooldown > 0)
                            ? AppTheme.textHint
                            : AppTheme.accentCyan,
                      ),
                    ),
                  ),

                  TextButton(
                    onPressed: () async {
                      await auth.signOut();
                      if (context.mounted) {
                        Navigator.of(context).pushReplacementNamed('/signin');
                      }
                    },
                    child: Text('Use a different account',
                        style: AppTheme.bodySmall.copyWith(color: AppTheme.textHint)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
