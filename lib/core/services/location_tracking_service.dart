// ============================================================================
// LocationTrackingService - the single owner of background location state.
//
// WHY THIS FILE EXISTS
// Location tracking is a PLATFORM CAPABILITY, not a Profile setting. It used to
// be opt-in behind a "Location tracking / Review & enable" card on the Profile
// screen, which meant the service silently did nothing unless the employee went
// looking for it. That card is gone. Tracking now starts automatically for an
// authenticated, eligible employee who has already granted location permission.
//
// It does NOT duplicate the capture engine. [LocationHeartbeat] still takes the
// fixes, applies the staleness rules and talks to the server; this class only
// decides WHETHER it should be running, and reports an honest health state.
//
// WHAT THIS DELIBERATELY DOES NOT DO
// * It never claims to run when Android has not granted background location.
//   While-in-use alone does NOT mean continuous tracking, and the health enum
//   says so instead of pretending.
// * It never bypasses a permission prompt, a force-stop, or OEM battery rules.
// * It never attributes one employee's position to another. Points captured
//   while signed out are held locally and only ever released to the SAME
//   account that captured them.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import 'auth_service.dart';
import '../config/env.dart';
import 'location_heartbeat.dart';
import 'supabase_service.dart';

/// What tracking is actually doing right now.
///
/// The Profile card that used to render this is gone, so this is the single
/// source of truth for any diagnostic/status surface that needs it (a settings
/// row, a notification, a support screen). It is deliberately honest: the
/// states that Android actually produces, not optimistic ones.
enum LocationServiceHealth {
  /// Never evaluated yet.
  idle,

  /// Capturing and uploading.
  running,

  /// The app is authenticated and eligible, but the employee has not granted
  /// location permission. Attendance still works - it only needs while-in-use.
  permissionRequired,

  /// Android's location services are switched off device-wide.
  locationServicesDisabled,

  /// Running, but the last attempt could not produce a usable fix.
  temporarilyUnavailable,

  /// Signed out, but the device stays bound to its employee, so the heartbeat
  /// keeps capturing on-device and nothing is uploaded.
  recovering,
}

class LocationTrackingService with WidgetsBindingObserver {
  LocationTrackingService._();

  static final instance = LocationTrackingService._();

  final ValueNotifier<LocationServiceHealth> health =
      ValueNotifier<LocationServiceHealth>(LocationServiceHealth.idle);

  bool _started = false;
  bool _evaluating = false;
  String? _boundUserId;

