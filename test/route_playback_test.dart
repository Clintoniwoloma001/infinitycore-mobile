// Tests for the movement-delay engine.
//
// The rule under test: segment speed is Δdistance / Δtime using a haversine
// distance, classified at 1.5 m/s and 4.5 m/s, and only becomes a REVIEW FLAG
// when it is slow AND sustained for 10+ minutes AND the GPS fix is good
// enough to trust.
//
// Deliberately NOT tested as "verified traffic": low speed is correlated with
// congestion but does not prove it. A parked car produces the same trace, so
// the engine produces a flag for a human, never a verdict.

import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/attendance/route_playback.dart';
import 'package:infinitycore/features/attendance/tracking_service.dart';

/// Builds a point `dt` after `start`, `metresNorth` further north.
TrackingPoint at(
  DateTime start,
  Duration dt, {
  required double metresNorth,
  double? accuracy = 8,
  String id = '',
}) {
  // ~111,320 m per degree of latitude; ample precision for a unit test.
  const perDegree = 111320.0;
  return TrackingPoint.fromJson({
    'id': id,
    'recorded_at': start.add(dt).toIso8601String(),
    'inside_geofence': false,
    'location_label': '',
    'resolved_place': '',
    'latitude': 6.5244 + (metresNorth / perDegree),
    'longitude': 3.3792,
    'accuracy': accuracy,
  });
}

