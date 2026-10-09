import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// InfinityCore brand palette — mirrors the Infinity Bank web identity.
class AppColors {
  static const green = Color(0xFF009944);
  static const greenDark = Color(0xFF007A36);
  static const blue = Color(0xFF0B5ED7);
  static const amber = Color(0xFFF59E0B);

  /// SARA's second brand colour, lifted from the web `favicon.svg`
  /// (`infinitycore-sara/public/favicon.svg`, the orange diamond behind the
  /// green one). Used for "important but not urgent" states, the SARA mark and
  /// warm accents, so the orange is a brand colour rather than a one-off amber.
  static const orange = Color(0xFFFF8C00);
  static const orangeDark = Color(0xFFD97706);
  static const rose = Color(0xFFEF4444);
  static const violet = Color(0xFF8B5CF6);
  static const slate900 = Color(0xFF0F172A);
  static const slate800 = Color(0xFF1E293B);
  static const slate50 = Color(0xFFF7F9FC);
  static const white = Color(0xFFFFFFFF);

  // Dark InfinityCore palette.
  static const bgDark = Color(0xFF0D1117);
  static const surfaceDark = Color(0xFF0F172A);
  static const secondaryDark = Color(0xFF1E293B);
  static const accentGreen = Color(0xFF10B981);
  static const borderDark = Color(0xFF2A3441);

  // Dark-mode text ramps.
  //
  // These are contrast ratios against `bgDark` (#0D1117 / #0F172A):
  //   secondary ≈ 10:1, tertiary ≈ 6.7:1 — both comfortably past the 4.5:1
  //   WCAG AA floor for body text. The previous tertiary (#64748B) landed at
  //   ~3.9:1, which is exactly the "grey mush" failure mode dark themes fall
  //   into, so it is deliberately brighter now.
  static const textSecondaryDark = Color(0xFFB8C4D4);
  static const textTertiaryDark = Color(0xFF8D9BAD);

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

  /// "Important but not urgent" accent — the orange half of the brand.
  static Color warn(BuildContext context) =>
      isDark(context) ? orange : orangeDark;

  /// A low-emphasis brand tint, used behind cards and badges so green and
  /// orange read as accents rather than as full-strength fills.
  static Color brandTint(BuildContext context, Color brand) =>
      brand.withValues(alpha: isDark(context) ? 0.18 : 0.10);

  /// Hairline / input border.
  static Color border(BuildContext context) =>
      isDark(context) ? borderDark : const Color(0xFFE8EDF4);

