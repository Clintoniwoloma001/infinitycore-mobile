import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/theme/app_theme.dart';

/// Locks in the dark-mode legibility contract.
///
/// The recurring bug was never "one screen forgot a colour" — it was that
/// nothing stopped the next screen from doing the same thing. These tests
/// make the rule mechanical:
///
///   1. The theme itself must always supply a legible ramp (and a legible
///      TabBar / NavigationBar), whatever a widget passes.
///   2. `lib/` may not reintroduce hard-coded light-only text colours.
///   3. Screens that are *deliberately* white in both themes (branded auth
///      cards, the public kiosk) must say so via `LightPanel`, so their
///      children inherit light-mode contrast instead of white-on-white.
void main() {
  /// WCAG relative-luminance contrast ratio between two opaque colours.
  double contrast(Color a, Color b) {
    // `Color.computeLuminance()` already returns relative luminance (it does
    // the sRGB→linear conversion internally), so the ratio is direct.
    double lum(Color c) => c.computeLuminance();

    final la = lum(a), lb = lum(b);
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  group('dark theme text ramp', () {
    test('every text level clears the WCAG AA 4.5:1 floor on the scaffold', () {
      const bg = AppColors.bgDark;
      const surface = AppColors.surfaceDark;
      final ramp = <String, Color>{
        'primary': Colors.white,
        'secondary': AppColors.textSecondaryDark,
        'tertiary': AppColors.textTertiaryDark,
      };

      for (final entry in ramp.entries) {
        for (final bgColor in {bg, surface}) {
          final ratio = contrast(entry.value, bgColor);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                '${entry.key} (${entry.value.toARGB32().toRadixString(16)}) '
                'is only ${ratio.toStringAsFixed(2)}:1 on '
                '${bgColor.toARGB32().toRadixString(16)}',
          );
        }
      }
    });

    test('the ramp is actually ordered, not three identical greys', () {
      // textSecondary must read brighter than textTertiary, otherwise
      // "secondary" and "tertiary" are the same thing.
      expect(
        AppColors.textSecondaryDark.computeLuminance(),
        greaterThan(AppColors.textTertiaryDark.computeLuminance()),
      );
    });
  });

  group('theme supplies legible tab and navigation affordances', () {
    test('TabBar has an explicit, legible unselected label colour', () {
      final tab = AppTheme.dark.tabBarTheme;
      expect(tab.unselectedLabelColor, isNotNull);
      expect(
        contrast(tab.unselectedLabelColor!, AppColors.bgDark),
        greaterThanOrEqualTo(4.5),
      );
      expect(tab.labelColor, isNotNull);
    });

    test('NavigationBar resolves both states to a legible colour', () {
      final bar = AppTheme.dark.navigationBarTheme;
      final selected = bar.labelTextStyle?.resolve({WidgetState.selected});
      final unselected = bar.labelTextStyle?.resolve({});
      final iconSelected = bar.iconTheme?.resolve({WidgetState.selected});
      final iconUnselected = bar.iconTheme?.resolve({});

      for (final style in [selected, unselected]) {
        expect(style, isNotNull);
        expect(
          contrast(style!.color!, AppColors.bgDark),
          greaterThanOrEqualTo(4.5),
        );
      }
      for (final icon in [iconSelected, iconUnselected]) {
        expect(icon, isNotNull);
        expect(
          contrast(icon!.color!, AppColors.bgDark),
          greaterThanOrEqualTo(4.5),
        );
      }
    });
  });

  group('app-wide source guard', () {
    /// Colours that are dark inks: fine on a white card, invisible in dark
    /// mode. A widget needing one must go through `AppColors` instead.
    final lightOnlyInks = <String>[
      'Colors.black54',
      'Colors.black45',
      'Colors.black38',
      'Colors.black26',
      'Colors.black12',
      'Color(0xFF64748B)',
      'Color(0xFF475569)',
    ];

    /// Files whose canvas is fixed by design, so dark ink is genuinely correct
    /// there. Each is either a `LightPanel` (a deliberately white island) or a
    /// camera/kiosk surface that has no theme variant at all.
    final exempt = <String, String>{
      'core/theme/app_theme.dart': 'defines the ramp itself',
      'training/signature_pad.dart': 'the signing canvas is always white',
      'features/profile/staff_id_card.dart':
          'the ID card is a fixed white artefact in every mode, '
          'matching the web StaffIdCard.jsx, and is wrapped in LightPanel',
    };

    test('no light-only ink colour is hard-coded outside the exemptions', () {
      final dir = Directory('lib');
      expect(dir.existsSync(), isTrue, reason: 'run from the package root');

      final offenders = <String>[];
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path.replaceAll(r'\', '/');
        final relFromLib = rel.startsWith('lib/')
            ? rel.substring('lib/'.length)
            : rel;
        if (exempt.containsKey(relFromLib)) continue;
        if (rel.contains('/generated/')) continue;

        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          for (final ink in lightOnlyInks) {
            if (lines[i].contains(ink)) {
              offenders.add('$rel:${i + 1} → $ink');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Dark-mode ink must come from AppColors.textSecondary/textTertiary. '
            'Found:\n${offenders.join('\n')}',
      );
    });

    test('an ink colour is never used as a container surface', () {
      // A near-black panel in light mode becomes a near-white panel in dark
      // mode, so text coloured for the opposite mode disappears. This happened
      // for real: the director employee profile used
      // `AppColors.textPrimary(context)` as a panel background with white text
      // inside it.
      final inkHelpers = <String>[
        'AppColors.textPrimary(context)',
        'AppColors.textSecondary(context)',
        'AppColors.textTertiary(context)',
      ];

      /// Seeing any of these between the ink helper and its enclosing
      /// decoration means the colour is styling text or an icon, not a
      /// background — `InputDecoration` is the classic trap, since its
      /// `decoration:` also opens `hintStyle`.
      final textMarkers = <String>[
        'Text(',
        'TextStyle',
        'style:',
        'hintStyle',
        'hintText',
        'label',
        'title',
        'icon',
        'tooltip',
        'prefix',
        'suffix',
        'helper',
      ];

      final offenders = <String>[];
      final dir = Directory('lib');
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path.replaceAll(r'\', '/');

        // Comments explain *why* a colour was chosen and routinely quote the
        // old literal, so they are dropped before scanning. The original
        // 1-based line number is kept so a failure still points at real code.
        final code = <int, String>{};
        final all = entity.readAsLinesSync();
        for (var n = 0; n < all.length; n++) {
          if (all[n].trimLeft().startsWith('//')) continue;
          code[n] = all[n];
        }
        final keys = code.keys.toList()..sort();
        for (final i in keys) {
          for (final ink in inkHelpers) {
            if (!code[i]!.contains(ink)) continue;

            // Walk upwards from the ink helper. It is a surface only if a
            // `decoration:`/`BoxDecoration(` is reached without first passing
            // through something that means this colour is text or an icon.
            var isSurface = false;
            for (var back = 1; back <= 6; back++) {
              final above = code[i - back]?.trim();
              if (above == null) break;
              if (above.isEmpty) continue;
              if (textMarkers.any(above.contains)) break;
              if (above.contains('decoration:') ||
                  above.contains('BoxDecoration(')) {
                isSurface = true;
                break;
              }
            }
            if (isSurface) {
              offenders.add('$rel:${i + 1} → $ink used as a surface');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'A container background must come from AppColors.surface/brandTint, '
            'never from a text-ink helper.\n${offenders.join('\n')}',
      );
    });
  });
}
