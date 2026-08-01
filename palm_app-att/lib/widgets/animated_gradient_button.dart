import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// Premium gradient button with shimmer/glow effects and loading state.
class AnimatedGradientButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final Gradient? gradient;
  final double height;

  const AnimatedGradientButton({
    super.key,
    required this.label,
    this.onPressed,
    this.loading = false,
    this.icon,
    this.gradient,
    this.height = 56,
  });

  @override
  State<AnimatedGradientButton> createState() => _AnimatedGradientButtonState();
}

class _AnimatedGradientButtonState extends State<AnimatedGradientButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    final gradient = widget.gradient ?? AppTheme.accentGradient;

    return AnimatedBuilder(
      animation: _shimmer,
      builder: (context, child) {
        return GestureDetector(
          onTap: enabled ? widget.onPressed : null,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: enabled ? 1.0 : 0.5,
            child: Container(
              height: widget.height,
              decoration: BoxDecoration(
                gradient: gradient,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                boxShadow: enabled
                    ? AppTheme.glowShadow(AppTheme.accentCyan, blur: 16)
                    : null,
              ),
              child: Stack(
                children: [
                  // Shimmer overlay
                  if (enabled)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMd),
                        child: ShaderMask(
                          shaderCallback: (bounds) {
                            return LinearGradient(
                              colors: [
                                Colors.white.withOpacity(0),
                                Colors.white.withOpacity(0.15),
                                Colors.white.withOpacity(0),
                              ],
                              stops: const [0.0, 0.5, 1.0],
                              begin: Alignment(-2 + 4 * _shimmer.value, 0),
                              end: Alignment(-1 + 4 * _shimmer.value, 0),
                            ).createShader(bounds);
                          },
                          blendMode: BlendMode.srcATop,
                          child: Container(color: Colors.white),
                        ),
                      ),
                    ),
                  // Content
                  Center(
                    child: widget.loading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: AppTheme.backgroundDark,
                              strokeWidth: 2.5,
                            ),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.icon != null) ...[
                                Icon(widget.icon,
                                    color: AppTheme.backgroundDark, size: 22),
                                const SizedBox(width: AppTheme.spacingSm),
                              ],
                              Text(
                                widget.label,
                                style: AppTheme.labelLarge.copyWith(
                                  color: AppTheme.backgroundDark,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
