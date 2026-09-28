// ============================================================================
// Automation Command Centre — payload parsing
// ============================================================================
// The shapes below are transcribed from a real `get_automation_portfolio()`
// response taken from the live backend, not invented. The point of these tests
// is that mobile must not silently disagree with web about how a department's
// completion is reported.
//
// The critical property: `completion_pct` is passed through, never recomputed.
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/automation/automation_service.dart';

/// Shaped exactly like the live RPC response.
const _livePayload = <String, dynamic>{
  'ok': true,
  'departments': <Map<String, dynamic>>[
    <String, dynamic>{
      'department': 'audit',
      'label': 'Audit',
      'is_configurable': false,
      'display_order': 10,
      'total': 4,
      'live': 0,
      'in_progress': 1,
      'not_started': 3,
      'completion_pct': 12.5,
    },
    <String, dynamic>{
      'department': 'e_business',
      'label': 'E-Business',
      'is_configurable': true,
      'display_order': 60,
      'total': 0,
      'live': 0,
      'in_progress': 0,
      'not_started': 0,
      'completion_pct': null,
    },
  ],
  'items': <Map<String, dynamic>>[
    <String, dynamic>{
      'item_key': 'branch_turnaround_tracking',
      'label': 'Branch request turnaround tracking',
      'status': 'not_started',
      'live_at': null,
      'department': 'admin',
      'description': 'Time-to-response measured between submission',
    },
    <String, dynamic>{
      'item_key': 'performance_appraisal',
      'label': 'Performance appraisal',
      'status': 'in_progress',
      'live_at': null,
      'department': 'hr',
      'description': 'Company-wide review cycles',
    },
  ],
  'active_workflows': <Map<String, dynamic>>[
    <String, dynamic>{
      'item_key': 'performance_appraisal',
      'label': 'Performance appraisal',
      'status': 'in_progress',
      'live_at': null,
      'department': 'hr',
      'description': 'Company-wide review cycles',
    },
  ],
  'totals': <String, dynamic>{'items': 14, 'live': 3},
};

AutomationPortfolio _build() {
  final map = Map<String, dynamic>.from(_livePayload);
  final totals = Map<String, dynamic>.from(map['totals'] as Map);
  List<Map<String, dynamic>> rows(Object? v) => (v as List)
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);
  return AutomationPortfolio(
    departments: rows(map['departments']).map(AutomationDepartment.new).toList(),
    items: rows(map['items']).map(AutomationItem.new).toList(),
    activeWorkflows: rows(map['active_workflows']).map(AutomationItem.new).toList(),
    totalItems: (totals['items'] as num).toInt(),
    totalLive: (totals['live'] as num).toInt(),
  );
}

void main() {
  group('Totals', () {
    test('reads the server totals rather than counting rows', () {
      final p = _build();
      expect(p.totalItems, 14);
      expect(p.totalLive, 3);
      expect(p.departments, hasLength(2));
    });
  });

  group('Department completion is passed through, never recomputed', () {
    test("a department's percentage is the server's own figure", () {
      final audit = _build().departments.first;
      expect(audit.key, 'audit');
      expect(audit.label, 'Audit');
      expect(audit.completionPct, 12.5);
    });

    test('a department with no measured percentage stays null, not 0', () {
      final eBusiness = _build().departments[1];
      expect(eBusiness.key, 'e_business');
      expect(eBusiness.completionPct, isNull);
      expect(eBusiness.total, 0);
      expect(eBusiness.isConfigurable, isTrue);
    });

    test('counts are read as ints even when JSONB sends doubles', () {
      final d = AutomationDepartment(<String, dynamic>{
        'department': 'x',
        'label': 'X',
        'total': 4.0,
        'live': 2.0,
        'in_progress': 1.0,
        'not_started': 1.0,
        'completion_pct': 62.5,
      });
      expect(d.total, 4);
      expect(d.live, 2);
      expect(d.inProgress, 1);
      expect(d.notStarted, 1);
    });
  });

  group('Item status', () {
    test('maps the wire values the database CHECK allows', () {
      expect(AutomationStatus.parse('live'), AutomationStatus.live);
      expect(AutomationStatus.parse('in_progress'), AutomationStatus.inProgress);
      expect(AutomationStatus.parse('not_started'), AutomationStatus.notStarted);
    });

    test('an unrecognised status fails safe to not-started, never to live', () {
      // Anything unknown must not be reported as a completed workstream.
      expect(AutomationStatus.parse('shipped'), AutomationStatus.notStarted);
      expect(AutomationStatus.parse(null), AutomationStatus.notStarted);
    });

    test('every status has a human label for the badge', () {
      for (final s in AutomationStatus.values) {
        expect(s.label, isNotEmpty);
      }
    });
  });

  group('Items are grouped by department', () {
    test('itemsFor returns only that department, in server order', () {
      final p = _build();
      expect(p.itemsFor('admin').map((i) => i.key), <String>[
        'branch_turnaround_tracking',
      ]);
      expect(p.itemsFor('hr').map((i) => i.key), <String>['performance_appraisal']);
      expect(p.itemsFor('risk'), isEmpty);
    });

    test('an empty department has no items but is still listed', () {
      final p = _build();
      final eBusiness = p.departments[1];
      expect(p.itemsForDepartment(eBusiness), isEmpty);
      // The point of the registry: it must not vanish because it is empty.
      expect(p.departments.any((d) => d.key == 'e_business'), isTrue);
    });
  });

  group('Active workflows', () {
    test('carries the in-progress items with their department', () {
      final p = _build();
      expect(p.activeWorkflows, hasLength(1));
      expect(p.activeWorkflows.first.department, 'hr');
      expect(p.activeWorkflows.first.status, AutomationStatus.inProgress);
    });
  });

  group('Defensive reads', () {
    test('a missing live_at is null rather than an epoch date', () {
      final p = _build();
      expect(p.items.first.liveAt, isNull);
    });

    test('an absent key/label degrades to empty strings, not a crash', () {
      final item = AutomationItem(<String, dynamic>{});
      expect(item.key, '');
      expect(item.label, '');
      expect(item.department, '');
      expect(item.status, AutomationStatus.notStarted);
    });

    test('a live_at timestamp is parsed', () {
      final item = AutomationItem(<String, dynamic>{
        'live_at': '2026-09-28T09:41:38.491853+00:00',
      });
      expect(item.liveAt, isNotNull);
      expect(item.liveAt!.year, 2026);
    });
  });
}