  /// Re-evaluate on foreground. There is no resume-on-background: the
  /// in-process timer keeps its own cadence, and re-evaluating here only
  /// repairs state a platform restart could have changed (a revoked permission,
  /// location switched off in Settings).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _started) {
      unawaited(evaluate(reason: 'resumed'));
    }
  }

  /// Wire up at app start, immediately after the session is known.
  ///
  /// Safe to call more than once; only the first call installs the listener.
  Future<void> init() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    AuthService.instance.addListener(_onAuthChanged);
    await evaluate(reason: 'startup');
  }

  void _onAuthChanged() {
    if (AuthService.instance.isAuthenticated) {
      unawaited(evaluate(reason: 'signed-in'));
    } else {
      unawaited(_onSignedOut());
    }
  }

  // -------------------------------------------------------------------------
  // Eligibility
  // -------------------------------------------------------------------------

  /// Start, stop, or leave well alone, based on what is actually true.
  ///
  /// Idempotent by design: [LocationHeartbeat.startAutomatic] is itself
  /// idempotent and this method is safe to call from a lifecycle callback, a
  /// login, and an app launch without ever producing a second timer or a
  /// duplicate upload.
  Future<void> evaluate({String? reason}) async {
    if (_evaluating) return; // never re-enter from a notifyListeners cascade
    _evaluating = true;
    try {
      final auth = AuthService.instance;
      if (!auth.isAuthenticated) {
        await _onSignedOut();
        return;
      }

      // A session alone is not eligibility. A blocked/suspended account must
      // not be tracked, and the server stays the final authority - this is a
      // cheap local gate, not a security boundary.
      if (auth.blockedByStatus) {
        await _stop();
        _set(LocationServiceHealth.permissionRequired);
        return;
      }

      final userId = (await SupabaseService.currentSession())?.user.id;
      if (userId == null || userId.isEmpty) {
        await _stop();
        _set(LocationServiceHealth.permissionRequired);
        return;
      }

      if (_boundUserId != userId) {
        // A different account signed in on this device. Anything the previous
        // account captured must never be released to this one.
        _boundUserId = userId;
        await LocationHeartbeat.instance.rebindTo(userId);
      }

      // Device-wide location must be on before any of this means anything.
      if (!await Geolocator.isLocationServiceEnabled()) {
        await _stop();
        _set(LocationServiceHealth.locationServicesDisabled);
        return;
      }

      // Only auto-start on a permission the employee has ALREADY granted. A
      // fresh launch must never ambush someone with a system dialog, and it
      // must never nag for one already refused - the honest state is reported
      // and the legitimate prompt is raised from a real workflow (attendance),
      // not from a background launch.
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        await _stop();
        _set(LocationServiceHealth.permissionRequired);
        return;
      }

      await LocationHeartbeat.instance.startAutomatic();
      await _startNativeService();
      _set(LocationServiceHealth.running);
    } catch (_) {
      // Never let a location fault take the app down with it.
      _set(LocationServiceHealth.temporarilyUnavailable);
    } finally {
      _evaluating = false;
    }
  }

  // -------------------------------------------------------------------------
  // Native foreground service (Android only)
  // -------------------------------------------------------------------------

  static const _nativeChannel = MethodChannel(
    'com.infinitycore/location_service',
  );

  /// Hand the capture loop to the Android foreground service.
  ///
  /// The in-process Dart heartbeat covers the foreground; this is what keeps
  /// recording once Android suspends the UI isolate. The access token is
  /// passed straight through and held in memory natively - it is never written
  /// to disk and never logged.
  ///
  /// iOS has no equivalent, so this is a no-op there and the Dart heartbeat
  /// remains the only path. That is the platform's limitation, not a gap in the
  /// implementation.
  Future<void> _startNativeService() async {
    if (!Platform.isAndroid) return;
    try {
      final session = await SupabaseService.currentSession();
      final token = session?.accessToken;
      final url = Env.supabaseUrl ?? '';
      if (token == null || token.isEmpty || url.isEmpty) return;
      await _nativeChannel.invokeMethod<bool>('start', {
        'accessToken': token,
        'supabaseUrl': url,
        'rpcPath': '/rest/v1/rpc/record_employee_location',
      });
    } on PlatformException {
      // Missing session, or the channel is unavailable. The Dart heartbeat is
      // still running, so this is a degraded state rather than a failure.
    } on MissingPluginException {
      // Older native build without the service; Dart heartbeat still covers
      // the foreground.
    }
  }

  /// Stop the native service. Paired with [_startNativeService] so the two
  /// paths can never drift into running when they should not.
  Future<void> _stopNativeService() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeChannel.invokeMethod<bool>('stop');
    } on PlatformException {
      /* already gone */
    } on MissingPluginException {
      /* not present in this build */
    }
  }

  // -------------------------------------------------------------------------
  // Sign-out (device-binding model)
  // -------------------------------------------------------------------------

  /// The device stays bound to its employee across a sign-out, so the heartbeat
  /// KEEPS capturing on-device instead of being torn down. Nothing is uploaded,
  /// because there is no session for the server to attribute it to - and the
  /// points are held against the account that captured them, so they can only
  /// ever be released to that same account.
  Future<void> _onSignedOut() async {
    if (_boundUserId == null) {
      await _stop();
      _set(LocationServiceHealth.idle);
      return;
    }
    await LocationHeartbeat.instance.startLocalOnly();
    _set(LocationServiceHealth.recovering);
  }

  /// Stop both the Dart heartbeat and the native foreground service together,
  /// so the two can never drift into a state where one is running and the other
  /// believes it is not.
  Future<void> _stop() async {
    await _stopNativeService();
    await LocationHeartbeat.instance.stop();
  }

  void _set(LocationServiceHealth next) {
    if (health.value == next) return;
    health.value = next;
  }

  /// Plain-language status, for a notification or a support screen.
  String describe(LocationServiceHealth state) => switch (state) {
    LocationServiceHealth.idle => 'Location service is not active.',
    LocationServiceHealth.running => 'Location service is running.',
    LocationServiceHealth.permissionRequired =>
      'Location permission is needed to record attendance locations.',
    LocationServiceHealth.locationServicesDisabled =>
      'Location services are switched off on this device.',
    LocationServiceHealth.temporarilyUnavailable =>
      'Location service is temporarily unavailable.',
    LocationServiceHealth.recovering =>
      'Signed out. This device stays bound to its employee, so tracking '
          'continues on-device and is sent when that account signs in again.',
  };
}
