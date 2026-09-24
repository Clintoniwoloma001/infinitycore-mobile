import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Explicit compile-time switch for integration/automation runs.
///
/// When `ATTENDANCE_TEST_MODE=true` the attendance flow uses the deterministic
/// [MockBiometricAttendanceService] instead of device biometrics. It is never
/// inferred from debug mode, emulator detection or biometric availability —
/// only this flag switches the implementation. A release build without this
/// flag always uses the real device biometrics.
const bool kAttendanceTestMode = bool.fromEnvironment(
  'ATTENDANCE_TEST_MODE',
  defaultValue: false,
);

/// Abstraction over the biometric gate used by the attendance flow.
///
/// Only the identity-verification step is mocked in test mode; employee
/// verification, device binding, geofence, policy and server-side RPC checks
/// are untouched and always active.
abstract class BiometricAttendanceService {
  /// True when this device actually has usable biometric hardware/enrollment
  /// (or, in test mode, the simulated enrollment). Attendance can proceed
  /// without a biometric assertion when [isUsable] is false, as long as every
  /// other attendance requirement (geofence, branch, valid staff) passes —
  /// this is how phones without biometrics or with failed biometric firmware
  /// are still allowed to record attendance normally.
  Future<bool> isUsable();

  /// True when the device has been linked for biometric attendance on the
  /// server (iOS/Android capable devices only).
  Future<bool> isAuthorized();

  /// Perform a native biometric assertion. Returns true on success.
  Future<bool> authenticate({
    String reason = 'Confirm your identity to record attendance',
  });

  /// Stable capability label recorded on the server device session.
  /// `'none'` means the device has no usable biometric method.
  Future<String> capabilityLabel();
}

/// Real device implementation backed by `local_auth`.
class RealBiometricAttendanceService implements BiometricAttendanceService {
  RealBiometricAttendanceService._();

  static final instance = RealBiometricAttendanceService._();
  final LocalAuthentication _auth = LocalAuthentication();

  bool? _supported;

  Future<bool> get _supportedCache async {
    if (_supported != null) return _supported!;
    try {
      _supported = await _auth.isDeviceSupported();
    } catch (_) {
      _supported = false;
    }
    return _supported!;
  }

  Future<List<BiometricType>> _types() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> isUsable() async {
    if (kAttendanceTestMode) return true;
    if (!await _supportedCache) return false;
    try {
      if (!await _auth.canCheckBiometrics) return false;
    } catch (_) {
      return false;
    }
    return (await _types()).isNotEmpty;
  }

  @override
  Future<bool> isAuthorized() => Future.value(true);

  @override
  Future<bool> authenticate({
    String reason = 'Confirm your identity to record attendance',
  }) async {
    if (kAttendanceTestMode) return true;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } catch (e) {
      debugPrint('Biometrics.authenticate: ${e.runtimeType}: $e');
      return false;
    }
  }

  @override
  Future<String> capabilityLabel() async {
    if (kAttendanceTestMode) return 'Biometrics';
    try {
      if (!await _supportedCache) return 'none';
      if (!await _auth.canCheckBiometrics) return 'none';
    } catch (_) {
      return 'none';
    }
    final types = await _types();
    if (types.isEmpty) return 'none';
    return describe(types);
  }

  /// Human label for the enrolled biometric methods.
  String describe(List<BiometricType> availableTypes) {
    if (availableTypes.isEmpty) return 'Biometrics';
    final labels = availableTypes
        .map(
          (t) => switch (t) {
            BiometricType.face => 'Face ID',
            BiometricType.fingerprint => 'Fingerprint',
            BiometricType.iris => 'IRIS',
            BiometricType.strong => 'Biometric key',
            BiometricType.weak => 'Biometrics',
          },
        )
        .toSet();
    return labels.isEmpty ? 'Biometrics' : labels.join(', ');
  }
}

/// Deterministic mock used when `ATTENDANCE_TEST_MODE=true`. Authorizes inline
/// so automated/integration runs never need manual Profile → Biometric setup.
/// It only replaces the local identity-assertion step.
class MockBiometricAttendanceService implements BiometricAttendanceService {
  MockBiometricAttendanceService._();

  static final instance = MockBiometricAttendanceService._();

  @override
  Future<bool> isUsable() async => true;

  @override
  Future<bool> isAuthorized() async => true;

  @override
  Future<bool> authenticate({
    String reason = 'Confirm your identity to record attendance',
  }) async => true;

  @override
  Future<String> capabilityLabel() async => 'Fingerprint';
}

/// The active biometric service for the app.
BiometricAttendanceService get biometricService => kAttendanceTestMode
    ? MockBiometricAttendanceService.instance
    : RealBiometricAttendanceService.instance;

/// Backward-compatible convenience facade (attendance/profile callers).
class Biometrics {
  Biometrics._();

  static final instance = Biometrics._();

  Future<bool> get supported =>
      RealBiometricAttendanceService.instance.isUsable();

  Future<bool> get available =>
      RealBiometricAttendanceService.instance.isUsable();

  Future<List<BiometricType>> types() async => const [];

  Future<bool> authenticate({String reason = 'Authenticate to continue'}) =>
      biometricService.authenticate(reason: reason);

  String describe(List<BiometricType> availableTypes) =>
      RealBiometricAttendanceService.instance.describe(availableTypes);

  Future<String> capabilityLabel() => biometricService.capabilityLabel();
}
