import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../config/app_theme.dart';
import '../widgets/animated_gradient_button.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// DPDP-compliant standalone consent screen.
///
/// This is NOT buried in terms — it is a dedicated, explicit consent screen
/// as required by India's DPDP Act, 2023 (README §6). Students must consent
/// before ANY biometric capture begins.
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _consentBiometric = false;
  bool _consentPurpose = false;
  bool _consentAge = false;

  bool get _allConsented => _consentBiometric && _consentPurpose && _consentAge;

  void _proceed() {
    final consentAt = DateTime.now();
    Navigator.of(context).pushNamed('/hand-select', arguments: consentAt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ParticleBackground(
        particleCount: 25,
        color: AppTheme.accentTeal,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spacingMd,
              vertical: AppTheme.spacingLg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Back button
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new,
                      color: AppTheme.textPrimary),
                ),

                const SizedBox(height: AppTheme.spacingMd),

                // Header
                Center(
                  child: Column(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.accentTeal.withOpacity(0.15),
                          border: Border.all(
                              color: AppTheme.accentTeal.withOpacity(0.3)),
                        ),
                        child: const Icon(Icons.shield_outlined,
                            size: 36, color: AppTheme.accentTeal),
                      )
                          .animate()
                          .fadeIn(duration: 400.ms)
                          .scale(begin: const Offset(0.8, 0.8)),

                      const SizedBox(height: AppTheme.spacingMd),

                      Text(
                        'Biometric Consent',
                        style: AppTheme.displayMedium,
                      ).animate().fadeIn(delay: 200.ms),

                      const SizedBox(height: AppTheme.spacingSm),

                      Text(
                        'Your privacy matters. Please review and consent\nto the following before enrollment.',
                        style: AppTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ).animate().fadeIn(delay: 300.ms),
                    ],
                  ),
                ),

                const SizedBox(height: AppTheme.spacingXl),

                // Consent items
                _ConsentItem(
                  icon: Icons.fingerprint,
                  title: 'Palm Embedding Storage',
                  description:
                      'Your palm print will be converted into a mathematical '
                      'representation (256-dimensional embedding). Only this '
                      'embedding is stored — the raw palm image is never saved '
                      'or transmitted.',
                  checked: _consentBiometric,
                  onChanged: (v) =>
                      setState(() => _consentBiometric = v ?? false),
                )
                    .animate()
                    .fadeIn(delay: 400.ms, duration: 400.ms)
                    .slideX(begin: -0.1),

                const SizedBox(height: AppTheme.spacingMd),

                _ConsentItem(
                  icon: Icons.verified_user_outlined,
                  title: 'Purpose Limitation',
                  description:
                      'Your palm embedding will be used exclusively for '
                      'attendance authentication at your institution. It will '
                      'not be shared with third parties or used for any other '
                      'purpose.',
                  checked: _consentPurpose,
                  onChanged: (v) =>
                      setState(() => _consentPurpose = v ?? false),
                )
                    .animate()
                    .fadeIn(delay: 500.ms, duration: 400.ms)
                    .slideX(begin: -0.1),

                const SizedBox(height: AppTheme.spacingMd),

                _ConsentItem(
                  icon: Icons.cake_outlined,
                  title: 'Age Confirmation',
                  description:
                      'I confirm that I am 18 years of age or older. This pilot '
                      'program is currently available only to students aged 18+. '
                      'Under-18 enrollment requires separate parental consent.',
                  checked: _consentAge,
                  onChanged: (v) => setState(() => _consentAge = v ?? false),
                )
                    .animate()
                    .fadeIn(delay: 600.ms, duration: 400.ms)
                    .slideX(begin: -0.1),

                const SizedBox(height: AppTheme.spacingMd),

                // Deletion right notice
                GlassmorphicCard(
                  margin: EdgeInsets.zero,
                  opacity: 0.04,
                  padding: const EdgeInsets.all(AppTheme.spacingMd),
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline,
                          color: AppTheme.accentCyan.withOpacity(0.7), size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'You can delete your enrollment at any time with a '
                          'single tap. Withdrawing consent is as easy as giving it.',
                          style: AppTheme.bodySmall.copyWith(
                            color: AppTheme.textSecondary,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ).animate().fadeIn(delay: 700.ms),

                const SizedBox(height: AppTheme.spacingXl),

                // Submit
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd),
                  child: AnimatedGradientButton(
                    label: 'I Consent & Continue',
                    icon: Icons.arrow_forward,
                    onPressed: _allConsented ? _proceed : null,
                    gradient: _allConsented
                        ? AppTheme.accentGradient
                        : LinearGradient(
                            colors: [
                              Colors.grey.shade700,
                              Colors.grey.shade800,
                            ],
                          ),
                  ),
                ).animate().fadeIn(delay: 800.ms),

                const SizedBox(height: AppTheme.spacingLg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConsentItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool checked;
  final ValueChanged<bool?> onChanged;

  const _ConsentItem({
    required this.icon,
    required this.title,
    required this.description,
    required this.checked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GlassmorphicCard(
      margin: EdgeInsets.zero,
      borderColor:
          checked ? AppTheme.accentCyan.withOpacity(0.4) : null,
      padding: const EdgeInsets.all(AppTheme.spacingMd),
      child: InkWell(
        onTap: () => onChanged(!checked),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: checked
                    ? AppTheme.accentCyan.withOpacity(0.15)
                    : Colors.white.withOpacity(0.05),
                border: Border.all(
                  color: checked
                      ? AppTheme.accentCyan.withOpacity(0.5)
                      : Colors.white.withOpacity(0.1),
                ),
              ),
              child: Icon(icon,
                  size: 22,
                  color: checked
                      ? AppTheme.accentCyan
                      : AppTheme.textHint),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppTheme.headlineMedium.copyWith(fontSize: 15)),
                  const SizedBox(height: 4),
                  Text(description,
                      style: AppTheme.bodySmall.copyWith(height: 1.5)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: checked
                    ? AppTheme.accentCyan
                    : Colors.transparent,
                border: Border.all(
                  color: checked
                      ? AppTheme.accentCyan
                      : Colors.white.withOpacity(0.25),
                  width: 2,
                ),
              ),
              child: checked
                  ? const Icon(Icons.check, size: 18, color: AppTheme.backgroundDark)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
