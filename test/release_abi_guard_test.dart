// ============================================================================
// Release guard: the installed binary must contain the ABI the device needs
// ============================================================================
// THE CRASH THIS LOCKS OUT (SM-J415F, armeabi-v7a, 1.1.9+23):
//
//   java.lang.RuntimeException: ... v7: Could not find 'libflutter.so'.
//     Looked for: [armeabi-v7a, armeabi], but only found: [arm64-v8a].
//
// The release was built with `--target-platform android-arm64`, which emits
// libflutter.so for arm64 only. A 32-bit device then finds nothing to load and
// dies on the first frame of MainActivity - an instant crash on launch with no
// Dart involved at all, which is indistinguishable from an app bug but is purely
// a build-command mistake.
//
// The rule: NEVER pass --target-platform to `shorebird release android` or
// `flutter build` unless the target device is known to be 64-bit only. The
// default ABI set (arm, arm64, x64) covers every device in the fleet.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const _gradleSource = 'android/app/build.gradle.kts';
const _scriptsDir = 'scripts';

void main() {
  group('Release ABI coverage', () {
    test('the Gradle build keeps all default ABIs', () {
      final source = File(_gradleSource).readAsStringSync();

      // ABI filters narrow the APK to the listed architectures. If someone
      // pins this to arm64 for size, every 32-bit device crashes on launch.
      final abiFilter = RegExp(
        r'abiFilters\s*[=.]\s*\[?\s*"([^"]*)"',
        caseSensitive: false,
      );
      final matches = abiFilter.allMatches(source).toList();
      for (final match in matches) {
        final abi = match.group(1)!;
        expect(
          abi,
          isNot('arm64-v8a'),
          reason: 'an arm64-only abiFilter crashes 32-bit devices on launch',
        );
      }

      expect(
        source,
        isNot(contains('--target-platform android-arm64')),
        reason: 'the release command must use the default ABI set',
      );
    });

    test('a smoke test exists that installs and launches the APK', () {
      // A missing libflutter.so is caught the moment an APK is installed on a
      // real device, so the release flow must keep that check.
      final script = File('$_scriptsDir/release_smoke.sh');
      expect(script.existsSync(), isTrue);
      final body = script.readAsStringSync();
      final detectsCrash =
          body.contains('libflutter.so') || body.contains('FATAL EXCEPTION');
      expect(
        detectsCrash,
        isTrue,
        reason: 'the smoke test must catch a missing native library',
      );
      expect(body.contains('install'), isTrue);
    });

    test('the release is not pinned to a 64-bit-only target', () {
      // Guard the release pipeline itself: any script that builds the shipped
      // artifact must not restrict ABIs.
      final scripts =
          Directory(_scriptsDir).listSync().whereType<File>().where(
                (f) => f.path.endsWith('.sh'),
              );
      for (final script in scripts) {
        final body = script.readAsStringSync();
        expect(
          body.splitMapJoin(
            '--target-platform',
            onMatch: (_) => 'found',
            onNonMatch: (_) => '',
          ),
          isEmpty,
          reason: '${script.path} must not restrict the target ABI',
        );
      }
    });
  });
}
