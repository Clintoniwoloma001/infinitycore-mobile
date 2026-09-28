// ============================================================================
// Background location heartbeat (Phase 70)
// ============================================================================
// The ~30-minute workforce tracking heartbeat. THREE THINGS ARE KEPT STRICTLY
// SEPARATE, and this file is only the middle one:
//
//   1. ATTENDANCE LOCATION  -> authoritative for clock-in/out. Owned by
//      resolve_employee_location() in Postgres. This file never influences it.
//   2. BACKGROUND HEARTBEAT -> THIS FILE. Approximate, best-effort telemetry.
//   3. MOVEMENT HISTORY     -> derived from the recorded observations, server
//      side. Never inferred between points.
//
// HONESTY ABOUT THE CADENCE
// A 30-minute interval is a REQUEST, not a guarantee. Android and iOS both
// delay background work for battery, connectivity and app state. This service
// therefore records the ACTUAL timestamp of every observation, never
// back-fills or invents a missing point, and surfaces the real gap so the UI
// can say "last seen 42 minutes ago" instead of showing a fabricated live
// position.
//
// OFFLINE BEHAVIOUR
// A point captured without connectivity is queued on-device with its original
// recorded_at and uploaded later. The server keeps recorded_at (when it was
// seen) and uploaded_at (when it arrived) separate.
//
// PERMISSION UX
// Collection is NEVER silent. [explainAndRequest] shows the purpose first;
// only then is the runtime permission asked for, and only the minimum needed.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';

import 'supabase_service.dart';

class LocationHeartbeat {
  LocationHeartbeat._();

  static final instance = LocationHeartbeat._();

  /// The requested cadence. A request, not a guarantee.
  static const Duration interval = Duration(minutes: 30);

  /// Never record a fix this stale: it would misrepresent where someone is.
  static const Duration maxFixAge = Duration(minutes: 5);

  /// An unbounded queue would grow forever on a device that stays offline.
  static const int maxQueue = 500;

  static const _queueKey = 'infinitycore.location.queue.v1';
  static const _enabledKey = 'infinitycore.location.tracking.enabled';

  // Encrypted at rest: the offline queue holds precise employee coordinates.
  final _storage = const FlutterSecureStorage();

  Timer? _timer;
  bool _running = false;
  bool _inFlight = false;
  int _pendingCount = 0;

  /// The account this device is bound to. Points captured while signed out are
  /// tagged with it and are only ever released to the SAME account, so a second
  /// employee signing in on a bound device can never inherit the first
  /// employee's queued positions.
  String? _boundUserId;

  /// True while signed out but still bound to an employee: keep capturing on
  /// device, upload nothing. There is no session for the server to attribute a
  /// point to, and guessing would be worse than holding it.
  bool _localOnly = false;

  /// Exposed so a screen can show honest status instead of assuming success.
  final ValueNotifier<HeartbeatStatus> status = ValueNotifier<HeartbeatStatus>(
    const HeartbeatStatus(),
  );

  bool get isRunning => _running;

  /// The disclosure shown BEFORE any permission prompt. Location is never
  /// collected silently.
  ///
  /// Kept truthful after the Profile card was removed: there is no in-app
  /// toggle any more, so claiming "turn it off in Settings" would point people
  /// at a switch that does not exist. The real control is Android's own
  /// permission for this app.
  static const String purposeMessage =
      'InfinityCore uses your location during authorized attendance and tracking '
      'periods to verify attendance locations and support workforce operations. '
      'Once you have allowed location access, tracking starts automatically '
      'while you are signed in - you do not need to switch it on yourself. '
      'To stop it, change InfinityCore\'s location permission in your device '
      'settings. Clocking in and out works either way.';

  // -------------------------------------------------------------------------
  // Permission UX
  // -------------------------------------------------------------------------

