import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/core/services/biometrics.dart';
import 'package:infinitycore/core/services/notification_service.dart';

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
      expect(
        biometricService,
        isNot(same(MockBiometricAttendanceService.instance)),
      );
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

  group('biometric setup detection is not re-prompted', () {
    test('the mock service reports setup as already complete', () async {
      // The mock stands in for an already-enrolled device, so asking a user to
      // configure biometrics again would be the exact bug being guarded.
      expect(
        await MockBiometricAttendanceService.instance.hasCompletedSetup(),
        isTrue,
      );
    });

    test('every implementation is constructible with the new method', () {
      // Guards the interface: a service added without this override would
      // reintroduce the re-prompt, so the analyzer must fail loudly.
      expect(RealBiometricAttendanceService.instance, isNotNull);
      expect(MockBiometricAttendanceService.instance, isNotNull);
    });
  });

  group('clock in/out notification ids are stable and distinct', () {
    test('a repeat punch replaces its own notification', () {
      // The old code used `DateTime.now().millisecondsSinceEpoch ~/ 1000` as
      // the id, so every punch produced a new id and old confirmations piled up
      // in the shade. Fixed ids make a retry replace its predecessor.
      expect(NotificationService.attendanceClockedInId, isNot(equals(0)));
      expect(
        NotificationService.attendanceClockedInId,
        isNot(equals(NotificationService.attendanceClockedOutId)),
      );
    });

    test('confirmation ids do not collide with the reminder alarms', () {
      // Sharing an id with a scheduled reminder would let a confirmation
      // silently cancel the next day's alarm.
      expect(
        NotificationService.attendanceClockedInId,
        isNot(equals(NotificationService.reminderClockInId)),
      );
      expect(
        NotificationService.attendanceClockedOutId,
        isNot(equals(NotificationService.reminderClockOutId)),
      );
    });
  });
}
