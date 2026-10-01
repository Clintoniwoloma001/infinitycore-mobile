import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/leave/leave_planner_client.dart';
import 'package:infinitycore/features/leave/leave_planner_service.dart';

/// Leave Schedule Planner - model and verdict tests.
///
/// These cover the two places a planner could quietly lie to an executive: how a
/// date range is rendered, and how a verdict maps to a decision. The RPC
/// payloads themselves are produced by Postgres and are not re-derived here.
void main() {
  group('Leave planner date ranges', () {
    test('a single-day request keeps its start as the effective end', () {
      final e = PlannerEntry(
        employeeId: 'e1',
        fullName: 'Ada Okafor',
        leaveType: 'annual',
        status: 'approved',
        startDate: '2026-10-15',
      );

      // A null end_date means one day, which the server permits.
      expect(e.effectiveEnd, '2026-10-15');
    });

    test('a multi-day request keeps its own end date', () {
      final e = PlannerEntry(
        employeeId: 'e1',
        fullName: 'Ada Okafor',
        leaveType: 'annual',
        status: 'approved',
        startDate: '2026-10-15',
        endDate: '2026-10-25',
      );

      expect(e.effectiveEnd, '2026-10-25');
    });

    test('a partial payload still renders rather than crashing', () {
      // A partially-populated entry must not take the screen down.
      final e = PlannerEntry.fromJson(const {'employee_id': 'e1'});

      expect(e.employeeId, 'e1');
      expect(e.fullName, '');
      expect(e.plannerState, 'completed');
    });

    test('working days defaults to zero rather than null', () {
      final e = PlannerEntry.fromJson(const {'working_days': null});

      expect(e.workingDays, 0);
    });
  });

  group('Leave planner verdict', () {
    test('each server verdict maps to its own state', () {
      expect(leaveVerdictFrom('AVAILABLE'), LeaveVerdict.available);
      expect(leaveVerdictFrom('WARNING'), LeaveVerdict.warning);
      expect(leaveVerdictFrom('CONFLICT'), LeaveVerdict.conflict);
    });

    test('an unrecognised verdict is UNKNOWN, never approved', () {
      // The dangerous default: treating an unparseable verdict as "available"
      // would let a blocked request through the UI.
      expect(leaveVerdictFrom('SOMETHING_NEW'), LeaveVerdict.unknown);
      expect(leaveVerdictFrom(null), LeaveVerdict.unknown);
      expect(leaveVerdictFrom(''), LeaveVerdict.unknown);

      // So the UI must branch on the verdict explicitly rather than treating
      // "not blocked" as "fine".
      expect(leaveVerdictFrom('nonsense') == LeaveVerdict.available, isFalse);
    });

    test('only a CONFLICT blocks a request', () {
      LeaveAvailability withVerdict(String raw) =>
          LeaveAvailability.fromJson({'verdict': raw});

      expect(withVerdict('CONFLICT').isBlocked, isTrue);
      expect(withVerdict('WARNING').isBlocked, isFalse);
      expect(withVerdict('AVAILABLE').isBlocked, isFalse);
      expect(withVerdict('garbage').isBlocked, isFalse);
    });

    test('a missing or wrongly-typed list degrades to empty, not a crash', () {
      // PostgREST can hand back null or a scalar where a list is expected.
      final a = LeaveAvailability.fromJson(const {
        'verdict': 'CONFLICT',
        'conflicts': null,
        'warnings': 'unexpected',
      });

      expect(a.conflicts, isEmpty);
      expect(a.warnings, isEmpty);
      expect(a.alternatives, isEmpty);
    });

    test('server-provided conflicts survive intact', () {
      final a = LeaveAvailability.fromJson(const {
        'verdict': 'CONFLICT',
        'conflicts': [
          {'department': 'Legal', 'on_leave': 3, 'max_on_leave': 2},
        ],
      });

      expect(a.conflicts.length, 1);
      expect(a.conflicts.first['department'], 'Legal');
    });
  });

  group('Leave capacity day', () {
    test('a day at its ceiling is flagged as at capacity', () {
      const day = LeaveCapacityDay({
        'date': '2026-10-15',
        'on_leave': 3,
        'max_on_leave': 3,
      });

      expect(day.onLeave, 3);
      expect(day.maxOnLeave, 3);
      expect(day.isAtCapacity, isTrue);
      expect(day.pressure, 1.0);
    });

    test('a day under its ceiling is not flagged', () {
      const day = LeaveCapacityDay({
        'date': '2026-10-15',
        'on_leave': 1,
        'max_on_leave': 3,
      });

      expect(day.isAtCapacity, isFalse);
      expect(day.pressure, closeTo(1 / 3, 0.001));
    });

    test('an over-subscribed day clamps rather than exceeding 1', () {
      const day = LeaveCapacityDay({
        'date': '2026-10-15',
        'on_leave': 9,
        'max_on_leave': 3,
      });

      // pressure is a heatmap tint, never a score shown to an executive.
      expect(day.pressure, 1.0);
    });

    test('an ungoverned day has no ceiling and is not at capacity', () {
      // No rule applies, so there is nothing to be at capacity against, and it
      // must not read as "full" against a zero ceiling.
      const day = LeaveCapacityDay({'date': '2026-10-15', 'on_leave': 4});

      expect(day.maxOnLeave, isNull);
      expect(day.isAtCapacity, isFalse);
      expect(day.pressure, 0);
    });

    test('a zero ceiling is treated as no ceiling', () {
      const day = LeaveCapacityDay({
        'date': '2026-10-15',
        'on_leave': 4,
        'max_on_leave': 0,
      });

      expect(day.isAtCapacity, isFalse);
      expect(day.pressure, 0);
    });

    test('numeric fields arriving as strings are coerced', () {
      // PostgREST returns numerics as int, double or string by column type.
      const day = LeaveCapacityDay({
        'date': '2026-10-15',
        'on_leave': '2',
        'max_on_leave': '4',
      });

      expect(day.onLeave, 2);
      expect(day.maxOnLeave, 4);
    });
  });

  group('LeavePlanner grouping', () {
    PlannerEntry entry(String id, {String? department}) => PlannerEntry(
      employeeId: id,
      fullName: 'Staff $id',
      department: department,
      leaveType: 'annual',
      status: 'approved',
      startDate: '2026-10-01',
    );

    test('entries group by department with an explicit unassigned bucket', () {
      final planner = LeavePlanner(
        entries: [
          entry('1', department: 'Legal'),
          entry('2', department: 'Legal'),
          entry('3'),
        ],
        summary: const {},
        capacity: const [],
      );

      final grouped = planner.byDepartment;
      expect(grouped['Legal']!.length, 2);
      // A missing department must stay visible, never silently dropped.
      expect(grouped['Unassigned']!.length, 1);
    });

    test('an empty department string falls into the unassigned bucket', () {
      final planner = LeavePlanner(
        entries: [entry('1', department: '')],
        summary: const {},
        capacity: const [],
      );

      expect(planner.byDepartment.containsKey('Unassigned'), isTrue);
      expect(planner.byDepartment.containsKey(''), isFalse);
    });
  });
}