  /// Asks for the minimum permission needed, in the right order:
  /// service enabled -> while-in-use -> (only then) background.
  ///
  /// Returns true only when BOTH are held. A false result is not an error: it
  /// means attendance keeps working (it only needs while-in-use) and the
  /// heartbeat simply stays off.
  Future<bool> explainAndRequest() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return false;
      }

      // Background location is a SEPARATE grant, meaningful only once the app
      // is not in the foreground. A refusal is not fatal - the heartbeat just
      // pauses when the app is backgrounded.
      if (permission == LocationPermission.whileInUse) {
        await Geolocator.requestPermission();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Control
  // -------------------------------------------------------------------------

  /// Start the heartbeat. Safe to call repeatedly; only one timer runs.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _localOnly = false;
    await _storage.write(key: _enabledKey, value: '1');
    // Record one immediately so an admin does not wait a full interval to see
    // anything, then settle onto the requested cadence.
    unawaited(captureOnce());
    _timer = Timer.periodic(interval, (_) => unawaited(captureOnce()));
  }

  /// Start tracking for an authenticated, eligible employee.
  ///
  /// Identical to [start] but does not depend on the old opt-in consent flag:
  /// tracking is now an automatic platform capability, so the gate is "is this
  /// an eligible employee with permission" - which
  /// [LocationTrackingService] decides - and not "did someone visit a card and
  /// press a button".
  Future<void> startAutomatic({String? boundUserId}) async {
    if (boundUserId != null) _boundUserId = boundUserId;
    if (_running && !_localOnly) return;
    _running = true;
    _localOnly = false;
    unawaited(captureOnce());
    _timer ??= Timer.periodic(interval, (_) => unawaited(captureOnce()));
  }

  /// Keep capturing on device, upload nothing.
  ///
  /// Used on sign-out: the device remains bound to its employee, so the
  /// requirement is to keep the heartbeat alive, but with no session there is
  /// nothing for the server to attribute a point to. Points go to the encrypted
  /// local queue and are released only if the same account signs back in.
  Future<void> startLocalOnly() async {
    if (_running && _localOnly) return;
    _running = true;
    _localOnly = true;
    unawaited(captureOnce());
    _timer ??= Timer.periodic(interval, (_) => unawaited(captureOnce()));
  }

  /// Point the device at a different account.
  ///
  /// Anything queued by the previous account is discarded rather than carried
  /// over: the previous employee's positions must never be attributed to the
  /// new one.
  Future<void> rebindTo(String userId) async {
    if (_boundUserId == userId) return;
    _boundUserId = userId;
    await _writeQueue(const []);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _localOnly = false;
    await _storage.delete(key: _enabledKey);
    status.value = const HeartbeatStatus();
  }

  // NOTE: the old `restoreIfEnabled()` (resume only if the employee had
  // previously pressed "Review & enable" on the Profile card) is deliberately
  // GONE. Tracking is no longer opt-in, so resuming from a stored consent flag
  // would under-start it for every employee who never visited that card.
  // [LocationTrackingService] now decides on every start from live state
  // instead: authenticated + eligible + permission already granted.

  // -------------------------------------------------------------------------
  // Capture
  // -------------------------------------------------------------------------

  /// Take one observation and upload it, or queue it if offline.
  Future<void> captureOnce() async {
    if (_inFlight) return; // never overlap two fixes
    _inFlight = true;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        status.value = const HeartbeatStatus(
          running: true,
          note: 'Location permission is off, so tracking is paused.',
        );
        return;
      }

      if (!await Geolocator.isLocationServiceEnabled()) {
        status.value = const HeartbeatStatus(
          running: true,
          note: 'Location services are off, so tracking is paused.',
        );
        return;
      }

      final now = DateTime.now();
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );

      // A fix that is too old is worse than no fix: an administrator would be
      // shown a position the device no longer holds.
      if (now.difference(position.timestamp) > maxFixAge) {
        status.value = const HeartbeatStatus(
          running: true,
          note: 'Last fix was too old to trust; nothing was recorded.',
        );
        return;
      }

      final observation = <String, dynamic>{
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        // recorded_at is when the device SAW this position.
        'recorded_at': position.timestamp.toUtc().toIso8601String(),
        'source': 'mobile',
        'source_detail': 'heartbeat',
        // Local-only attribution. Never sent to the server - the server
        // resolves the employee from the session - but it is what stops one
        // account's queued points being released to another on the same device.
        'captured_for': _boundUserId,
      };

      // Signed out but still bound to an employee: hold the point on device
      // rather than trying to upload it. There is no session for the server to
      // attribute it to, and an unattributed write would be worse than a
      // delayed one.
      if (_localOnly) {
        await _enqueue(observation);
        status.value = HeartbeatStatus(
          running: true,
          lastRecordedAt: position.timestamp,
          pending: _pendingCount,
          note:
              'Signed out. Saved on this device and sent when the account '
              'signs in again.',
        );
        return;
      }

      final result = await _upload(observation);
      if (result == _UploadResult.ok) {
        status.value = HeartbeatStatus(
          running: true,
          lastRecordedAt: position.timestamp,
          pending: _pendingCount,
        );
        unawaited(_flushQueue());
      } else if (result == _UploadResult.retry) {
        await _enqueue(observation);
        status.value = HeartbeatStatus(
          running: true,
          lastRecordedAt: position.timestamp,
          pending: _pendingCount,
          note: 'No connection. The observation is saved and will be sent.',
        );
      } else {
        // Permanent rejection: stop rather than queue points that can never
        // be delivered, and tell the employee plainly why. The status is set
        // AFTER stop() because stop() clears it.
        await stop();
        status.value = const HeartbeatStatus(
          note:
              'Tracking stopped: this account has no employee record '
              'linked, so locations cannot be accepted.',
        );
      }
    } catch (_) {
      status.value = const HeartbeatStatus(
        running: true,
        note: 'Could not read a location fix this time.',
      );
    } finally {
      _inFlight = false;
    }
  }

  // -------------------------------------------------------------------------
  // Upload + offline queue
  // -------------------------------------------------------------------------

  /// Why an upload did not simply succeed.
  ///
  /// The distinction matters: a lost connection should fill the queue, while a
  /// server-side rejection will NEVER succeed no matter how many times it is
  /// retried, so queueing it would just burn battery forever.
  Future<_UploadResult> _upload(Map<String, dynamic> observation) async {
    try {
      final res = await SupabaseService.client.rpc(
        'record_employee_location',
        params: <String, dynamic>{
          'p_lat': observation['latitude'],
          'p_lng': observation['longitude'],
          'p_accuracy': observation['accuracy'],
          // The ORIGINAL observation time, not now(): this is what preserves
          // the recorded_at / uploaded_at distinction on the server.
          'p_recorded_at': observation['recorded_at'],
          'p_source': observation['source'],
          'p_source_detail': observation['source_detail'],
        },
      );
      if (res is Map && res['ok'] == true) return _UploadResult.ok;
      // A well-formed response that is not ok:() is a contract mismatch. Treat
      // as retryable rather than permanent so a server rollout is survivable.
      return _UploadResult.retry;
    } catch (e) {
      final text = '$e';
      // Permanent, server-decided failures: an account with no employee record
      // or a rejected write. Retrying can never fix these.
      if (text.contains('NO_EMPLOYEE_PROFILE') ||
          text.contains('FORBIDDEN') ||
          text.contains('permission denied') ||
          text.contains('PGRST301')) {
        return _UploadResult.fatal;
      }
      // Everything else reads as "the network was not there".
      return _UploadResult.retry;
    }
  }

  Future<List<Map<String, dynamic>>> _readQueue() async {
    try {
      final raw = await _storage.read(key: _queueKey);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeQueue(List<Map<String, dynamic>> items) async {
    try {
      await _storage.write(key: _queueKey, value: jsonEncode(items));
      _pendingCount = items.length;
    } catch (_) {
      /* storage unavailable: drop rather than grow without bound */
    }
  }

  /// Queue holds at most [maxQueue] entries; the oldest are the least useful
  /// for a movement history, so they go first.
  Future<void> _enqueue(Map<String, dynamic> observation) async {
    final items = await _readQueue();
    items.add(observation);
    if (items.length > maxQueue) {
      items.removeRange(0, items.length - maxQueue);
    }
    await _writeQueue(items);
  }

  /// Retry queued observations oldest-first. Each keeps its original
  /// recorded_at, so the server still shows the true observation time.
  ///
  /// Only entries captured for the account that owns this device are released.
  /// Anything tagged for a different account is dropped rather than uploaded:
  /// the previous employee's positions must never be attributed to whoever
  /// signed in afterwards.
  Future<void> _flushQueue() async {
    final items = await _readQueue();
    if (items.isEmpty) {
      _pendingCount = 0;
      return;
    }
    final remaining = <Map<String, dynamic>>[];
    for (final item in items) {
      final capturedFor = item['captured_for'];
      if (capturedFor != null && capturedFor != _boundUserId) {
        // Belongs to another account. Delete it.
        continue;
      }
      final result = await _upload(item);
      if (result == _UploadResult.retry) remaining.add(item);
    }
    await _writeQueue(remaining);
  }

  /// Observations waiting for a connection.
  Future<int> pendingCount() async {
    final items = await _readQueue();
    _pendingCount = items.length;
    return _pendingCount;
  }
}

/// Delivery outcome for a single observation.
enum _UploadResult { ok, retry, fatal }

/// What the UI is allowed to claim. [note] carries the honest explanation when
/// something is not working, so no screen ever implies a live position that
/// does not exist.
@immutable
class HeartbeatStatus {
  const HeartbeatStatus({
    this.running = false,
    this.lastRecordedAt,
    this.pending = 0,
    this.note,
  });

  final bool running;
  final DateTime? lastRecordedAt;
  final int pending;
  final String? note;

  bool get hasFreshFix {
    final at = lastRecordedAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < const Duration(minutes: 45);
  }

  String get summary {
    if (note != null) return note!;
    if (!running) return 'Tracking is off.';
    final at = lastRecordedAt;
    if (at == null) return 'Waiting for the first location.';
    return 'Last recorded ${describeAge(DateTime.now().difference(at))}.';
  }
}

/// "42 minutes ago" - never rounds a stale fix into "now".
String describeAge(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inMinutes < 60) {
    return '${age.inMinutes} minute${age.inMinutes == 1 ? '' : 's'} ago';
  }
  if (age.inHours < 24) {
    return '${age.inHours} hour${age.inHours == 1 ? '' : 's'} ago';
  }
  return '${age.inDays} day${age.inDays == 1 ? '' : 's'} ago';
}
