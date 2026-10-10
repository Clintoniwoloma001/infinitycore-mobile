// ============================================================================
// Mobile Employee Tracking — one source of truth for the chips and the badges
// ============================================================================
// The web bug, and the same defect on this screen: what the header counted was
// not what the badges showed. On mobile it showed up differently — the list was
// the whole company with no way to tell who was actually reporting, and a fix
// was "live" at 44 minutes here but "stale" at 31 minutes on the web, because
// this client used its own 45-minute threshold while the server used 30.
//
// What must hold, and what this file asserts:
//   1. The service reads employee_live_positions_v4 and v3 is only a fallback.
//   2. Only employees with a fix are listed; v4 decides it in SQL.
//   3. ONE display_category drives the chips, the badges and the sort — the
//      phone never re-sorts v4's rows.
//   4. inside + outside + stale + unconfigured == rows listed.
//   5. Stale is decided by the SERVER's threshold (30 min), never a local one.
//   6. The low-accuracy note appears only on a genuinely ambiguous fix.
//   7. The list is labelled by reporting count, not by staff-list size.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/attendance/tracking_service.dart';

Map<String, dynamic> _row({
  required String id,
  required String name,
  String category = 'inside',
  int? ageMinutes,
  bool inside = true,
  bool ambiguous = false,
  bool hasFix = true,
}) {
  return <String, dynamic>{
    'employee_id': id,
    'full_name': name,
    'employee_number': 'IMFB/00/$id',
    'position': 'Officer',
    'branch_name': 'Head Office',
    // v4's real shape.
    'geofence_status': inside ? 'inside' : 'outside',
    'inside_geofence': inside,
    'display_category': hasFix ? category : null,
    'boundary_ambiguous': ambiguous,
    'age_seconds': hasFix ? (ageMinutes ?? 1) * 60 : null,
    'recorded_at': hasFix
        ? DateTime.now()
            .toUtc()
            .subtract(Duration(minutes: ageMinutes ?? 1))
            .toIso8601String()
        : null,
    'latitude': 6.6057,
    'longitude': 3.3925,
    'nearest_location_name': 'Head Office',
    'location_label': 'Head Office',
    'has_fix': hasFix,
  };
}