void main() {
  final base = DateTime.utc(2026, 5, 10, 8);

  group('classification thresholds', () {
    test('a stationary hold for 20 min is slow and flagged', () {
      // 20 m in 20 min ≈ 0.0167 m/s — well under 1.5.
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        at(base, const Duration(minutes: 20), metresNorth: 20, id: 'b'),
      ]);

      expect(a.segments, hasLength(1));
      expect(a.segments.single.movement, MovementClass.slow);
      expect(a.segments.single.isPlausibleTrafficHold, isTrue);
      expect(a.segments.single.isStrongFlag, isTrue);
      expect(a.flagged, hasLength(1));
    });

    test('a fast drive is free-flowing and never flagged', () {
      // ~14 m/s ≈ 50 km/h.
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        at(base, const Duration(minutes: 20), metresNorth: 16800, id: 'b'),
      ]);

      expect(a.segments.single.movement, MovementClass.freeFlowing);
      expect(a.segments.single.isPlausibleTrafficHold, isFalse);
      expect(a.flagged, isEmpty);
      expect(a.segments.single.movementLabel, 'Free-flowing movement');
    });

    test('a moderate crawl sits between the two bands', () {
      // 2.5 m/s: above slow, below free-flow.
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        at(base, const Duration(minutes: 20), metresNorth: 3000, id: 'b'),
      ]);

      expect(a.segments.single.speedMs, closeTo(2.5, 0.05));
      expect(a.segments.single.movement, MovementClass.moderate);
      expect(a.segments.single.isPlausibleTrafficHold, isFalse);
    });

    // NB: the band edges are tested with a margin rather than at exactly
    // 1.5/4.5 m/s. The test builds coordinates from a flat "metres north"
    // conversion, but the engine measures a real haversine distance on a
    // sphere, so the two disagree by ~0.6%. Sitting a value exactly on a
    // threshold would make this test assert a floating-point accident.
    test('just under the slow threshold still counts as slow', () {
      // ~1.40 m/s — 7% below 1.5, well clear of the conversion error.
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        at(base, const Duration(minutes: 20), metresNorth: 1680, id: 'b'),
      ]);
      expect(a.segments.single.speedMs, closeTo(1.4, 0.05));
      expect(a.segments.single.movement, MovementClass.slow);
    });

    test('just under the free-flow threshold stays moderate', () {
      // ~4.0 m/s — 11% below 4.5.
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        at(base, const Duration(minutes: 20), metresNorth: 4800, id: 'b'),
      ]);
      expect(a.segments.single.speedMs, closeTo(4.0, 0.1));
      expect(a.segments.single.movement, MovementClass.moderate);
    });

    test('a speed above the free-flow threshold is free-flowing', () {
      // ~8 m/s.
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        at(base, const Duration(minutes: 20), metresNorth: 9600, id: 'b'),
      ]);
      expect(a.segments.single.speedMs, closeTo(8.0, 0.2));
      expect(a.segments.single.movement, MovementClass.freeFlowing);
    });
  });

  group('sustained-duration gate', () {
    test('a slow segment under 10 min is NOT flagged', () {
      // 0.5 m/s but only 5 minutes.
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        at(base, const Duration(minutes: 5), metresNorth: 150, id: 'b'),
      ]);

      expect(a.segments.single.movement, MovementClass.slow);
      expect(a.segments.single.isPlausibleTrafficHold, isFalse,
          reason: 'under the 10-minute hold threshold');
      expect(a.flagged, isEmpty);
    });
  });

  group('GPS-quality gate', () {
    test('a slow hold on a poor fix is not a strong flag', () {
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, accuracy: 250, id: 'a'),
        at(base, const Duration(minutes: 20), metresNorth: 20, accuracy: 250,
            id: 'b'),
      ]);

      final seg = a.segments.single;
      expect(seg.isPlausibleTrafficHold, isTrue,
          reason: 'the geometry still says slow-and-held');
      expect(seg.hasReliableFix, isFalse);
      expect(seg.isStrongFlag, isFalse,
          reason: 'a ±250 m fix cannot prove the vehicle did not drift');
      expect(a.flagged, isEmpty);
    });

    test('a missing accuracy is treated as reliable, not as a failure', () {
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, accuracy: null, id: 'a'),
        at(base, const Duration(minutes: 20), metresNorth: 20,
            accuracy: null, id: 'b'),
      ]);
      expect(a.segments.single.hasReliableFix, isTrue);
    });
  });

  group('degenerate input', () {
    test('two pings at the same instant yield no segment, not Infinity', () {
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        at(base, Duration.zero, metresNorth: 500, id: 'b'),
      ]);

      expect(a.segments, isEmpty);
      expect(a.zeroDurationSegments, 1);
    });

    test('a single point produces an empty analysis, not a crash', () {
      final a = RouteAnalysis.build([at(base, Duration.zero, metresNorth: 0)]);
      expect(a.isEmpty, isTrue);
      expect(a.pointsUsed, 1);
      expect(a.totalDistanceMeters, 0);
    });

    test('empty input is handled', () {
      final a = RouteAnalysis.build([]);
      expect(a.isEmpty, isTrue);
      expect(a.elapsed, Duration.zero);
      expect(a.flaggedTimeShare, 0);
    });

    test('out-of-order pings are sorted before the maths runs', () {
      final a = RouteAnalysis.build([
        at(base, const Duration(minutes: 20), metresNorth: 20, id: 'late'),
        at(base, Duration.zero, metresNorth: 0, id: 'early'),
      ]);

      expect(a.segments, hasLength(1));
      expect(a.segments.single.speedMs, greaterThan(0),
          reason: 'a negative duration would have produced a negative speed');
    });

    test('points without coordinates are skipped and counted', () {
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        TrackingPoint.fromJson({
          'id': 'nocoord',
          'recorded_at':
              base.add(const Duration(minutes: 10)).toIso8601String(),
        }),
        at(base, const Duration(minutes: 20), metresNorth: 20, id: 'b'),
      ]);

      expect(a.pointsSkipped, 1);
      expect(a.pointsUsed, 2);
    });
  });

  group('summary maths', () {
    test('flagged time share is bounded and reflects the hold', () {
      final a = RouteAnalysis.build([
        at(base, Duration.zero, metresNorth: 0, id: 'a'),
        at(base, const Duration(minutes: 30), metresNorth: 20, id: 'b'),
      ]);

      expect(a.flaggedTimeShare, closeTo(1.0, 0.001));
      expect(a.elapsed, const Duration(minutes: 30));
    });
  });

  group('copy', () {
    test('minutesLabel reads naturally', () {
      expect(minutesLabel(const Duration(minutes: 42)), '42 min');
      expect(minutesLabel(const Duration(hours: 1)), '1 h');
      expect(minutesLabel(const Duration(hours: 1, minutes: 5)), '1 h 5 min');
    });
  });
}
