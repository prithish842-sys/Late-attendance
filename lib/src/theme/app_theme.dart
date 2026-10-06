import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens from docs/DESIGN.md — do not drift from these values.
abstract final class AppColors {
  // Core identity (drawn from the college ID card).
  static const maroon900 = Color(0xFF8B1E1E);
  static const maroon700 = Color(0xFFA82B2B);
  static const navy900 = Color(0xFF1B2A4A);
  static const cream50 = Color(0xFFFAF8F5);
  static const ink900 = Color(0xFF232323);
  static const sand200 = Color(0xFFE8E2D8);

  // Functional status colors — only for late-count severity.
  static const statusOk = Color(0xFF2E7D4F);
  static const statusWarn = Color(0xFFC77A1F);
  static const statusEscalate = Color(0xFF8B1E1E);
}

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final scheme = ColorScheme.light(
      primary: AppColors.maroon900,
      onPrimary: Colors.white,
      secondary: AppColors.maroon700,
      onSecondary: Colors.white,
      surface: AppColors.cream50,
      onSurface: AppColors.ink900,
      outline: AppColors.sand200,
      outlineVariant: AppColors.sand200,
      error: const Color(0xFFB3261E),
      onError: Colors.white,
    );

    final baseText = ThemeData.light().textTheme.apply(
          bodyColor: AppColors.ink900,
          displayColor: AppColors.ink900,
        );
    final text = GoogleFonts.interTextTheme(baseText).apply(
      bodyColor: AppColors.ink900,
      displayColor: AppColors.ink900,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.cream50,
      fontFamily: 'Inter',
      textTheme: text,
      splashFactory: InkSplash.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.cream50,
        foregroundColor: AppColors.ink900,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.maroon900,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.sand200,
          disabledForegroundColor: AppColors.ink900.withValues(alpha: 0.6),
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.maroon700,
          visualDensity: VisualDensity.compact,
          textStyle: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.sand200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.sand200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.maroon700, width: 1.6),
        ),
        labelStyle: GoogleFonts.inter(color: AppColors.ink900.withValues(alpha: 0.7)),
        hintStyle: GoogleFonts.inter(color: AppColors.ink900.withValues(alpha: 0.4)),
      ),
    );
  }
}

/// Numerals (student ID, counts, times) always use tabular figures so
/// columns in reports and the gate view align — DESIGN.md §2.
TextStyle tabular([TextStyle? style]) {
  return (style ?? const TextStyle()).copyWith(
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// The rare display/identity moment — Fraunces. Reserverd for the login
/// screen app name (DESIGN.md §2, "Don't use a display serif everywhere").
TextStyle get displayStyle => GoogleFonts.fraunces(
      fontSize: 34,
      fontWeight: FontWeight.w600,
      height: 1.15,
      color: AppColors.navy900,
      letterSpacing: -0.2,
    );