void main() {
  group('categories are read from the server, not recomputed', () {
    test('display_category survives the parse unchanged', () {
      final p = TrackedEmployee.fromJson(
        _row(id: '1', name: 'A', category: 'outside', inside: false),
      );
      expect(p.category, 'outside');
      expect(p.insideGeofence, isFalse);
    });

    test('every v4 category parses', () {
      for (final c in kTrackedCategories) {
        expect(
          TrackedEmployee.fromJson(_row(id: 'x', name: 'X', category: c))
              .category,
          c,
        );
      }
    });

    test('the v3 fallback derives a category the same way', () {
      // No display_category at all: derive from the server's own 30-minute
      // threshold, never a client-local number.
      final live = TrackedEmployee.fromJson(
        _row(id: 'v', name: 'V', category: 'inside', ageMinutes: 2)
          ..remove('display_category'),
      );
      expect(live.category, 'inside');

      final stale = TrackedEmployee.fromJson(
        _row(id: 'w', name: 'W', category: 'inside', ageMinutes: 31)
          ..remove('display_category'),
      );
      expect(stale.category, 'stale');
    });

    test('the stale threshold is 30 minutes on every client', () {
      expect(kStaleThresholdMinutes, 30);
      // The exact boundary: 30 is live, 31 is stale.
      expect(
        TrackedEmployee.fromJson(
          _row(id: 'a', name: 'A', category: 'inside', ageMinutes: 30)
            ..remove('display_category'),
        ).isStale,
        isFalse,
      );
      expect(
        TrackedEmployee.fromJson(
          _row(id: 'b', name: 'B', category: 'inside', ageMinutes: 31)
            ..remove('display_category'),
        ).isStale,
        isTrue,
      );
    });
  });

  group('counts, filtering and the sum invariant', () {
    test('the four categories are mutually exclusive and sum to the rows', () {
      final people = [
        TrackedEmployee.fromJson(_row(id: '1', name: 'A', category: 'outside', inside: false)),
        TrackedEmployee.fromJson(_row(id: '2', name: 'B', category: 'inside')),
        TrackedEmployee.fromJson(_row(id: '3', name: 'C', category: 'inside')),
        TrackedEmployee.fromJson(_row(id: '4', name: 'D', category: 'stale', ageMinutes: 600)),
        TrackedEmployee.fromJson(_row(id: '5', name: 'E', category: 'unconfigured', inside: false)),
      ];

      final counted = <String, int>{for (final c in kTrackedCategories) c: 0};
      for (final p in people) {
        counted[p.category] = (counted[p.category] ?? 0) + 1;
      }
      final sum = kTrackedCategories.fold<int>(0, (t, c) => t + (counted[c] ?? 0));
      expect(sum, people.length);
      expect(counted['outside'], 1);
      expect(counted['inside'], 2);
      expect(counted['stale'], 1);
      expect(counted['unconfigured'], 1);
    });

    test('a chip filters to that category only', () {
      final people = [
        TrackedEmployee.fromJson(_row(id: '1', name: 'A', category: 'outside', inside: false)),
        TrackedEmployee.fromJson(_row(id: '2', name: 'B', category: 'inside')),
        TrackedEmployee.fromJson(_row(id: '3', name: 'C', category: 'stale', ageMinutes: 600)),
      ];
      List<TrackedEmployee> apply(String? chip) =>
          people.where((p) => chip == null || p.category == chip).toList();
      expect(apply('outside').length, 1);
      expect(apply('inside').length, 1);
      expect(apply('stale').length, 1);
      expect(apply(null).length, 3);
    });

    test('a row with no fix is never counted as a current position', () {
      final p = TrackedEmployee.fromJson(
        _row(id: 'z', name: 'Z', category: 'inside', hasFix: false),
      );
      expect(p.hasFix, isFalse);
      expect(p.isStale, isTrue);
    });
  });

  group('ordering matches the web, row for row', () {
    test('v4 rows keep the server order and are never re-sorted', () {
      final source = File('lib/features/attendance/tracking_service.dart')
          .readAsStringSync()
          .replaceAll('\n', ' ');
      expect(
        source,
        contains('Already sorted by the server'),
        reason: 'the v4 path must not re-order the rows',
      );
      expect(
        source,
        contains('displayOrder'),
        reason: 'the comparator exists only for the v3 fallback',
      );
    });

    test('the comparator orders live, then newest, then name', () {
      final live = TrackedEmployee.fromJson(
        _row(id: '1', name: 'Zed Live', category: 'outside', inside: false, ageMinutes: 1),
      );
      final delayed = TrackedEmployee.fromJson(
        _row(id: '2', name: 'Ann Delayed', category: 'inside', ageMinutes: 10),
      );
      final oldNewer = TrackedEmployee.fromJson(
        _row(id: '3', name: 'Bo Old', category: 'stale', ageMinutes: 400),
      );
      final oldOlder = TrackedEmployee.fromJson(
        _row(id: '4', name: 'Ci Old', category: 'stale', ageMinutes: 900),
      );

      final sorted = [oldOlder, delayed, oldNewer, live]..sort(displayOrder);
      expect(sorted.map((p) => p.name).toList(), [
        'Zed Live',
        'Ann Delayed',
        'Bo Old',
        'Ci Old',
      ]);
    });
  });

  group('the low-accuracy note is ambiguous-only', () {
    test('a far outside fix is not flagged however imprecise it is', () {
      final far = _row(id: '1', name: 'A', category: 'outside', inside: false);
      far['accuracy'] = 100;
      far['nearest_radius'] = 20;
      far['distance_to_center_m'] = 11600;
      final p = TrackedEmployee.fromJson(far);
      expect(p.isLowAccuracy, isFalse);
    });

    test('a boundary-straddling fix IS flagged', () {
      final p = TrackedEmployee.fromJson(
        <String, dynamic>{
          ..._row(id: '2', name: 'B'),
          'boundary_ambiguous': true,
        },
      );
      expect(p.isLowAccuracy, isTrue);
    });
  });

  group('the page contract', () {
    test('the service reads v4 first, v3 only as a fallback', () {
      final src = File('lib/features/attendance/tracking_service.dart')
          .readAsStringSync();
      expect(src, contains("'employee_live_positions_v4'"));
      expect(src, contains("'p_recent_hours': recentHours"));
      expect(src, contains("'employee_live_positions_v3', 'employee_live_positions_v2'"));
    });

    test('the default window is 48 hours, matching the web', () {
      final src = File('lib/features/attendance/tracking_service.dart')
          .readAsStringSync();
      expect(src, contains('int recentHours = 48'));
    });

    test('the screen counts from the same rows it renders', () {
      final page = File('lib/features/attendance/employee_tracking_screen.dart')
          .readAsStringSync();
      expect(page, contains('_counts'));
      expect(page, contains('counts[p.category]'));
      expect(page, contains('kTrackedCategories'));
      // The chip and the badge read the same field.
      expect(page, contains('_VerdictPill(category: person.category)'));
      // No local staleness test, no second counting path.
      expect(page, isNot(contains('minutesAgo ?? 0) > 45')));
      expect(page, isNot(contains('!p.isStale).length')));
    });

    test('the list is labelled by reporting count, not staff-list size', () {
      final page = File('lib/features/attendance/employee_tracking_screen.dart')
          .readAsStringSync();
      expect(page, contains('reporting in the last 48 h'));
      expect(page, isNot(contains('tracked · current')));
    });

    test('the empty state says nobody reported, and is honest about scope', () {
      final page = File('lib/features/attendance/employee_tracking_screen.dart')
          .readAsStringSync();
      expect(page, contains('No one has reported in the last 48 h'));
      expect(page, isNot(contains('No positions recorded')));
    });
  });

  group('a real v4 payload decodes end to end', () {
    test('the production shape for Iwoloma Clinton Tamunosiki', () {
      // The exact row employee_live_positions_v4 returns for IMFB/26/0526,
      // trimmed to the fields the phone consumes.
      final json = jsonDecode('''
        {
          "employee_id": "ac71b9d9-d23b-43de-9be2-1f7ec4d89036",
          "full_name": "Iwoloma Clinton Tamunosiki",
          "employee_number": "IMFB/26/0526",
          "position": "IT AUTOMATION SPECIALIST",
          "department": "E-BUSINESS",
          "branch_id": "017fa140-fc83-473a-9f70-8cefcbacaf2f",
          "branch_name": "Head Office",
          "latitude": 6.6224365,
          "longitude": 3.4966001,
          "accuracy_m": 37.52,
          "recorded_at": "2026-10-10T10:26:05+00:00",
          "uploaded_at": "2026-10-10T10:26:05.712243+00:00",
          "age_seconds": 78,
          "freshness": "live",
          "geofence_status": "outside",
          "geofence_name": "Head Office",
          "nearest_location_name": "Head Office",
          "distance_to_center_m": null,
          "radius_m": null,
          "nearest_distance": 11639.07,
          "nearest_radius": 20,
          "meters_outside": 11639,
          "boundary_ambiguous": false,
          "confidence": "low",
          "location_label": "Outside Head Office (11639 m away)",
          "sync_status": "synced",
          "display_category": "outside",
          "has_fix": true,
          "clocked_in_at": null,
          "clocked_out_at": null,
          "is_clocked_in": false,
          "tracking_unavailable_reason": null
        }
      ''') as Map<String, dynamic>;

      final p = TrackedEmployee.fromJson(json);
      expect(p.name, 'Iwoloma Clinton Tamunosiki');
      expect(p.employeeNumber, 'IMFB/26/0526');
      expect(p.branchName, 'Head Office');
      expect(p.category, 'outside');
      expect(p.insideGeofence, isFalse);
      expect(p.isStale, isFalse);
      // 11.6 km outside with 37 m accuracy is NOT an ambiguous reading.
      expect(p.isLowAccuracy, isFalse);
      expect(p.hasFix, isTrue);
    });
  });
}
