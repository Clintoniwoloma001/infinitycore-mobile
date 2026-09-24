import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

const _mockChannel = MethodChannel('com.infinitycore/device');

/// Location-integrity heuristics for attendance actions.
///
/// These are best-effort "is the coordinate plausibly real" checks layered on
/// top of what the server already enforces (geofence + device-day binding).
/// They never replace server verification.
class LocationIntegrity {
  LocationIntegrity._();

  static final instance = LocationIntegrity._();

  bool get _isAndroidNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Report whether the current fix is mock/spoofed.
  ///
  /// Returns `null` when the signal is unavailable (web, mock-detection API
  /// missing, permission denied) — callers treat null as "unverified", not
  /// "clean".
  Future<bool?> mockDetected() async {
    if (_isAndroidNative) {
      try {
        final result = await _mockChannel.invokeMethod<bool>('isMockLocation');
        if (result != null) return result;
      } on MissingPluginException {
        return null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// A guard that the client can present to the server as part of clock
  /// actions; the server keeps authority but sees the reported signal.
  Future<String?> mockDetectionToken() async {
    final mock = await mockDetected();
    if (mock == null) return null;
    return mock ? 'mock_detected' : 'no_mock_detected';
  }

  /// The Android emulator ships with a default GPS fix at Google's Mountain
  /// View campus (37.4219983, -122.084). A fix at exactly those coordinates
  /// almost always means "emulator with no real location configured", never
  /// an actual attendance position — surface it instead of silently
  /// accepting obviously-wrong evidence.
  static const double emulatorDefaultLat = 37.4219983;
  static const double emulatorDefaultLng = -122.084;

  /// True when [lat]/[lng] match the Android emulator's default Googleplex
  /// fix (within ~11 m).
  bool looksLikeEmulatorDefault(double lat, double lng) =>
      (lat - emulatorDefaultLat).abs() < 0.0001 &&
      (lng - emulatorDefaultLng).abs() < 0.0001;

  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();

  Future<LocationPermission> permissionState() => Geolocator.checkPermission();

  /// Does this fix look physically plausible? Accuracy must be between 0m and
  /// a few kilometres; larger values are treated as suspect.
  bool plausibleFix(Position position) =>
      position.accuracy > 0 && position.accuracy <= 9999;

  /// Aggregate check for a clock action. Returns a problem description, or
  /// `null` when things look OK. Mirrors the server `LOCATION_*:` messages so
  /// callers can map to the same strings the web app shows.
  Future<String?> preflightCheck({required bool requireGps}) async {
    final service = await Geolocator.isLocationServiceEnabled();
    if (requireGps && !service) {
      return 'LOCATION_REQUIRED:Location services are turned off. Enable them and try again.';
    }
    if (requireGps) {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        return 'LOCATION_REQUIRED:Location permission is required to clock in.';
      }
      if (permission == LocationPermission.deniedForever) {
        return 'LOCATION_REQUIRED:Location permission is permanently blocked. Enable it in app settings.';
      }
    }
    final mock = await mockDetected();
    if (mock == true) {
      return 'LOCATION_INVALID:Spoofed location detected. Disable mock location and try again.';
    }
    return null;
  }
}
