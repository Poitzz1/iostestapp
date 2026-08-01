import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../config/app_theme.dart';
import '../services/hand_detector.dart';
import '../widgets/animated_gradient_button.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// Hand side selection with 3D hand model visualization.
///
/// Uses model_viewer_plus to render a glTF hand model that mirrors
/// the user's selection (left/right) with smooth rotation transitions.
class HandSelectScreen extends StatefulWidget {
  const HandSelectScreen({super.key});

  @override
  State<HandSelectScreen> createState() => _HandSelectScreenState();
}

class _HandSelectScreenState extends State<HandSelectScreen>
    with SingleTickerProviderStateMixin {
  HandSide _selected = HandSide.left;
  late final AnimationController _floatCtrl;

  @override
  void initState() {
    super.initState();
    _floatCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _floatCtrl.dispose();
    super.dispose();
  }

  void _proceed() {
    final consentAt = ModalRoute.of(context)!.settings.arguments as DateTime;
    Navigator.of(context).pushNamed('/capture', arguments: {
      'handSide': _selected,
      'consentAt': consentAt,
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLeft = _selected == HandSide.left;

    return Scaffold(
      body: ParticleBackground(
        particleCount: 30,
        color: isLeft ? AppTheme.accentCyan : AppTheme.accentPurple,
        child: SafeArea(
          child: Column(
            children: [
              // App bar
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.spacingMd, vertical: AppTheme.spacingSm),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_ios_new),
                    ),
                    const Spacer(),
                    Text('Select Hand', style: AppTheme.headlineMedium),
                    const Spacer(),
                    const SizedBox(width: 48), // balance
                  ],
                ),
              ),

              const SizedBox(height: AppTheme.spacingMd),

              Text(
                'Which palm would you like to enroll?',
                style: AppTheme.bodyMedium,
                textAlign: TextAlign.center,
              ).animate().fadeIn(duration: 400.ms),

              const SizedBox(height: AppTheme.spacingLg),

              // 3D Hand Model
              Expanded(
                child: AnimatedBuilder(
                  animation: _floatCtrl,
                  builder: (context, child) {
                    final offset = math.sin(_floatCtrl.value * math.pi) * 8;
                    return Transform.translate(
                      offset: Offset(0, offset),
                      child: child,
                    );
                  },
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Glow behind model
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: (isLeft
                                      ? AppTheme.accentCyan
                                      : AppTheme.accentPurple)
                                  .withOpacity(0.15),
                              blurRadius: 80,
                              spreadRadius: 20,
                            ),
                          ],
                        ),
                      ),
                      // 3D model viewer
                      SizedBox(
                        height: 320,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 600),
                          transitionBuilder: (child, anim) {
                            return FadeTransition(
                              opacity: anim,
                              child: ScaleTransition(scale: anim, child: child),
                            );
                          },
                          child: Transform(
                            key: ValueKey(_selected),
                            alignment: Alignment.center,
                            transform: isLeft
                                ? Matrix4.identity()
                                : (Matrix4.identity()..scale(-1.0, 1.0)),
                            child: ModelViewer(
                              backgroundColor: Colors.transparent,
                              src: 'https://modelviewer.dev/shared-assets/models/Astronaut.glb',
                              alt: '3D hand model',
                              autoRotate: true,
                              autoRotateDelay: 0,
                              rotationPerSecond: '30deg',
                              cameraControls: false,
                              disableZoom: true,
                              interactionPrompt: InteractionPrompt.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: AppTheme.spacingLg),

              // Hand selection toggle
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingXl),
                child: GlassmorphicCard(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.all(6),
                  child: Row(
                    children: [
                      _handButton(
                        'Left Hand',
                        Icons.back_hand_rounded,
                        isLeft,
                        () => setState(() => _selected = HandSide.left),
                        false,
                      ),
                      const SizedBox(width: 8),
                      _handButton(
                        'Right Hand',
                        Icons.back_hand_rounded,
                        !isLeft,
                        () => setState(() => _selected = HandSide.right),
                        true,
                      ),
                    ],
                  ),
                ),
              ).animate().fadeIn(delay: 300.ms, duration: 400.ms).slideY(begin: 0.2),

              const SizedBox(height: AppTheme.spacingXl),

              // Proceed button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingXl),
                child: AnimatedGradientButton(
                  label: 'Scan ${isLeft ? 'Left' : 'Right'} Palm',
                  icon: Icons.camera_alt_outlined,
                  onPressed: _proceed,
                  gradient: LinearGradient(
                    colors: isLeft
                        ? [AppTheme.accentCyan, AppTheme.accentTeal]
                        : [AppTheme.accentPurple, AppTheme.accentPink],
                  ),
                ),
              ).animate().fadeIn(delay: 500.ms, duration: 400.ms),

              const SizedBox(height: AppTheme.spacingXxl),
            ],
          ),
        ),
      ),
    );
  }

  Widget _handButton(
      String label, IconData icon, bool active, VoidCallback onTap, bool mirror) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: active
                ? AppTheme.accentCyan.withOpacity(0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(
              color: active
                  ? AppTheme.accentCyan.withOpacity(0.4)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            children: [
              Transform(
                alignment: Alignment.center,
                transform: mirror
                    ? (Matrix4.identity()..scale(-1.0, 1.0))
                    : Matrix4.identity(),
                child: Icon(icon,
                    size: 28,
                    color: active ? AppTheme.accentCyan : AppTheme.textHint),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: AppTheme.bodyMedium.copyWith(
                  color: active ? AppTheme.accentCyan : AppTheme.textHint,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