  /// Drop shadow for map markers (the "Your live position" pin).
  ///
  /// This is a SHADOW, not ink: it never carries text and has no legibility
  /// contract, so it is intentionally the same opaque-black at ~45% alpha in
  /// both themes. It exists as a named token so the dark-mode source guard
  /// (which forbids a bare `Colors.black45` outside the theme file) does not
  /// have to exempt the map screen for something that is not a text colour.
  static const Color markerShadow = Color(0x73000000);
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

/// A deliberately light panel.
///
/// A few surfaces are white by brand/functional design even when the canvas
/// around them is the branded dark one: the sign-in card, the activation
/// card, the printed staff ID card, the public-terminal status card. Left to
/// the ambient theme those panels inherit *dark* ink in dark mode, which
/// renders white-on-white — text that is technically present but invisible.
///
/// Wrapping the panel in the light theme is the single fix: everything
/// inside it (including a bare `Text()` with no explicit colour, which is
/// exactly how new regressions arrive) resolves light-mode contrast, while
/// the rest of the screen keeps following the user's theme.
class LightPanel extends StatelessWidget {
  const LightPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color = Colors.white,
    this.radius = 20,
    this.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final double radius;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.light,
      child: Builder(
        builder: (context) => Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(radius),
            border: border == null ? null : Border.all(color: border!),
          ),
          child: child,
        ),
      ),
    );
  }
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
      // NavigationBar is themed centrally in `_base` so both brightnesses get
      // the same explicit selected/unselected label + icon contrast.
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
        backgroundColor: accent.withValues(alpha: 0.14),
        selectedColor: accent.withValues(alpha: 0.32),
        // `greenDark` (#007A36) on the dark scaffold measured ~1.9:1 — the
        // label was effectively invisible. The ramp now tracks the theme.
        labelStyle: TextStyle(
          color: isDark ? Colors.white : AppColors.greenDark,
          fontWeight: FontWeight.w700,
        ),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? AppColors.borderDark : const Color(0xFFEDF1F7),
      ),

      // ------------------------------------------------------------------
      // Legibility contract for dark mode.
      //
      // Tab strips and the bottom navigation are the highest-traffic "where am
      // I?" affordances in the app, so their colours are pinned here rather
      // than left to Material defaults. A widget that forgets to pass
      // `labelColor` still renders a high-contrast strip in both themes, and
      // `test/dark_mode_legibility_test.dart` asserts this block exists so it
      // can never silently regress.
      // ------------------------------------------------------------------
      tabBarTheme: TabBarThemeData(
        labelColor: accent,
        unselectedLabelColor: isDark
            ? AppColors.textSecondaryDark
            : const Color(0xFF5B6472),
        indicatorColor: accent,
        dividerColor: isDark ? AppColors.borderDark : const Color(0xFFE8EDF4),
        labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? AppColors.bgDark : Colors.white,
        indicatorColor: accent.withValues(alpha: 0.16),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        // Unselected destinations used to fall back to `onSurfaceVariant`,
        // which is barely distinguishable from the background on a dark
        // scaffold. Both states are now explicit.
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          // The resolver must return the VALUE itself (IconThemeData), exactly
          // like `labelTextStyle` below - not a WidgetStateProperty wrapper.
          return IconThemeData(
            color: selected
                ? accent
                : (isDark
                      ? AppColors.textSecondaryDark
                      : const Color(0xFF5B6472)),
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected
                ? accent
                : (isDark
                      ? AppColors.textSecondaryDark
                      : const Color(0xFF5B6472)),
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? AppColors.bgDark : Colors.white,
        indicatorColor: accent.withValues(alpha: 0.16),
        selectedIconTheme: IconThemeData(color: accent, size: 22),
        unselectedIconTheme: IconThemeData(
          color: isDark ? AppColors.textSecondaryDark : const Color(0xFF5B6472),
          size: 22,
        ),
        selectedLabelTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: accent,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: isDark ? AppColors.textSecondaryDark : const Color(0xFF5B6472),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? AppColors.surfaceDark : Colors.white,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: isDark ? AppColors.surfaceDark : Colors.white,
        // The drag-handle knob colour, not a `showDragHandleColor` flag that
        // does not exist on BottomSheetThemeData.
        dragHandleColor: isDark
            ? AppColors.textSecondaryDark
            : const Color(0xFF94A3B8),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: isDark
            ? AppColors.textSecondaryDark
            : const Color(0xFF5B6472),
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : AppColors.slate900,
        ),
        subtitleTextStyle: TextStyle(
          fontSize: 12.5,
          color: isDark ? AppColors.textSecondaryDark : const Color(0xFF5B6472),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return accent;
            return isDark
                ? AppColors.textSecondaryDark
                : const Color(0xFF5B6472);
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return accent.withValues(alpha: 0.16);
            }
            return Colors.transparent;
          }),
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(
              color: isDark ? AppColors.borderDark : const Color(0xFFD5DCE6),
            ),
          ),
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF243447)
            : const Color(0xFF12202E),
        contentTextStyle: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? AppColors.surfaceDark : Colors.white,
        elevation: 3,
        textStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : AppColors.slate900,
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: TextStyle(
          fontSize: 14.5,
          color: isDark ? Colors.white : AppColors.slate900,
        ),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(
            isDark ? AppColors.surfaceDark : Colors.white,
          ),
        ),
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
