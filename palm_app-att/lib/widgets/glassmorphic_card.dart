import 'dart:ui';

import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// A frosted-glass container with configurable blur, opacity, gradient border.
///
/// Used across all screens to create the signature glassmorphism look.
class GlassmorphicCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final double blur;
  final double opacity;
  final Color? borderColor;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Gradient? gradient;

  const GlassmorphicCard({
    super.key,
    required this.child,
    this.borderRadius = AppTheme.radiusLg,
    this.blur = 12,
    this.opacity = 0.08,
    this.borderColor,
    this.padding,
    this.margin,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin ?? const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: AppTheme.cardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding ??
                const EdgeInsets.all(AppTheme.spacingLg),
            decoration: BoxDecoration(
              gradient: gradient ??
                  LinearGradient(
                    colors: [
                      Colors.white.withOpacity(opacity),
                      Colors.white.withOpacity(opacity * 0.5),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: borderColor ?? Colors.white.withOpacity(0.12),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Glass card with an accent gradient border (used for highlighted actions).
class AccentGlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  const AccentGlassCard({
    super.key,
    required this.child,
    this.borderRadius = AppTheme.radiusLg,
    this.padding,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin ?? const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: const LinearGradient(
          colors: [AppTheme.accentCyan, AppTheme.accentTeal],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: AppTheme.glowShadow(AppTheme.accentCyan, blur: 12),
      ),
      child: Container(
        margin: const EdgeInsets.all(1.5), // gradient border width
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark.withOpacity(0.92),
          borderRadius: BorderRadius.circular(borderRadius - 1.5),
        ),
        padding: padding ?? const EdgeInsets.all(AppTheme.spacingLg),
        child: child,
      ),
    );
  }
}
