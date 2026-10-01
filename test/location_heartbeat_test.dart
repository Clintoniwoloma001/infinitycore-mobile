// ============================================================================
// Phase 70 mobile - background location heartbeat
// ============================================================================
// Pure/unit tests only. No Supabase session, no geolocation, no network.
//
// What is under test here is the HONESTY contract of the heartbeat rather than
// the GPS call itself: the promised cadence, the staleness ceiling, the offline
// queue bound, and the fact that the UI can only ever say what actually
// happened ("last recorded 42 minutes ago", never a fabricated live position).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/core/services/location_heartbeat.dart';
import 'package:infinitycore/core/services/permission_service.dart';

const _sourcePath = 'lib/core/services/location_heartbeat.dart';
const _permissionPath = 'lib/core/services/permission_service.dart';

void main() {
  group('Heartbeat cadence contract', () {
    test('requests 2 minutes, never claims it is guaranteed', () {
      // 2 minutes is the requested cadence. It is a REQUEST: Android throttles
      // background work and iOS may delay updates, so the service records the
      // real timestamp of every fix and never back-fills a missed one.
      expect(LocationHeartbeat.interval, const Duration(minutes: 2));
      expect(LocationHeartbeat.interval.inMinutes, 2);
    });

    test('refuses to record a fix older than 5 minutes', () {
      // A stale fix would misrepresent where the person is. Anything older
      // than the ceiling is dropped rather than uploaded.
      expect(LocationHeartbeat.maxFixAge, const Duration(minutes: 5));
      expect(const Duration(minutes: 6) > LocationHeartbeat.maxFixAge, isTrue);
      expect(
        const Duration(seconds: 30) > LocationHeartbeat.maxFixAge,
        isFalse,
      );
    });

    test('offline queue is bounded so it cannot grow forever', () {
      expect(LocationHeartbeat.maxQueue, 500);
    });
  });

  group('Consent copy', () {
    test('purpose is stated before any permission prompt', () {
      final message = LocationHeartbeat.purposeMessage;
      expect(message, isNotEmpty);
      // The employee must be told the scope and how it starts.
      expect(message.toLowerCase(), contains('location'));
      expect(message.toLowerCase(), contains('starts automatically'));
      // The Profile toggle is gone, so the copy must point at the control that
      // actually exists (the OS permission) rather than an in-app switch that
      // no longer renders anywhere.
      expect(message.toLowerCase(), contains('permission'));
      expect(message.toLowerCase(), isNot(contains('turn it off in settings')));
    });

    test('declining leaves attendance untouched', () {
      // Tracking is separate from clocking in/out, so the copy must not imply
      // that declining costs the employee anything.
      expect(
        LocationHeartbeat.purposeMessage.toLowerCase(),
        contains('clocking in and out works either way'),
      );
    });
  });

  group('Status reporting (never invents a position)', () {
    test('idle state says tracking is off', () {
      const status = HeartbeatStatus();
      expect(status.running, isFalse);
      expect(status.summary, 'Tracking is off.');
    });

    test('running with no observation says so', () {
      const status = HeartbeatStatus(running: true);
      expect(status.summary, 'Waiting for the first location.');
    });

    test('reports the real age of the last observation', () {
      final status = HeartbeatStatus(
        running: true,
        lastRecordedAt: DateTime.now().subtract(const Duration(minutes: 42)),
      );
      expect(status.summary, 'Last recorded 42 minutes ago.');
      // 42 minutes must not round down into a comforting "now".
      expect(status.summary, isNot(contains('just now')));
    });

    test('an explanatory note always wins over the cadence line', () {
      const status = HeartbeatStatus(
        running: true,
        note: 'No connection. The observation is saved and will be sent.',
      );
      expect(status.summary, contains('No connection'));
    });

    test('freshness window tracks the 2-minute cadence', () {
      // Tightened from 45 minutes. With points arriving every 2 minutes, a
      // 45-minute window would happily label a position from three quarters of
      // an hour ago as "fresh" — i.e. as live. A couple of missed windows on a
      // throttled OS is normal, so the window allows for that and no more.
      expect(
        HeartbeatStatus(
          running: true,
          lastRecordedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ).hasFreshFix,
        isTrue,
      );
      expect(
        HeartbeatStatus(
          running: true,
          lastRecordedAt: DateTime.now().subtract(const Duration(minutes: 7)),
        ).hasFreshFix,
        isFalse,
      );
      expect(const HeartbeatStatus().hasFreshFix, isFalse);
    });

    test('a queued observation survives and is retried without a live capture', () {
      // The offline contract: nothing is discarded, and a drain is safe to call
      // when the queue is empty, while signed out, or twice in a row.
      final source = File(_sourcePath).readAsStringSync();

      expect(source, contains('syncPending'));
      expect(source, contains('startSyncWatchdog'));
      // A failed drain must leave the queue alone.
      expect(source, contains('Queue untouched; retried on the next tick.'));
      // Entries captured for a different account are still dropped.
      expect(source, contains('Belongs to another account'));
    });
  });

  group('Effective permission precedence (must match web + database)', () {
    test('super admin is allowed everything', () {
      const perms = EffectivePermissions(isSuperUser: true, loaded: true);
      expect(perms.has('hr.payroll.read'), isTrue);
      expect(perms.has('anything.at.all'), isTrue);
    });

    test('an explicit DENY beats an explicit ALLOW', () {
      // This is the documented precedence, and the single most important case:
      // a revoked permission must survive a role that would otherwise grant it.
      const perms = EffectivePermissions(
        allowed: {'hr.payroll.read'},
        denied: {'hr.payroll.read'},
        loaded: true,
      );
      expect(perms.has('hr.payroll.read'), isFalse);
    });

    test('an unknown key is denied, not allowed', () {
      const perms = EffectivePermissions(allowed: {'a'}, loaded: true);
      expect(perms.has('b'), isFalse);
    });

    test('fails closed while nothing is loaded', () {
      // A permission that has not been fetched must not read as granted —
      // otherwise a cold start briefly shows restricted menu items.
      const perms = EffectivePermissions();
      expect(perms.loaded, isFalse);
      expect(perms.has('hr.employees.read'), isFalse);
    });

    test('hasAny / hasAll / visibleFrom follow the same rule', () {
      const perms = EffectivePermissions(
        allowed: {'employees.read', 'leave.read'},
        denied: {'leave.read'},
        loaded: true,
      );
      expect(perms.hasAny(['payroll.read', 'employees.read']), isTrue);
      expect(perms.hasAll(['employees.read', 'leave.read']), isFalse);
      expect(perms.hasAll(['employees.read']), isTrue);
      expect(
        perms.visibleFrom(['employees.read', 'leave.read', 'payroll.read']),
        {'employees.read'},
      );
    });
  });

  group('Cross-platform consistency', () {
    test('the service reads the backend document, not a local role matrix', () {
      final source = File(_permissionPath).readAsStringSync();

      // It must ask the same RPC the web and the backend use.
      expect(source, contains('get_my_permissions'));
      // And must NOT re-derive access from a hard-coded role table.
      expect(source, isNot(contains('ROLE_PERMISSIONS')));
      expect(source, isNot(contains('ROLE_MODULES')));
    });

    test('a grant reaches the device without a re-login', () {
      final source = File(_permissionPath).readAsStringSync();
      expect(source, contains('onPostgresChanges'));
      for (final table in ['user_permissions', 'role_permissions']) {
        expect(source, contains(table));
      }
      // Foreground return is the other moment a permission can have changed.
      expect(source, contains('AppLifecycleState.resumed'));
      // Nothing is cached on disk, so a relaunch cannot resurrect a stale grant.
      expect(source, isNot(contains('FlutterSecureStorage')));
    });

    test('signing out clears every permission immediately', () {
      final source = File(_permissionPath).readAsStringSync();
      expect(source, contains('stopRealtime()'));
      expect(
        source,
        contains('no permission outlives the session'),
      );
    });
  });

  group('Age formatting', () {
    test('scales from just-now to days', () {
      expect(describeAge(const Duration(seconds: 30)), 'just now');
      expect(describeAge(const Duration(minutes: 1)), '1 minute ago');
      expect(describeAge(const Duration(minutes: 59)), '59 minutes ago');
      expect(describeAge(const Duration(hours: 1)), '1 hour ago');
      expect(describeAge(const Duration(hours: 5)), '5 hours ago');
      expect(describeAge(const Duration(hours: 24)), '1 day ago');
      expect(describeAge(const Duration(days: 3)), '3 days ago');
    });

    test('pluralises correctly', () {
      expect(
        describeAge(const Duration(minutes: 1)),
        isNot(contains('minutes')),
      );
      expect(describeAge(const Duration(minutes: 2)), contains('2 minutes'));
      expect(describeAge(const Duration(hours: 1)), isNot(contains('hours')));
    });
  });

  _sourceGuards();
}

