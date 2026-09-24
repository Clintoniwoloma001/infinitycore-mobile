import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/core/services/biometrics.dart';

void main() {
  test('kAttendanceTestMode is a compile-time flag (default off)', () {
    // Without --dart-define=ATTENDANCE_TEST_MODE=true the release/real
    // biometric service must be selected, never an emulator/debug inference.
    expect(kAttendanceTestMode, false);
  });

  test('service routing follows the flag', () {
    if (kAttendanceTestMode) {
      // Same guarantee the --dart-define=true build exercises.
      expect(biometricService, same(MockBiometricAttendanceService.instance));
    } else {
      expect(biometricService, isNot(same(MockBiometricAttendanceService.instance)));
      expect(biometricService, same(RealBiometricAttendanceService.instance));
    }
  });

  test('mock service grants usable + authorized + authenticate', () async {
    final mock = MockBiometricAttendanceService.instance;
    expect(await mock.isUsable(), isTrue);
    expect(await mock.isAuthorized(), isTrue);
    expect(await mock.authenticate(reason: 'test'), isTrue);
    expect(await mock.capabilityLabel(), 'Fingerprint');
  });
}