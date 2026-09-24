import 'dart:async';

import 'package:flutter/foundation.dart';

import '../diagnostics/auth_trace.dart';
import 'biometrics.dart';
import 'device_identity.dart';
import 'supabase_service.dart';

/// Server-side device/session layer for the mobile app.
///
/// A validated active `mobile_device_sessions` row is required before attendance
/// actions. The server enforces "one active session per user" and blocks a
/// second device from being authorized until HR/Super Admin unbinds the old
/// one. Biometric metadata is stored on the server, but no biometric template
/// or image ever leaves the device.
class MobileSessionService extends ChangeNotifier {
  MobileSessionService._();

  static final instance = MobileSessionService._();

  bool _initialized = false;
  bool? _enforced;

  /// The single in-flight registration. Second callers join this future rather
  /// than returning early with the device check still unresolved.
  Future<void>? _inFlight;
  String? _sessionId;
  String? _blockedReason;
  bool _biometricEnabled = false;
  String? _linkedAt;
  String? _lastAuthenticatedAt;
  String? _lastAttendanceAt;
  String? _deviceId;
  String? _capability;

  bool get initialized => _initialized;
  bool? get enforced => _enforced;
  String? get sessionId => _sessionId;
  String? get blockedReason => _blockedReason;
  bool get biometricEnabled => _biometricEnabled;
  String? get linkedAt => _linkedAt;
  String? get lastAuthenticatedAt => _lastAuthenticatedAt;
  String? get lastAttendanceAt => _lastAttendanceAt;
  String? get deviceId => _deviceId;
  String? get capability => _capability;

  /// Register this device as the active session for the current user.
  ///
  /// Throws on unauthorized-device detection so callers can sign out.
  ///
  /// Concurrent callers **join** the in-flight registration instead of
  /// returning early. The old `if (_initialized) return;` guard returned
  /// immediately for a second caller while the first caller's
  /// `mobile_device_register` RPC was still on the wire — which let that second
  /// caller treat the device check as "already done" and open the navigation
  /// gate before the server had answered.
  Future<void> initialize() {
    if (SupabaseService.userId == null) {
      AuthTrace.log('mss.register', 'SKIP — no authenticated user');
      return Future<void>.value();
    }
    final existing = _inFlight;
    if (existing != null) {
      AuthTrace.log('mss.register', 'JOIN in-flight registration');
      return existing;
    }
    if (_initialized) {
      AuthTrace.log(
        'mss.register',
        'SKIP — already registered for this session',
      );
      return Future<void>.value();
    }
    final future = _register().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _register() async {
    // Set synchronously, before the first await, so a duplicate call cannot
    // slip past the `_initialized` check while this one is still running.
    _initialized = true;
    AuthTrace.log('mss.register', 'START registration');

    final identity = await DeviceIdentity.instance.describe();
    _deviceId = identity['deviceId']?.toString();
    _capability = await biometricService.capabilityLabel();
    AuthTrace.log(
      'mss.register',
      'deviceId=$_deviceId capability=$_capability',
    );

    try {
      final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
        'mobile_device_register',
        params: {
          'p_device_id': _deviceId,
          'p_device_model': identity['deviceModel'],
          'p_os_version': identity['osVersion'],
          'p_app_version': identity['appVersion'],
          'p_biometric_capability': _capability,
          'p_platform': identity['platform'],
        },
      );
      _enforced = true;
      _sessionId = data['session_id']?.toString();
      _blockedReason = null;
      AuthTrace.log('mss.register', 'OK sessionId=$_sessionId -> validating');
      await validate();
    } on Exception catch (err) {
      _enforced = false;
      final message = err.toString();
      AuthTrace.log('mss.register', 'THREW: $message');
      if (message.contains('MOBILE_UNAUTHORIZED_DEVICE:')) {
        _blockedReason = message
            .split('MOBILE_UNAUTHORIZED_DEVICE:')
            .last
            .trim();
        notifyListeners();
        rethrow;
      }
      if (!SupabaseService.rpcMissing(err)) {
        debugPrint('MobileSessionService: register failed: $err');
      }
    }
    notifyListeners();
  }

  /// Refresh the active session state from the server.
  Future<Map<String, dynamic>?> validate() async {
    final deviceId =
        _deviceId ?? await DeviceIdentity.instance.ensureDeviceId();
    Map<String, dynamic>? data;
    try {
      data = await SupabaseService.client.rpc<Map<String, dynamic>>(
        'mobile_device_validate',
        params: {'p_device_id': deviceId},
      );
    } on Exception catch (err) {
      if (SupabaseService.rpcMissing(err)) return null;
      rethrow;
    }
    final ok = data['ok'] == true;
    if (!ok) {
      final reason = data['reason']?.toString() ?? 'unknown';
      final message =
          data['message']?.toString() ?? 'Mobile session is no longer valid.';
      if (reason == 'no_session' || reason == 'device_mismatch') {
        throw MobileSessionException(message, reason: reason);
      }
      return const {};
    }
    _enforced = true;
    _sessionId = data['session_id']?.toString();
    _biometricEnabled = data['biometric_enabled'] == true;
    _linkedAt = data['linked_at']?.toString();
    _lastAuthenticatedAt = data['last_authenticated_at']?.toString();
    _lastAttendanceAt = data['last_attendance_at']?.toString();
    notifyListeners();
    return data;
  }

  /// Mark this device as biometric-authorized for attendance.
  Future<void> linkBiometric() async {
    final deviceId =
        _deviceId ?? await DeviceIdentity.instance.ensureDeviceId();
    final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'mobile_device_link_biometric',
      params: {'p_device_id': deviceId},
    );
    if (data['ok'] == true) {
      _biometricEnabled = true;
      _linkedAt = DateTime.now().toIso8601String();
      _lastAuthenticatedAt = _linkedAt;
      notifyListeners();
    }
  }

  /// Record a native biometric assertion result. On success the server extends
  /// the attendance time window.
  Future<bool> authenticateBiometric(bool success) async {
    final deviceId =
        _deviceId ?? await DeviceIdentity.instance.ensureDeviceId();
    final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'mobile_device_authenticate_biometric',
      params: {'p_device_id': deviceId, 'p_success': success},
    );
    if (success && data['ok'] == true) {
      _biometricEnabled = true;
      _lastAuthenticatedAt = DateTime.now().toIso8601String();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Softly revoke the session (used on explicit sign-out). Best effort.
  Future<void> revoke() async {
    try {
      final deviceId =
          _deviceId ?? await DeviceIdentity.instance.ensureDeviceId();
      await SupabaseService.client.rpc<Map<String, dynamic>>(
        'mobile_device_revoke',
        params: {'p_device_id': deviceId},
      );
    } catch (_) {}
    _initialized = false;
    _inFlight = null;
    _sessionId = null;
    _blockedReason = null;
    _biometricEnabled = false;
    _linkedAt = null;
    _lastAuthenticatedAt = null;
    _lastAttendanceAt = null;
    notifyListeners();
  }
}

class MobileSessionException implements Exception {
  MobileSessionException(this.message, {this.reason});

  final String message;
  final String? reason;

  @override
  String toString() => message;
}
