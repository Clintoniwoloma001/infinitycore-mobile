import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

Future<({int painted, int opaque})> analyze(ui.Image img) async {
  final bytes =
      (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  var painted = 0, opaque = 0;
  for (var i = 0; i < bytes.length; i += 4) {
    final a = bytes[i + 3];
    if (a > 0) painted++;
    if (a == 255) opaque++;
  }
  return (painted: painted, opaque: opaque);
}

void main() {
  for (final name in [
    'assets/images/infinitycore_mark.png',
    'assets/images/infinitycore_mark_fg.png',
  ]) {
    test('decoded $name', () async {
      final bytes = File(name).readAsBytesSync();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final r = await analyze(img);
      // ignore: avoid_print
      print('$name -> $r');
      expect(r.painted, greaterThan(100000));
    });
  }
}