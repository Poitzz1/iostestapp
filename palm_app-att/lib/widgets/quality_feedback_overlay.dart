import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../services/quality_gate.dart';

/// Real-time quality feedback overlay on the camera preview.
///
/// Displays animated text hints color-coded by severity:
/// - Green (ok / hold still)
/// - Amber (warning: off center, blurry)
/// - Red (error: too dark, too bright, no palm)
class QualityFeedbackOverlay extends StatelessWidget {
  final QualityReport? report;
  final String message;
  final int goodFrames;
  final int targetFrames;

  const QualityFeedbackOverlay({
    super.key,
    this.report,
    required this.message,
    required this.goodFrames,
    required this.targetFrames,
  });

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(report?.issue);
    final icon = _iconFor(report?.issue);

    return Positioned(
      bottom: 120,
      // Inset from the screen edges so a wrapped, multi-line hint has a margin
      // instead of running right up against the sides.
      left: 24,
      right: 24,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Quality hint
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.3),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: Container(
              key: ValueKey(message),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                border: Border.all(color: color.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Nudged down so the icon lines up with the FIRST line of a
                  // wrapped message rather than floating at its vertical centre.
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, color: color, size: 18),
                  ),
                  const SizedBox(width: 8),
                  // Flexible, or the Row lays the Text out at its full
                  // single-line width and overflows the banner. The capture
                  // hints are full sentences ("Move your hand a little further
                  // away", the Wi-Fi troubleshooting text), none of which fit
                  // on one line on a phone — they must be allowed to wrap.
                  Flexible(
                    child: Text(
                      message,
                      softWrap: true,
                      textAlign: TextAlign.center,
                      style: AppTheme.bodyMedium.copyWith(
                        color: color,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Frame counter dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(targetFrames, (i) {
              final captured = i < goodFrames;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                // NOT an overshooting curve (easeOutBack). AnimatedContainer
                // lerps the whole BoxDecoration, and a "back" curve drives t
                // beyond 1.0 — which scales the glow's blur radius NEGATIVE
                // and trips `Shadow`'s "blur radius should be non-negative"
                // assertion, i.e. the red screen. It fired whenever a dot went
                // from captured back to uncaptured, which is every time the
                // frame counter resets — once per capture pass.
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: captured ? 12 : 8,
                height: captured ? 12 : 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: captured
                      ? AppTheme.accentCyan
                      : Colors.white.withOpacity(0.2),
                  // Always a shadow list of the SAME LENGTH as glowShadow()
                  // (2 entries) rather than null, so the lerp is element-wise
                  // between two real shadows instead of scaling a list against
                  // null. Belt-and-braces alongside the curve fix above.
                  boxShadow: captured
                      ? AppTheme.glowShadow(AppTheme.accentCyan, blur: 6)
                      : const [
                          BoxShadow(color: Colors.transparent),
                          BoxShadow(color: Colors.transparent),
                        ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Color _colorFor(QualityIssue? issue) {
    if (issue == null) return AppTheme.textSecondary;
    switch (issue) {
      case QualityIssue.ok:
        return AppTheme.successGreen;
      case QualityIssue.offCenter:
      case QualityIssue.blurry:
      case QualityIssue.noMotion:
        return AppTheme.warningAmber;
      case QualityIssue.tooDark:
      case QualityIssue.tooBright:
      case QualityIssue.noPalm:
      case QualityIssue.spoofDetected:
        return AppTheme.errorRed;
    }
  }

  IconData _iconFor(QualityIssue? issue) {
    if (issue == null) return Icons.info_outline;
    switch (issue) {
      case QualityIssue.ok:
        return Icons.check_circle_outline;
      case QualityIssue.offCenter:
        return Icons.center_focus_weak;
      case QualityIssue.blurry:
        return Icons.blur_on;
      case QualityIssue.tooDark:
        return Icons.dark_mode_outlined;
      case QualityIssue.tooBright:
        return Icons.light_mode_outlined;
      case QualityIssue.noPalm:
        return Icons.pan_tool_outlined;
      case QualityIssue.noMotion:
        return Icons.front_hand_outlined;
      case QualityIssue.spoofDetected:
        return Icons.shield_outlined;
    }
  }
}
