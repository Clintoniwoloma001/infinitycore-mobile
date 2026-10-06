// Tests for the map-facing half of the tracking model: coordinate validation,
// chronological ordering, and the evidence-quality note.
//
// The rule under test: a point is only drawn when it carries a REAL, in-range
// coordinate. Coercing a missing fix to 0,0 would silently drop a breadcrumb in
// the Gulf of Guinea and quietly corrupt the whole rendered route, so the
// guard is deliberately strict and these tests pin it.

import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/attendance/tracking_service.dart';

TrackingPoint p({
  String id = 'x',
  String? at,
  double? lat,
  double? lon,
  double? accuracy,
  int? battery,
  String network = '',
  bool inside = false,
}) {
  return TrackingPoint.fromJson({
    'id': id,
    'recorded_at': at,
    'inside_geofence': inside,
    'location_label': 'HQ',
    'resolved_place': '',
    'latitude': lat,
    'longitude': lon,
    'accuracy': accuracy,
    'battery_level': battery,
    'network_type': network,
  });
}

void main() {
  group('coordinate validation', () {
    test('a normal fix is drawable', () {
      expect(p(lat: 6.5244, lon: 3.3792).hasCoordinates, isTrue);
    });

    test('a missing fix is NOT drawable', () {
      expect(p().hasCoordinates, isFalse);
      expect(p(lat: 6.5244).hasCoordinates, isFalse);
      expect(p(lon: 3.3792).hasCoordinates, isFalse);
    });

    test('Null Island is rejected — it means "GPS never initialised"', () {
      expect(p(lat: 0, lon: 0).hasCoordinates, isFalse);
    });

    test('out-of-range coordinates are rejected', () {
      expect(p(lat: 91, lon: 3.3792).hasCoordinates, isFalse);
      expect(p(lat: 6.5244, lon: 181).hasCoordinates, isFalse);
    });
  });

  group('TrackingDay.mappablePoints', () {
    test('returns only drawable points, in chronological order', () {
      final day = TrackingDay.fromJson({
        'timezone': 'Africa/Lagos',
        'points': [
          {'id': 'late', 'recorded_at': '2026-05-10T14:00:00Z',
           'latitude': 6.60, 'longitude': 3.40},
          {'id': 'early', 'recorded_at': '2026-05-10T08:00:00Z',
           'latitude': 6.52, 'longitude': 3.37},
          {'id': 'broken', 'recorded_at': '2026-05-10T10:00:00Z',
           'latitude': null, 'longitude': null},
        ],
      });

      final ids = day.mappablePoints.map((e) => e.id).toList();
      expect(ids, ['early', 'late']);
      expect(day.unplaceableCount, 1);
    });

    test('a point with no timestamp sorts last instead of jumping to the front', () {
      final day = TrackingDay.fromJson({
        'timezone': 'Africa/Lagos',
        'points': [
          {'id': 'undated', 'latitude': 6.52, 'longitude': 3.37},
          {'id': 'dated', 'recorded_at': '2026-05-10T08:00:00Z',
           'latitude': 6.60, 'longitude': 3.40},
        ],
      });

      expect(day.mappablePoints.map((e) => e.id).toList(), ['dated', 'undated']);
    });

    test('an empty day is handled without throwing', () {
      final day = TrackingDay.fromJson({'timezone': 'Africa/Lagos', 'points': []});
      expect(day.isEmpty, isTrue);
      expect(day.mappablePoints, isEmpty);
      expect(day.unplaceableCount, 0);
    });
  });

  group('evidence quality', () {
    test('a healthy fix reports no caveat', () {
      expect(p(battery: 82, network: '5g').evidenceNote, isNull);
    });

    test('a low-battery fix is flagged as weak evidence', () {
      expect(p(battery: 9).evidenceNote, contains('low battery (9%)'));
    });

    test('a normal battery is not flagged', () {
      expect(p(battery: 40).evidenceNote, isNull);
    });
  });
}
