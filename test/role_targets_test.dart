// Tests for the cumulative target maths. The rule under test: completion is
// measured against the ELAPSED portion of a target's window, never its full
// length. Getting this wrong makes every in-flight target look failed.

import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/performance/role_targets.dart';

PerformanceTarget t({
  String id = 'x',
  double target = 100,
  double current = 0,
  double start = 0,
  DateTime? from,
  DateTime? to,
  String role = '',
  String employeeId = 'e1',
  TargetStatus status = TargetStatus.active,
  String unit = '',
}) {
  return PerformanceTarget(
    id: id,
    title: 'T',
    employeeId: employeeId,
    employeeName: 'N',
    role: role,
    department: '',
    measurementType: 'number',
    targetValue: target,
    currentValue: current,
    startingValue: start,
    unit: unit,
    startDate: from,
    endDate: to,
    status: status,
  );
}

void main() {
  // Anchored to the real clock. Hard-coded 2025 windows would already be
  // closed, so every "still in progress" assertion would silently pass for the
  // wrong reason.
  final now = DateTime.now();
  final nextYear = DateTime(now.year + 1, 1, 1);

  // Exact 100-day windows, so a quarter of the way in is exactly 25 days rather
  // than the 24.72% that Jan 1 -> Apr 1 really is. These tests are about the
  // RULE, so the arithmetic must be clean enough to check by eye.
  // A 100-day window that OPENED 25 days ago and closes in 75 days, so the
  // real clock sits exactly one quarter of the way in. Anchoring to DateTime.now()
  // is deliberate: several getters default to the real clock, so a hard-coded
  // 2025 window would have those calls measure a long-closed target while the
  // test still claimed it was in progress.
  final jan1 = DateTime.now().subtract(const Duration(days: 25));
  final dec31 = jan1.add(const Duration(days: 100));
  DateTime apr1(int days) => jan1.add(Duration(days: days));

  group('cumulative completion is measured against elapsed time', () {
    test('a third-year target reads ~25%, not 0%, at the quarter mark', () {
      // 25% of the year elapsed, 25% of 100 achieved -> exactly 100% of pace.
      final target = t(target: 100, current: 25, from: jan1, to: dec31);
      expect(target.completionPct(asOf: apr1(25)), closeTo(100, 1));
    });

    test('behind pace reads below 100 even with real progress made', () {
      // 25% elapsed, only 10 achieved -> 40% of the pace expected.
      final target = t(target: 100, current: 10, from: jan1, to: dec31);
      expect(target.completionPct(asOf: apr1(25)), closeTo(40, 2));
    });

    test('ahead of pace is allowed to exceed 100%', () {
      final target = t(target: 100, current: 50, from: jan1, to: dec31);
      expect(target.completionPct(asOf: apr1(25)), closeTo(200, 1));
    });

    test('past the end date, the whole target is due', () {
      final target = t(target: 100, current: 80, from: jan1, to: dec31);
      expect(
        target.completionPct(asOf: DateTime(now.year + 1, 3, 1)),
        closeTo(80, 1),
      );
    });

    test('before the window opens there is nothing to measure', () {
      // The core rule: not-yet-due is null, NEVER 0.
      final target = t(target: 100, current: 0, from: nextYear);
      expect(target.completionPct(asOf: apr1(25)), isNull);
    });

    test('a target with no dates is measured straight against its value', () {
      final target = t(target: 200, current: 50);
      expect(target.completionPct(asOf: apr1(25)), closeTo(25, 1));
    });
  });

  group('starting values', () {
    test('progress is the rise, not the absolute current value', () {
      // Starts at 500, must reach 1000. Sitting at 500 is 0%, not 50%.
      final target = t(target: 1000, current: 500, start: 500);
      expect(target.achievedDelta, 0);
      expect(target.completionPct(asOf: apr1(25)), 0);
    });

    test('halving a 500-wide band reads as half done', () {
      final target = t(target: 1000, current: 750, start: 500);
      expect(target.completionPct(asOf: apr1(25)), closeTo(50, 1));
    });

    test('a zero-width target has no meaningful ratio', () {
      // target == start means nothing to climb; reporting Infinity or 0 would
      // both be lies.
      final target = t(target: 500, current: 500, start: 500);
      expect(target.completionPct(asOf: apr1(25)), isNull);
    });
  });

  group('terminal status', () {
    test('an achieved target is not re-measured against the clock', () {
      final target = t(
        target: 100,
        current: 100,
        from: jan1,
        to: dec31,
        status: TargetStatus.achieved,
      );
      expect(target.completionPct(asOf: apr1(25)), isNull);
    });

    test('a cancelled target is excluded from averages entirely', () {
      final target = t(
        target: 100,
        current: 0,
        from: jan1,
        to: dec31,
        status: TargetStatus.cancelled,
      );
      expect(target.completionPct(asOf: apr1(25)), isNull);
      final group = RoleTargets(role: 'Cashier', targets: [target]);
      expect(group.averageCompletion, isNull);
      expect(group.cancelled, 1);
    });
  });

  group('overdue detection', () {
    test('a target past its end date has negative days remaining', () {
      final target = t(target: 100, current: 10, from: jan1, to: dec31);
      expect(
        target.daysRemaining(asOf: dec31.add(const Duration(days: 30))),
        lessThan(0),
      );
    });

    test('a target still in window is not overdue', () {
      // The window closes 75 days from now, so against the real clock this
      // target is open and healthy.
      final target = t(target: 100, current: 10, from: jan1, to: dec31);
      expect(target.isOverdue, isFalse);
      expect(target.daysRemaining(), greaterThan(0));
      expect(target.daysRemaining(asOf: apr1(25)), greaterThan(0));
    });

    test('a missed target is not also reported as overdue', () {
      // It is already closed out; showing both would double-count the failure.
      final target = t(
        target: 100,
        current: 10,
        from: jan1,
        to: dec31,
        status: TargetStatus.missed,
      );
      expect(target.isOverdue, isFalse);
    });

    test('no end date means no countdown', () {
      expect(t().daysRemaining(asOf: apr1(25)), isNull);
      expect(t().isOverdue, isFalse);
    });
  });
  group('grouping by role', () {
    test('resolves the role through the employee map', () {
      // `targets` has no role column, so grouping depends on this lookup.
      final grouped = groupTargetsByRole(
        [t(employeeId: 'e1', current: 50), t(employeeId: 'e2', current: 10)],
        {'e1': 'Cashier', 'e2': 'Cashier'},
      );
      expect(grouped.keys, ['Cashier']);
      expect(grouped['Cashier']!.total, 2);
    });

    test(
      'an employee with no position is grouped as Unassigned, not dropped',
      () {
        // Silently discarding these would hide underperforming staff.
        final grouped = groupTargetsByRole([t(employeeId: 'e9')], {});
        expect(grouped.keys, contains('Unassigned'));
        expect(grouped['Unassigned']!.total, 1);
      },
    );

    test('a not-yet-due target does not drag the role average down', () {
      // One target on pace, one not started. The role reads 100%,
      // NOT 50% — treating "not reported" as zero is the bug this avoids.
      final grouped = groupTargetsByRole(
        [
          // 25% of the window has elapsed and 25 of 100 is done: on pace.
          t(id: 'a', employeeId: 'e1', current: 25, from: jan1, to: dec31),
          t(id: 'b', employeeId: 'e1', current: 0, from: nextYear),
        ],
        {'e1': 'Cashier'},
      );
      final group = grouped['Cashier']!;
      expect(group.averageCompletion, closeTo(100, 1));
      expect(group.notYetDue, 1);
      expect(group.measurable, hasLength(1));
    });

    test('a role with nothing measurable shows a dash, not 0%', () {
      final grouped = groupTargetsByRole(
        [t(employeeId: 'e1', from: nextYear)],
        {'e1': 'Teller'},
      );
      expect(grouped['Teller']!.completionLabel, '—');
    });

    test('roles with nothing measurable sort LAST, not first', () {
      // A missing average is not a perfect score. Leading the board with one
      // would be the same error as reading "not reported" as 0%, inverted.
      final grouped = groupTargetsByRole([
        t(
          id: 'a',
          employeeId: 'e1',
          role: 'Teller',
          current: 50,
          from: jan1,
          to: dec31,
        ),
        t(id: 'b', employeeId: 'e2', role: 'Auditor', from: nextYear),
      ], {});
      expect(grouped.keys.first, 'Teller');
      expect(grouped.keys.last, 'Auditor');
    });

    test('roles are ordered best first', () {
      final grouped = groupTargetsByRole([
        t(
          id: 'a',
          employeeId: 'e1',
          role: 'Weak',
          current: 10,
          from: jan1,
          to: dec31,
        ),
        t(
          id: 'b',
          employeeId: 'e2',
          role: 'Strong',
          current: 100,
          from: jan1,
          to: dec31,
        ),
      ], {});
      expect(grouped.keys.first, 'Strong');
    });

    test('an empty input yields an empty map rather than throwing', () {
      expect(groupTargetsByRole([], {}), isEmpty);
    });

    test('role names are title-cased for display', () {
      final grouped = groupTargetsByRole([t(role: 'head teller')], {});
      expect(grouped.keys.single, 'Head teller');
    });
  });

  group('expected value', () {
    test('reports the straight-line expectation at the quarter mark', () {
      final target = t(target: 100, start: 0, from: jan1, to: dec31);
      expect(target.expectedValue(asOf: apr1(25)), closeTo(25, 1));
    });

    test('is null before the window opens', () {
      final target = t(target: 100, from: nextYear);
      expect(target.expectedValue(asOf: apr1(25)), isNull);
    });

    test('a cancelled target has no expectation to chase', () {
      final target = t(
        target: 100,
        from: jan1,
        to: dec31,
        status: TargetStatus.cancelled,
      );
      expect(target.expectedValue(asOf: apr1(25)), isNull);
    });
    test('a future start with NO end date is still not-yet-due', () {
      // Regression: this fell through to the "no window, all due" branch and
      // reported 0% for a target that had not begun.
      final target = t(target: 100, current: 0, from: nextYear, to: null);
      expect(target.completionPct(asOf: apr1(25)), isNull);
    });

    test('a backwards target is excluded rather than shown as negative', () {
      // target 100 but start 500: a data-entry error. A negative percentage
      // would render as nonsense, so it is simply not measurable.
      final target = t(target: 100, current: 400, start: 500);
      expect(target.completionPct(asOf: apr1(25)), isNull);
    });

    test('a zero-length window does not divide by zero', () {
      final target = t(target: 100, current: 50, from: apr1(5), to: apr1(5));
      expect(target.completionPct(asOf: apr1(25)), closeTo(50, 0.01));
    });

    test('an empty input yields an empty map rather than throwing', () {
      expect(groupTargetsByRole([], {}), isEmpty);
    });
  });
}