/// Reading the implementation guards the properties a unit test cannot reach
/// without a real GPS and a real session.
void _sourceGuards() {
  final source = File(_sourcePath).readAsStringSync();

  group('Source-level honesty guards', () {
    test('recorded_at comes from the fix, not from the upload time', () {
      // The server keeps recorded_at (seen) and uploaded_at (arrived)
      // separate. Stamping the upload time would silently rewrite history.
      expect(source, contains("'recorded_at': position.timestamp"));
      expect(source, isNot(contains("'recorded_at': now")));
    });

    test('queued observations are retried, not dropped', () {
      expect(source, contains('_flushQueue'));
      expect(source, contains('maxQueue'));
    });

    test('a permanently rejected upload stops instead of queueing forever', () {
      // NO_EMPLOYEE_PROFILE can never succeed, so it must not be re-sent.
      expect(source, contains('NO_EMPLOYEE_PROFILE'));
      expect(source, contains('_UploadResult.fatal'));
    });

    test('tracking is only ever run for an authenticated session', () {
      // The session check now lives in the service that decides whether to run,
      // not in the capture engine.
      final service = File('lib/core/services/location_tracking_service.dart')
          .readAsStringSync();
      expect(service, contains('currentSession'));
      expect(service, contains('isAuthenticated'));
    });

    test('the tracking service owns start and stop, not a screen', () {
      // The Profile card and its consent sheet are gone. Exactly one place may
      // decide whether tracking runs, and it is a service - not a widget that
      // the employee has to find and press.
      expect(
        File('lib/features/profile/location_tracking_sheet.dart').existsSync(),
        isFalse,
        reason: 'the manual toggle sheet must not come back',
      );
      final service = File('lib/core/services/location_tracking_service.dart')
          .readAsStringSync();
      expect(service, contains('startAutomatic'));
      expect(service, contains('startLocalOnly'));
      expect(service, contains('LocationHeartbeat.instance.stop()'));

      // The Profile screen must not reach into location at all any more.
      final profile = File('lib/features/profile/profile_screen.dart')
          .readAsStringSync();
      expect(profile, isNot(contains('Location tracking')));
      expect(profile, isNot(contains('Review & enable')));
      expect(profile, isNot(contains('LocationHeartbeat')));
    });

    test('auto-start never raises a permission prompt', () {
      // Starting from a background launch must not ambush the employee with a
      // system dialog, or nag for one they already refused.
      final service = File('lib/core/services/location_tracking_service.dart')
          .readAsStringSync();
      expect(service, contains('Geolocator.checkPermission()'));
      expect(service, isNot(contains('Geolocator.requestPermission()')));
    });

    test('one employee can never inherit another\'s queued positions', () {
      // Points captured while signed out are tagged and only released to the
      // same account; rebinding discards the previous account's queue.
      final heartbeat = File('lib/core/services/location_heartbeat.dart')
          .readAsStringSync();
      expect(heartbeat, contains('captured_for'));
      expect(heartbeat, contains('rebindTo'));
      expect(heartbeat, contains('Belongs to another account'));
    });
  });
}
