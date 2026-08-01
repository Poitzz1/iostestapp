import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../providers/providers.dart';
import '../services/auth_service.dart';
import '../widgets/animated_gradient_button.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// Sign-in screen with college email + password authentication.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isRegister = false;
  bool _loading = false;
  bool _obscurePass = true;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final auth = ref.read(authServiceProvider);
      if (_isRegister) {
        // Freshly created accounts are never verified yet — always route to
        // the verify-email gate rather than checking.
        await auth.register(_emailCtrl.text, _passCtrl.text);
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed('/verify-email');
      } else {
        final cred = await auth.signIn(_emailCtrl.text, _passCtrl.text);
        if (!auth.isEmailVerified) {
          if (!mounted) return;
          Navigator.of(context).pushReplacementNamed('/verify-email');
          return;
        }
        // Route staff (advisor/admin) to their own home; students to /home.
        // Read staff directly from the just-authenticated uid — the
        // auth-state stream (and staffProfileProvider) can still be stale here.
        final uid = cred.user?.uid;
        final staff = uid == null
            ? null
            : await ref.read(staffServiceProvider).profileFor(uid);
        if (!mounted) return;
        Navigator.of(context)
            .pushReplacementNamed(staff != null ? '/advisor' : '/home');
      }
    } catch (e) {
      setState(() => _error = _friendlyError(e.toString()));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(String msg) {
    if (msg.contains('DisallowedEmailDomainException')) {
      return 'Only @${AuthService.allowedDomain} college email addresses are allowed.';
    }
    if (msg.contains('user-not-found')) return 'No account found. Try registering.';
    if (msg.contains('wrong-password')) return 'Incorrect password.';
    if (msg.contains('email-already-in-use')) return 'Email already registered. Try signing in.';
    if (msg.contains('weak-password')) return 'Password too weak. Use at least 6 characters.';
    if (msg.contains('invalid-email')) return 'Invalid email format.';
    if (msg.contains('network')) return 'Network error. Check your connection.';
    return 'Authentication failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    return Scaffold(
      body: ParticleBackground(
        particleCount: 30,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: mq.viewInsets.bottom + 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: mq.size.height - mq.padding.top - mq.padding.bottom,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: AppTheme.spacingXl),

                  // Palm icon
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: AppTheme.accentGradient,
                      boxShadow: AppTheme.glowShadow(AppTheme.accentCyan),
                    ),
                    child: const Icon(
                      Icons.back_hand_rounded,
                      size: 40,
                      color: AppTheme.backgroundDark,
                    ),
                  )
                      .animate()
                      .fadeIn(duration: 500.ms)
                      .scale(begin: const Offset(0.7, 0.7), curve: Curves.easeOutBack),

                  const SizedBox(height: AppTheme.spacingLg),

                  Text('Welcome to PalmPay', style: AppTheme.displayMedium)
                      .animate()
                      .fadeIn(delay: 200.ms, duration: 400.ms),

                  const SizedBox(height: AppTheme.spacingSm),

                  Text(
                    'Sign in with your college credentials',
                    style: AppTheme.bodyMedium,
                  ).animate().fadeIn(delay: 300.ms, duration: 400.ms),

                  const SizedBox(height: AppTheme.spacingXl),

                  // Form card
                  GlassmorphicCard(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Tab toggle
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                            ),
                            child: Row(
                              children: [
                                _tabButton('Sign In', !_isRegister, () {
                                  setState(() => _isRegister = false);
                                }),
                                _tabButton('Register', _isRegister, () {
                                  setState(() => _isRegister = true);
                                }),
                              ],
                            ),
                          ),

                          const SizedBox(height: AppTheme.spacingLg),

                          // Email field
                          TextFormField(
                            controller: _emailCtrl,
                            keyboardType: TextInputType.emailAddress,
                            style: AppTheme.bodyLarge,
                            decoration: InputDecoration(
                              labelText: 'College Email',
                              hintText: '2023cs041@${AuthService.allowedDomain}',
                              prefixIcon: const Icon(Icons.email_outlined,
                                  color: AppTheme.accentCyan),
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return 'Email is required';
                              }
                              if (!v.contains('@')) return 'Invalid email';
                              if (!AuthService.isAllowedEmail(v)) {
                                return 'Use your @${AuthService.allowedDomain} college email';
                              }
                              return null;
                            },
                          ),

                          const SizedBox(height: AppTheme.spacingMd),

                          // Password field
                          TextFormField(
                            controller: _passCtrl,
                            obscureText: _obscurePass,
                            style: AppTheme.bodyLarge,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline,
                                  color: AppTheme.accentCyan),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePass
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: AppTheme.textHint,
                                ),
                                onPressed: () {
                                  setState(() => _obscurePass = !_obscurePass);
                                },
                              ),
                            ),
                            validator: (v) {
                              if (v == null || v.isEmpty) return 'Password is required';
                              if (v.length < 6) return 'At least 6 characters';
                              return null;
                            },
                          ),

                          // Error message
                          if (_error != null) ...[
                            const SizedBox(height: AppTheme.spacingMd),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.errorRed.withOpacity(0.1),
                                borderRadius:
                                    BorderRadius.circular(AppTheme.radiusSm),
                                border: Border.all(
                                    color: AppTheme.errorRed.withOpacity(0.3)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error_outline,
                                      color: AppTheme.errorRed, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(_error!,
                                        style: AppTheme.bodySmall.copyWith(
                                            color: AppTheme.errorRed)),
                                  ),
                                ],
                              ),
                            ).animate().shake(hz: 3, duration: 400.ms),
                          ],

                          const SizedBox(height: AppTheme.spacingLg),

                          // Submit button
                          AnimatedGradientButton(
                            label: _isRegister ? 'Create Account' : 'Sign In',
                            loading: _loading,
                            icon: _isRegister
                                ? Icons.person_add_outlined
                                : Icons.login,
                            onPressed: _submit,
                          ),
                        ],
                      ),
                    ),
                  ).animate().fadeIn(delay: 400.ms, duration: 500.ms).slideY(begin: 0.1),

                  const SizedBox(height: AppTheme.spacingXl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabButton(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: active ? AppTheme.accentCyan.withOpacity(0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppTheme.labelLarge.copyWith(
              color: active ? AppTheme.accentCyan : AppTheme.textHint,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}
