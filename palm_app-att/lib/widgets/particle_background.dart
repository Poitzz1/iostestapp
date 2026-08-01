import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// Floating geometric particles for premium screen backgrounds.
///
/// GPU-friendly: uses a single CustomPainter + AnimationController.
/// Particles float upward with gentle lateral drift, creating a living,
/// ambient feel behind glassmorphic cards.
class ParticleBackground extends StatefulWidget {
  final int particleCount;
  final Color color;
  final Widget? child;

  const ParticleBackground({
    super.key,
    this.particleCount = 50,
    this.color = AppTheme.accentCyan,
    this.child,
  });

  @override
  State<ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<ParticleBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final List<_Particle> _particles;
  final _rng = math.Random();

  @override
  void initState() {
    super.initState();
    _particles = List.generate(widget.particleCount, (_) => _randomParticle());
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  _Particle _randomParticle() => _Particle(
        x: _rng.nextDouble(),
        y: _rng.nextDouble(),
        radius: _rng.nextDouble() * 2.5 + 0.5,
        speed: _rng.nextDouble() * 0.3 + 0.1,
        drift: (_rng.nextDouble() - 0.5) * 0.15,
        opacity: _rng.nextDouble() * 0.35 + 0.05,
        phase: _rng.nextDouble() * math.pi * 2,
      );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Gradient background
        Container(decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient)),
        // Particles
        AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) => CustomPaint(
            painter: _ParticlePainter(
              particles: _particles,
              color: widget.color,
              progress: _ctrl.value,
            ),
            size: Size.infinite,
          ),
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}

class _Particle {
  double x, y;
  final double radius, speed, drift, opacity, phase;
  _Particle({
    required this.x,
    required this.y,
    required this.radius,
    required this.speed,
    required this.drift,
    required this.opacity,
    required this.phase,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final Color color;
  final double progress;

  _ParticlePainter({
    required this.particles,
    required this.color,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      // Move upward with sinusoidal drift
      final t = (progress * p.speed + p.y) % 1.0;
      final px = (p.x + math.sin(t * math.pi * 2 + p.phase) * p.drift) * size.width;
      final py = (1.0 - t) * size.height;

      final paint = Paint()
        ..color = color.withOpacity(p.opacity * (0.5 + 0.5 * math.sin(t * math.pi)))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, p.radius * 1.5);

      canvas.drawCircle(Offset(px, py), p.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) => true;
}
