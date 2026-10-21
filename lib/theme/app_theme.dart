import 'package:flutter/material.dart';

/// Every color used by the app, named by the role it plays.
///
/// Widgets should use these tokens (or the [appTheme] built from them)
/// instead of Color literals, so the visual identity changes in one place.
abstract final class AppColors {
  // Brand
  /// Filled action buttons and selected states.
  static const Color primary = Color(0xFF3F9242);

  /// Darker brand shade for selected outlines.
  static const Color primaryDark = Color(0xFF2D6C2F);

  /// Bright brand green for highlights, links, live values and
  /// call-to-action buttons drawn with [onAccent] content.
  static const Color accent = Colors.greenAccent;

  static const Color onPrimary = Colors.white;
  static const Color onAccent = Colors.black;

  // Surfaces, darkest to lightest
  static const Color background = Color(0xFF0F0F0F);
  static const Color backgroundTint = Color(0xFF101A16);
  static const Color surface = Color(0xFF1B1B1B);
  static const Color surfaceHigh = Color(0xFF232323);

  // Content and lines drawn on surfaces
  static const Color foreground = Colors.white;
  static const Color foregroundSecondary = Colors.white70;
  static const Color foregroundMuted = Colors.white54;
  static const Color foregroundDisabled = Colors.white38;
  static const Color lineStrong = Colors.white24;
  static const Color divider = Colors.white12;
  static const Color border = Colors.white10;
  static const Color overlayFaint = Color(0x09FFFFFF);

  // Shadows and scrims
  static const Color shadow = Colors.black54;
  static const Color shadowSoft = Colors.black45;
  static const Color scrim = Colors.black;

  // Status
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Colors.orangeAccent;
  static const Color danger = Colors.redAccent;

  /// Fill for destructive buttons (delete, discard).
  static const Color dangerStrong = Color(0xFFD24343);
  static const Color info = Colors.lightBlueAccent;

  /// Analog readings that are inside their configured range.
  static const Color neutral = Color(0xFFA7A7A7);
  static const Color disabled = Color(0xFF5A5A5A);

  // Logic editor block categories
  static const Color blockMath = Colors.blueAccent;
  static const Color blockLogic = Colors.tealAccent;
  static const Color blockTimer = Colors.purpleAccent;
  static const Color blockPid = Colors.pinkAccent;
  static const Color blockTpo = Colors.deepOrangeAccent;
}

/// Type scale shared by the [TextTheme] and by widgets that still set an
/// explicit fontSize.
abstract final class AppFontSize {
  static const double xs = 11;
  static const double sm = 12;
  static const double md = 13;
  static const double base = 14;
  static const double lg = 16;
  static const double xl = 18;
  static const double xxl = 22;
}

const _inputRadius = BorderRadius.all(Radius.circular(12));

OutlineInputBorder _inputBorder(Color color, double width) {
  return OutlineInputBorder(
    borderRadius: _inputRadius,
    borderSide: BorderSide(color: color, width: width),
  );
}

TextTheme _textTheme(TextTheme base) {
  return base
      .copyWith(
        titleLarge: base.titleLarge?.copyWith(fontSize: AppFontSize.xxl),
        titleMedium: base.titleMedium?.copyWith(fontSize: AppFontSize.lg),
        titleSmall: base.titleSmall?.copyWith(fontSize: AppFontSize.base),
        bodyLarge: base.bodyLarge?.copyWith(fontSize: AppFontSize.lg),
        bodyMedium: base.bodyMedium?.copyWith(fontSize: AppFontSize.base),
        bodySmall: base.bodySmall?.copyWith(fontSize: AppFontSize.sm),
        labelLarge: base.labelLarge?.copyWith(fontSize: AppFontSize.base),
        labelMedium: base.labelMedium?.copyWith(fontSize: AppFontSize.sm),
        labelSmall: base.labelSmall?.copyWith(fontSize: AppFontSize.xs),
      )
      .apply(
        bodyColor: AppColors.foreground,
        displayColor: AppColors.foreground,
      );
}

ThemeData _buildTheme() {
  final colorScheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.dark,
      ).copyWith(
        primary: AppColors.accent,
        onPrimary: AppColors.onAccent,
        secondary: AppColors.primary,
        onSecondary: AppColors.onPrimary,
        error: AppColors.danger,
        surface: AppColors.surface,
        onSurface: AppColors.foreground,
        onSurfaceVariant: AppColors.foregroundSecondary,
        surfaceContainerLowest: AppColors.background,
        surfaceContainerLow: AppColors.surface,
        surfaceContainer: AppColors.surface,
        surfaceContainerHigh: AppColors.surfaceHigh,
        surfaceContainerHighest: AppColors.surfaceHigh,
        outline: AppColors.lineStrong,
        outlineVariant: AppColors.border,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    textTheme: _textTheme(base.textTheme),
    appBarTheme: const AppBarTheme(backgroundColor: AppColors.surface),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      border: _inputBorder(AppColors.foreground, 1),
      enabledBorder: _inputBorder(AppColors.foreground, 1),
      focusedBorder: _inputBorder(AppColors.foreground, 2),
      errorBorder: _inputBorder(AppColors.danger, 1),
      focusedErrorBorder: _inputBorder(AppColors.danger, 2),
    ),
  );
}

final ThemeData appTheme = _buildTheme();
