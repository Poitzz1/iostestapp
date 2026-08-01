import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// Animated scan ring overlay for the camera capture screen.
///
/// Features:
/// - Glowing gradient ring with 3D depth shadows
/// - Animated progress arc showing frames captured / target
/// - Pulse animation on each accepted frame
/// - Corner markers for palm alignment guidance
class ScanRingPainter extends CustomPainter {
  final double progress; // 0.0 → 1.0 (frames captured / target)
  final double pulseValue; // 0.0 → 1.0 pulse animation
  final double rotationAngle; // continuous rotation
  final bool isActive;
  final Color ringColor;

  ScanRingPainter({
    required this.progress,
    this.pulseValue = 0,
    this.rotationAngle = 0,
    this.isActive = true,
    this.ringColor = AppTheme.accentCyan,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.38;

    // Save canvas for rotation
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotationAngle);
    canvas.translate(-center.dx, -center.dy);

    // ─── Outer glow ──────────────────────────────────────────────────
    if (isActive) {
      final glowPaint = Paint()
        ..color = ringColor.withOpacity(0.06 + pulseValue * 0.08)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 30 + pulseValue * 15);
      canvas.drawCircle(center, radius + 10, glowPaint);
    }

    // ─── Background ring (track) ─────────────────────────────────────
    final trackPaint = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, trackPaint);

    // ─── Progress arc ────────────────────────────────────────────────
    if (progress > 0) {
      final progressPaint = Paint()
        ..shader = SweepGradient(
          colors: [
            AppTheme.accentCyan,
            AppTheme.accentTeal,
            AppTheme.accentPurple,
            AppTheme.accentCyan,
          ],
          stops: const [0.0, 0.33, 0.66, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;

      final sweepAngle = 2 * math.pi * progress;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        sweepAngle,
        false,
        progressPaint,
      );

      // Dot at the progress tip
      final tipAngle = -math.pi / 2 + sweepAngle;
      final tipX = center.dx + radius * math.cos(tipAngle);
      final tipY = center.dy + radius * math.sin(tipAngle);
      final dotPaint = Paint()
        ..color = AppTheme.accentCyan
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(Offset(tipX, tipY), 5 + pulseValue * 3, dotPaint);
    }

    // ─── Pulse ring (on frame accept) ────────────────────────────────
    if (pulseValue > 0) {
      final pulsePaint = Paint()
        ..color = ringColor.withOpacity(0.4 * (1.0 - pulseValue))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * (1.0 - pulseValue);
      canvas.drawCircle(
        center,
        radius + 20 * pulseValue,
        pulsePaint,
      );
    }

    // ─── Corner markers ──────────────────────────────────────────────
    _drawCornerMarkers(canvas, center, radius);

    canvas.restore();
  }

  void _drawCornerMarkers(Canvas canvas, Offset center, double radius) {
    final markerLength = radius * 0.15;
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    // Inner guide square (for palm positioning)
    final half = radius * 0.65;
    final corners = [
      Offset(center.dx - half, center.dy - half), // top-left
      Offset(center.dx + half, center.dy - half), // top-right
      Offset(center.dx + half, center.dy + half), // bottom-right
      Offset(center.dx - half, center.dy + half), // bottom-left
    ];

    for (var i = 0; i < 4; i++) {
      final c = corners[i];
      final dx = (i == 0 || i == 3) ? 1.0 : -1.0;
      final dy = (i < 2) ? 1.0 : -1.0;
      canvas.drawLine(c, Offset(c.dx + markerLength * dx, c.dy), paint);
      canvas.drawLine(c, Offset(c.dx, c.dy + markerLength * dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant ScanRingPainter old) =>
      old.progress != progress ||
      old.pulseValue != pulseValue ||
      old.rotationAngle != rotationAngle ||
      old.isActive != isActive;
}
