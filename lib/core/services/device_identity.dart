import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

/// Stable first-party identity for this install of the app.
///
///   * [deviceId]        — UUID persisted in secure storage (survives app
///                         restarts; unique across installs).
///   * [fingerprint]     — sha256 composite used by the server's daily
///                         device→employee binding layer, mirroring the web
///                         `src/utils/deviceFingerprint.js` approach: the raw
///                         client value is never stored server-side, only the
///                         server double-hash of it.
///   * [platformName]    — how the app answers "which channel am I?".
class DeviceIdentity {
  DeviceIdentity._();

  static final instance = DeviceIdentity._();

  static const _storage = FlutterSecureStorage();
  static const _deviceKey = 'infinitycore.device_id';

  String? _deviceId;
  PackageInfo? _packageInfo;
  DateTime? _fingerprintMade;

  bool get isWeb => kIsWeb;
  bool get isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  String get platformName {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      _ => 'unknown',
    };
  }

  Future<PackageInfo> _loadPackageInfo() async {
    try {
      _packageInfo ??= await PackageInfo.fromPlatform();
    } catch (_) {
      _packageInfo ??= PackageInfo(
        appName: 'InfinityCore',
        packageName: 'com.infinitybank.infinitycore',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
    }
    return _packageInfo!;
  }

  Future<String> get appVersion async {
    final info = await _loadPackageInfo();
    return info.version;
  }

  Future<String> get appBuildNumber async {
    final info = await _loadPackageInfo();
    return info.buildNumber;
  }

  Future<String> get deviceModel async {
    if (kIsWeb) return 'Web Browser';
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await DeviceInfoPlugin().androidInfo;
        return info.model;
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        return info.utsname.machine;
      }
    } catch (_) {}
    return defaultTargetPlatform.name;
  }

  Future<String> get osVersion async {
    if (kIsWeb) return '';
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await DeviceInfoPlugin().androidInfo;
        return info.version.release;
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        return info.systemVersion;
      }
    } catch (_) {}
    return '';
  }

  /// Stable per-install device id. Persisted so a re-registration on the same
  /// phone does not look like a brand-new device.
  Future<String> ensureDeviceId() async {
    if (_deviceId != null) return _deviceId!;
    try {
      final stored = await _storage.read(key: _deviceKey);
      if (stored != null && stored.isNotEmpty) {
        _deviceId = stored;
        return stored;
      }
    } catch (_) {}
    final generated = const Uuid().v4();
    _deviceId = generated;
    try {
      await _storage.write(key: _deviceKey, value: generated);
    } catch (_) {}
    return generated;
  }

  /// Composite fingerprint for the device-day binding. Hashed client-side so
  /// the value crossing the wire is already one-way; the server hashes again.
  Future<String> fingerprint() async {
    final id = await ensureDeviceId();
    final version = await appVersion;
    final build = await appBuildNumber;
    _fingerprintMade ??= DateTime.now();
    final composite =
        '$id|$platformName|$version($build)|${_fingerprintMade!.millisecondsSinceEpoch ~/ 300000}';
    return sha256.convert(composite.codeUnits).toString();
  }

  Future<Map<String, dynamic>> describe() async {
    final version = await appVersion;
    final build = await appBuildNumber;
    return {
      'deviceId': await ensureDeviceId(),
      'platform': platformName,
      'appVersion': version,
      'appBuild': build,
      'deviceName': isWeb ? 'Web Browser' : defaultTargetPlatform.name,
      'deviceModel': await deviceModel,
      'osVersion': await osVersion,
    };
  }
}
