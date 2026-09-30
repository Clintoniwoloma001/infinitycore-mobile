import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/logo_assets.dart';

/// Generates the InfinityCore PNG brand assets used by flutter_launcher_icons
/// and flutter_native_splash. Run explicitly with:
///
///   GENERATE_LOGO=1 flutter test test/logo_assets_test.dart
void main() {
  test('generate brand PNG assets', () async {
    if (Platform.environment['GENERATE_LOGO'] != '1') {
      markTestSkipped('set GENERATE_LOGO=1 to regenerate assets');
      return;
    }
    final dir = Directory('assets/images');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final mark = await renderMarkPng(size: 1024, markScale: 1.0);
    File('assets/images/infinitycore_mark.png').writeAsBytesSync(mark);

    final light = await renderMarkPng(size: 1024, markScale: 1.0);
    File('assets/images/infinitycore_mark_light.png').writeAsBytesSync(light);

    final fg = await renderMarkPng(size: 1024, markScale: 0.62);
    File('assets/images/infinitycore_mark_fg.png').writeAsBytesSync(fg);

    expect(File('assets/images/infinitycore_mark.png').existsSync(), isTrue);
    expect(File('assets/images/infinitycore_mark_fg.png').existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
