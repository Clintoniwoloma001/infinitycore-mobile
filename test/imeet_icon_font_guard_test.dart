// ============================================================================
// I-Meet icon font guard
// ============================================================================
// Shorebird CANNOT ship an asset change in a patch, and the MaterialIcons font
// is an asset. So rendering an icon glyph the currently shipped font does not
// contain blocks EVERY patch until either the icon is swapped for one already
// in the font, or a new release ships the font.
//
// This has bitten the project twice already (46f4fcb for messaging, and the
// original I-Meet work), so the exact failure is pinned here rather than left
// to be rediscovered from a wall of build output.
//
// The authoritative check is tool/verify_icons_against_release_font.sh, which
// extracts release 1.1.0+9's real font from its AAB and diffs it against a
// fresh build. That is the gate a release has to pass. This test covers the
// specific regression that shipped a blank button, and fails loudly if the
// reference font goes missing (which would make the real check vacuous).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final releaseFont = File(
    'test/assets/release_1_1_0_9_MaterialIcons-Regular.otf',
  );

  test('the shipped-font reference file is present', () {
    expect(
      releaseFont.existsSync(),
      isTrue,
      reason:
          'the reference font is what makes the release check meaningful; '
          'without it the check would pass vacuously',
    );
    expect(
      releaseFont.readAsBytesSync().length,
      greaterThan(1000),
      reason: 'the reference font looks truncated or corrupt',
    );
  });

  group('No feature renders an icon missing from the shipped font', () {
    // `done_all` is the exact glyph that made release 1.1.0+9 ship a BLANK
    // "Mark all as read" button: the code referenced it, but the font the
    // release was built with did not contain it. The rounded sibling IS in the
    // font, so it is the correct choice.
    test('the blank "Mark all as read" glyph is not reintroduced', () {
      final notifications = _read(
        'lib/features/notifications/notifications_screen.dart',
      );
      expect(
        RegExp(r'\bIcons\.done_all\b').hasMatch(notifications),
        isFalse,
        reason:
            'the unrounded done_all glyph is NOT in the shipped 1.1.0+9 font; '
            'using it renders a blank box AND blocks every patch',
      );
      expect(
        RegExp(r'\bIcons\.done_all_rounded\b').hasMatch(notifications),
        isTrue,
        reason: 'the rounded sibling IS in the shipped font',
      );
    });

    test('no I-Meet screen references an icon outside the shipped font', () {
      // These are the five glyphs folder sharing/export (eb1be3f) introduced
      // and the ones replaced in ab597eb. Guarding them by name is enough: a
      // NEW icon in I-Meet is caught by the release check, and this test names
      // the specific cases that have already broken a build once.
      const mustNotAppear = <String>[
        'person_add_alt',
        'person_remove_outlined',
        'download_outlined',
        'folder_shared_outlined',
        'group_outlined',
        'checklist',
        'edit_note',
        'expand_less',
        'folder_outlined',
        'archive_outlined',
        'article_outlined',
        'people_outline',
        'place_outlined',
        'stop_circle_outlined',
        'pause_circle_filled',
        'upcoming',
        'today',
        'history',
        'replay',
        'mic',
        'pause',
        'play_arrow',
        'stop',
        'mic_none',
      ];
      final offenders = <String>[];
      for (final entry in Directory(
        'lib/features/imeet',
      ).listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        final source = _read(entry.path);
        for (final name in mustNotAppear) {
          if (RegExp('\\bIcons\\.$name\\b').hasMatch(source)) {
            offenders.add('${entry.path}: Icons.$name');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these glyphs are absent from the shipped font, so each one blocks '
            'a patch:\n  ${offenders.join('\n  ')}\n'
            'Run tool/map_icons_to_shipped_font.py to substitute them.',
      );
    });

    test('the I-Meet screens do render real icons', () {
      // Guards against the guard: if the scan silently stopped matching, the
      // test above would pass while protecting nothing.
      final source = Directory('lib/features/imeet')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => _read(f.path))
          .join('\n');
      expect(
        RegExp(r'\bIcons\.\w+').allMatches(source).length,
        greaterThan(20),
        reason: 'the icon scan must actually be matching something',
      );
    });
  });
}
