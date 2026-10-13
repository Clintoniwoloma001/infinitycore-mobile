import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/core/theme/infinity_logo.dart';

/// Locks the in-app brand mark to the APPROVED Infinity Bank logo
/// (`test/fixtures/infinity_logo_approved_512.png`).
///
/// The master knocks the infinity glyph OUT (transparent) and the app draws it
/// white, so the master is composited over white before the diff — on white,
/// a knockout and a white glyph are the same pixels.
///
/// A pixel "matches" when every channel is within [kTolerance] of the master.
/// The trace samples every second row and the corner radius is solved from the
/// master's edge slopes, so a small mismatch is expected; a LARGE mismatch
/// means the mark has drifted from the approved art.
Future<({int total, int mismatch})> _diffAgainstMaster() async {
  final bytes = File(
    'test/fixtures/infinity_logo_approved_512.png',
  ).readAsBytesSync();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final master = frame.image;
  expect(master.width, 512);
  expect(master.height, 512);

  final mine = await renderMark(size: 512);

  final masterData =
      (await master.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final mineData = (await mine.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final m = masterData.buffer.asUint8List();
  final n = mineData.buffer.asUint8List();

  const kTolerance = 48;
  var mismatch = 0;
  for (var i = 0; i < m.length; i += 4) {
    // Composite BOTH over white: the master knocks the glyph out and the
    // painter draws a transparent background, so on white a knockout, a white
    // glyph and a transparent background are all the same pixels.
    final aM = m[i + 3] / 255.0;
    final mr = (m[i] * aM + 255 * (1 - aM)).round();
    final mg = (m[i + 1] * aM + 255 * (1 - aM)).round();
    final mb = (m[i + 2] * aM + 255 * (1 - aM)).round();
    final aN = n[i + 3] / 255.0;
    final nr = (n[i] * aN + 255 * (1 - aN)).round();
    final ng = (n[i + 1] * aN + 255 * (1 - aN)).round();
    final nb = (n[i + 2] * aN + 255 * (1 - aN)).round();
    final dr = (mr - nr).abs();
    final dg = (mg - ng).abs();
    final db = (mb - nb).abs();
    if (dr > kTolerance || dg > kTolerance || db > kTolerance) mismatch++;
  }
  return (total: m.length ~/ 4, mismatch: mismatch);
}

void main() {
  test('the brand mark matches the approved logo', () async {
    final result = await _diffAgainstMaster();
    // ignore: avoid_print
    print(
      'brand mark diff: ${result.mismatch} of ${result.total} pixels '
      '(${(result.mismatch / result.total * 100).toStringAsFixed(2)}%)',
    );
    // Antialiasing edges plus the two-row glyph trace account for a small
    // residual: measured 5.4% (mostly 1-2px edge pixels along the diagonals).
    // Anything above 8% means the mark is no longer the approved art.
    expect(
      result.mismatch / result.total,
      lessThan(0.08),
      reason: 'the painted mark drifted from the approved logo',
    );
  });

  test('the mark paints the approved brand colours', () async {
    final mine = await renderMark(size: 512);
    final data = (await mine.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final p = data.buffer.asUint8List();
    var green = 0, orange = 0, white = 0;
    for (var i = 0; i < p.length; i += 4) {
      final r = p[i], g = p[i + 1], b = p[i + 2];
      if (p[i + 3] < 200) continue;
      if ((r - 0x02).abs() <= 12 && (g - 0x9F).abs() <= 12 &&
          (b - 0x58).abs() <= 12) {
        green++;
      } else if ((r - 0xF5).abs() <= 12 && (g - 0x82).abs() <= 12 &&
          (b - 0x0F).abs() <= 12) {
        orange++;
      } else if (r > 240 && g > 240 && b > 240) {
        white++;
      }
    }
    // ignore: avoid_print
    print('brand pixels — green: $green, orange: $orange, white: $white');
    expect(green, greaterThan(40000), reason: 'green mark is missing');
    expect(orange, greaterThan(3000), reason: 'orange layer is missing');
    expect(white, greaterThan(8000), reason: 'infinity glyph is missing');
  });
}
