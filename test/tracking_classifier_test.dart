import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/features/attendance/tracking_classifier.dart';

/// The classifier is the ONE place the mobile app decides which Live-positions
/// bucket a row belongs to, so every boundary below is pinned.
///
/// Must match web SARA Live positions logic: a 48 h window (inclusive at the
/// boundary, because the RPC's filter is `recorded_at >= now() - interval
/// '48 h'`), a 30-minute stale threshold that OVERRIDES the inside/outside
/// verdict, and a no-geofence case that outranks freshness.
void main() {
  final now = DateTime.utc(2026, 10, 13, 12, 0, 0);

  Map<String, dynamic> row({
    int? ageMinutes,
    String? displayCategory,
    String geofenceStatus = 'inside',
    bool? insideGeofence,
    int? ageSeconds,
    DateTime? recordedAt,
    bool hasFence = true,
  }) {
    final j = <String, dynamic>{
      'employee_id': 'e1',
      'full_name': 'Ada Lovelace',
      'inside_geofence': insideGeofence ?? (geofenceStatus == 'inside'),
    };
    if (ageMinutes != null) j['minutes_ago'] = ageMinutes;
    if (ageSeconds != null) j['age_seconds'] = ageSeconds;
    if (recordedAt != null) {
      j['recorded_at'] = recordedAt.toUtc().toIso8601String();
    }
    if (displayCategory != null) j['display_category'] = displayCategory;
    if (geofenceStatus.isNotEmpty) j['geofence_status'] = geofenceStatus;
    // A live v4 row names the fence it matched; only the deliberate
    // no-geofence cases omit it.
    if (hasFence) {
      j['geofence_id'] = 'f1';
      j['geofence_name'] = 'Head Office';
    }
    return j;
  }

  group('the 48 h window', () {
    test('47 h is inside the window', () {
      expect(
        classifyTrackingEntry(row(ageMinutes: 47 * 60), now: now),
        isNotNull,
      );
    });

    test('exactly 48 h is inside the window (the RPC uses >=)', () {
      final at = now.subtract(const Duration(hours: 48));
      expect(
        classifyTrackingEntry(
          row(recordedAt: at, geofenceStatus: ''),
          now: now,
        ),
        isNotNull,
        reason: 'a fix exactly 48 h old is still returned by the RPC',
      );
    });

    test('49 h is outside the window and is not listed', () {
      expect(
        classifyTrackingEntry(row(ageMinutes: 49 * 60), now: now),
        isNull,
      );
    });

    test('a row with no fix at all is never listed', () {
      expect(
        classifyTrackingEntry(<String, dynamic>{'employee_id': 'e2'}, now: now),
        isNull,
      );
    });
  });

  group('the four buckets', () {
    test('fresh + inside', () {
      expect(
        classifyTrackingEntry(
          row(ageMinutes: 4, displayCategory: 'inside'),
          now: now,
        ),
        TrackingBucket.inside,
      );
    });

    test('fresh + outside', () {
      expect(
        classifyTrackingEntry(
          row(
            ageMinutes: 4,
            displayCategory: 'outside',
            geofenceStatus: 'outside',
          ),
          now: now,
        ),
        TrackingBucket.outside,
      );
    });

    test('stale overrides inside and outside', () {
      expect(
        classifyTrackingEntry(
          row(ageMinutes: 45, displayCategory: 'inside'),
          now: now,
        ),
        TrackingBucket.stale,
      );
      expect(
        classifyTrackingEntry(
          row(ageMinutes: 45, displayCategory: 'outside'),
          now: now,
        ),
        TrackingBucket.stale,
      );
    });

    test('the stale threshold is 30 minutes inclusive', () {
      expect(
        classifyTrackingEntry(
          row(ageMinutes: 30, displayCategory: 'inside'),
          now: now,
        ),
        TrackingBucket.inside,
        reason: 'at or under 30 min the verdict still shows (web DELAYED)',
      );
      expect(
        classifyTrackingEntry(
          row(ageMinutes: 31, displayCategory: 'inside'),
          now: now,
        ),
        TrackingBucket.stale,
      );
    });

    test('no geofence configured outranks the verdict', () {
      expect(
        classifyTrackingEntry(
          row(ageMinutes: 4, displayCategory: 'unconfigured'),
          now: now,
        ),
        TrackingBucket.noGeofence,
      );
    });

    test('the server category wins over a client-derived one', () {
      // The server says stale while the row also carries an inside flag: the
      // server's answer is the only one that counts.
      expect(
        classifyTrackingEntry(
          row(
            ageMinutes: 90,
            displayCategory: 'stale',
            insideGeofence: true,
          ),
          now: now,
        ),
        TrackingBucket.stale,
      );
    });
  });

  group('derived buckets when the server sent no display_category', () {
    test('inside flag', () {
      expect(
        classifyTrackingEntry(row(ageMinutes: 5), now: now),
        TrackingBucket.inside,
      );
    });

    test('outside flag', () {
      expect(
        classifyTrackingEntry(
          row(ageMinutes: 5, geofenceStatus: 'outside'),
          now: now,
        ),
        TrackingBucket.outside,
      );
    });

    test('no fence answer at all is NoGeofence', () {
      expect(
        classifyTrackingEntry(
          row(ageMinutes: 5, geofenceStatus: '', hasFence: false),
          now: now,
        ),
        TrackingBucket.noGeofence,
      );
    });
  });

  group('the counts sum to the total', () {
    test('inside + outside + stale + no geofence === rows listed', () {
      final rows = <Map<String, dynamic>>[
        row(ageMinutes: 4, displayCategory: 'inside'),
        row(ageMinutes: 5, displayCategory: 'inside'),
        row(
          ageMinutes: 20,
          displayCategory: 'outside',
          geofenceStatus: 'outside',
        ),
        row(ageMinutes: 33, displayCategory: 'stale'),
        row(ageMinutes: 600, displayCategory: 'stale'),
        row(ageMinutes: 3, displayCategory: 'unconfigured'),
        // Outside the window: listed by nobody.
        row(ageMinutes: 49 * 60, displayCategory: 'inside'),
      ];
      final listed =
          rows.where((r) => classifyTrackingEntry(r, now: now) != null).toList();
      final counts = countTrackingBuckets(
        listed.map((r) => classifyTrackingEntry(r, now: now)),
      );
      final total = counts.values.fold(0, (a, b) => a + b);
      expect(listed.length, 6);
      expect(total, listed.length, reason: 'the sum invariant must hold');
      expect(counts[TrackingBucket.inside], 2);
      expect(counts[TrackingBucket.outside], 1);
      expect(counts[TrackingBucket.stale], 2);
      expect(counts[TrackingBucket.noGeofence], 1);
    });
  });

  group('indicators', () {
    test('delayed is fresh enough to show a verdict but older than 6 min', () {
      expect(
        isTrackingDelayed(row(ageMinutes: 4), now: now),
        isFalse,
      );
      expect(
        isTrackingDelayed(row(ageMinutes: 12), now: now),
        isTrue,
      );
      expect(
        isTrackingDelayed(row(ageMinutes: 45), now: now),
        isFalse,
        reason: 'stale is not merely delayed',
      );
    });

    test('low GPS accuracy is accuracy beyond the fence radius', () {
      expect(
        isLowAccuracyFix(<String, dynamic>{
          'accuracy_m': 120,
          'radius_m': 50,
        }),
        isTrue,
      );
      expect(
        isLowAccuracyFix(<String, dynamic>{
          'accuracy_m': 10,
          'radius_m': 50,
        }),
        isFalse,
      );
    });
  });
}
