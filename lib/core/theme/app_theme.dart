import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// InfinityCore brand palette — mirrors the Infinity Bank web identity.
class AppColors {
  static const green = Color(0xFF009944);
  static const greenDark = Color(0xFF007A36);
  static const blue = Color(0xFF0B5ED7);
  static const amber = Color(0xFFF59E0B);
  static const rose = Color(0xFFEF4444);
  static const violet = Color(0xFF8B5CF6);
  static const slate900 = Color(0xFF0F172A);
  static const slate800 = Color(0xFF1E293B);
  static const slate50 = Color(0xFFF7F9FC);

  // Dark InfinityCore palette.
  static const bgDark = Color(0xFF0D1117);
  static const surfaceDark = Color(0xFF0F172A);
  static const secondaryDark = Color(0xFF1E293B);
  static const accentGreen = Color(0xFF10B981);
  static const borderDark = Color(0xFF2A3441);
  static const textSecondaryDark = Color(0xFF94A3B8);
  static const textTertiaryDark = Color(0xFF64748B);

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// Brand accent — `#10B981` in dark mode, legacy Infinity green in light.
  static Color accent(BuildContext context) =>
      isDark(context) ? accentGreen : green;

  /// Card / surface background.
  static Color surface(BuildContext context) =>
      isDark(context) ? surfaceDark : Colors.white;

  /// Primary text (headings, values).
  static Color textPrimary(BuildContext context) =>
      isDark(context) ? Colors.white : slate900;

  /// Secondary text (labels, captions).
  static Color textSecondary(BuildContext context) =>
      isDark(context) ? textSecondaryDark : Colors.black54;

  /// Tertiary / muted text (metadata, hints).
  static Color textTertiary(BuildContext context) =>
      isDark(context) ? textTertiaryDark : Colors.black45;

  /// Muted icons / dividers.
  static Color iconMuted(BuildContext context) =>
      isDark(context) ? textTertiaryDark : Colors.black38;

  /// Hairline / input border.
  static Color border(BuildContext context) =>
      isDark(context) ? borderDark : const Color(0xFFE8EDF4);
}

/// Semantic surface blocks used on the deepest (authenticated) surfaces.
class SurfaceColors {
  static const splashDark = Color(0xFF0D1117);
  static const lockBackground = Color(0xFF0F172A);

  /// Green tint used by the "server verified" styles.
  static const successTintDark = Color(0xFF0A2820);
  static const successBorderDark = Color(0xFF14532D);
  static const warningTintDark = Color(0xFF2A2110);
  static const warningBorderDark = Color(0xFF7C5A12);
}

class AppTheme {
  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.green,
      brightness: Brightness.light,
      primary: AppColors.green,
      secondary: AppColors.blue,
      surface: Colors.white,
    );
    return _base(scheme, Brightness.light).copyWith(
      scaffoldBackgroundColor: AppColors.slate50,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: AppColors.slate900,
        titleTextStyle: TextStyle(
          color: AppColors.slate900,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: AppColors.green.withValues(alpha: 0.14),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
    );
  }

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accentGreen,
      brightness: Brightness.dark,
      primary: AppColors.accentGreen,
      secondary: AppColors.blue,
      surface: AppColors.surfaceDark,
      onSurface: Colors.white,
    );
    return _base(scheme, Brightness.dark).copyWith(
      scaffoldBackgroundColor: AppColors.bgDark,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: AppColors.bgDark,
        foregroundColor: Colors.white,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.bgDark,
        indicatorColor: AppColors.accentGreen.withValues(alpha: 0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
    );
  }

  static ThemeData _base(ColorScheme scheme, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final surface = scheme.surface;
    final border = isDark ? AppColors.borderDark : const Color(0xFFD5DCE6);
    final cardBorder = isDark ? AppColors.borderDark : const Color(0xFFE8EDF4);
    final cardColor = isDark ? scheme.surface : Colors.white;
    final accent = isDark ? AppColors.accentGreen : AppColors.green;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cardBorder),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accent, width: 1.6),
        ),
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: accent.withValues(alpha: 0.12),
        selectedColor: accent,
        labelStyle: const TextStyle(color: AppColors.greenDark),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide.none,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? AppColors.borderDark : const Color(0xFFEDF1F7),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
