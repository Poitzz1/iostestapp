import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// PalmPay design system — premium dark-mode glassmorphism.
///
/// Deep navy base with cyan-teal accent gradients. All screens pull colors,
/// spacing, and text styles from here so the look is cohesive end-to-end.
class AppTheme {
  AppTheme._();

  // ─── Colors ────────────────────────────────────────────────────────────────

  static const Color backgroundDark = Color(0xFF0A0E21);
  static const Color surfaceDark = Color(0xFF1A1F38);
  static const Color surfaceLight = Color(0xFF252A42);
  static const Color cardGlass = Color(0x1AFFFFFF); // 10% white

  static const Color accentCyan = Color(0xFF00E5FF);
  static const Color accentTeal = Color(0xFF00BFA5);
  static const Color accentPurple = Color(0xFF7C4DFF);
  static const Color accentPink = Color(0xFFFF4081);

  static const Color successGreen = Color(0xFF69F0AE);
  static const Color warningAmber = Color(0xFFFFD740);
  static const Color errorRed = Color(0xFFFF5252);

  static const Color textPrimary = Color(0xFFF5F5F5);
  static const Color textSecondary = Color(0xB3FFFFFF); // 70% white
  static const Color textHint = Color(0x80FFFFFF); // 50% white

  // ─── Gradients ─────────────────────────────────────────────────────────────

  static const LinearGradient accentGradient = LinearGradient(
    colors: [accentCyan, accentTeal],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0x1A00E5FF), Color(0x0D00BFA5)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [backgroundDark, Color(0xFF0D1230), surfaceDark],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient scanRingGradient = LinearGradient(
    colors: [accentCyan, accentTeal, accentPurple],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  // ─── Spacing & Radius ──────────────────────────────────────────────────────

  static const double spacingXs = 4;
  static const double spacingSm = 8;
  static const double spacingMd = 16;
  static const double spacingLg = 24;
  static const double spacingXl = 32;
  static const double spacingXxl = 48;

  static const double radiusSm = 8;
  static const double radiusMd = 16;
  static const double radiusLg = 24;
  static const double radiusXl = 32;

  // ─── Shadows ───────────────────────────────────────────────────────────────

  static List<BoxShadow> glowShadow(Color color, {double blur = 20}) => [
        BoxShadow(color: color.withOpacity(0.3), blurRadius: blur, spreadRadius: 2),
        BoxShadow(color: color.withOpacity(0.1), blurRadius: blur * 2),
      ];

  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: Colors.black.withOpacity(0.4),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ];

  // ─── Glass Decoration ─────────────────────────────────────────────────────

  static BoxDecoration glassDecoration({
    double borderRadius = radiusLg,
    Color? borderColor,
    double opacity = 0.08,
  }) =>
      BoxDecoration(
        color: Colors.white.withOpacity(opacity),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: borderColor ?? Colors.white.withOpacity(0.12),
          width: 1,
        ),
        boxShadow: cardShadow,
      );

  // ─── Text Styles ──────────────────────────────────────────────────────────

  static TextStyle get displayLarge => GoogleFonts.outfit(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        color: textPrimary,
        letterSpacing: -0.5,
      );

  static TextStyle get displayMedium => GoogleFonts.outfit(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        letterSpacing: -0.3,
      );

  static TextStyle get headlineLarge => GoogleFonts.outfit(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      );

  static TextStyle get headlineMedium => GoogleFonts.outfit(
        fontSize: 20,
        fontWeight: FontWeight.w500,
        color: textPrimary,
      );

  static TextStyle get bodyLarge => GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: textPrimary,
        height: 1.5,
      );

  static TextStyle get bodyMedium => GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: textSecondary,
        height: 1.5,
      );

  static TextStyle get bodySmall => GoogleFonts.outfit(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: textHint,
      );

  static TextStyle get labelLarge => GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        letterSpacing: 0.5,
      );

  static TextStyle get labelSmall => GoogleFonts.outfit(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: textHint,
        letterSpacing: 0.5,
      );

  // ─── ThemeData ─────────────────────────────────────────────────────────────

  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: backgroundDark,
        primaryColor: accentCyan,
        colorScheme: const ColorScheme.dark(
          primary: accentCyan,
          secondary: accentTeal,
          surface: surfaceDark,
          error: errorRed,
          onPrimary: backgroundDark,
          onSecondary: backgroundDark,
          onSurface: textPrimary,
          onError: Colors.white,
        ),
        textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: headlineMedium,
          iconTheme: const IconThemeData(color: textPrimary),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withOpacity(0.06),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusMd),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusMd),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusMd),
            borderSide: const BorderSide(color: accentCyan, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusMd),
            borderSide: const BorderSide(color: errorRed),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          hintStyle: bodyMedium.copyWith(color: textHint),
          labelStyle: bodyMedium,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: accentCyan,
            foregroundColor: backgroundDark,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusMd),
            ),
            textStyle: labelLarge.copyWith(color: backgroundDark),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: accentCyan,
            textStyle: labelLarge,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: surfaceLight,
          contentTextStyle: bodyMedium.copyWith(color: textPrimary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
          behavior: SnackBarBehavior.floating,
        ),
      );
}
