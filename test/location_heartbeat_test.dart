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

const _sourcePath = 'lib/core/services/location_heartbeat.dart';

void main() {
  group('Heartbeat cadence contract', () {
    test('requests 30 minutes, never claims it is guaranteed', () {
      expect(LocationHeartbeat.interval, const Duration(minutes: 30));
      expect(LocationHeartbeat.interval.inMinutes, 30);
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

    test('freshness window is 45 minutes', () {
      expect(
        HeartbeatStatus(
          running: true,
          lastRecordedAt: DateTime.now().subtract(const Duration(minutes: 44)),
        ).hasFreshFix,
        isTrue,
      );
      expect(
        HeartbeatStatus(
          running: true,
          lastRecordedAt: DateTime.now().subtract(const Duration(minutes: 46)),
        ).hasFreshFix,
        isFalse,
      );
      expect(const HeartbeatStatus().hasFreshFix, isFalse);
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
