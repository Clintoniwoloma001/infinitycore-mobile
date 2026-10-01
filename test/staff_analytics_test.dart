import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/attendance/staff_analytics.dart';
import 'package:infinitycore/shared/models/models.dart';

/// HR staff analytics: period windows, per-person scorecards, 2-3 way
/// comparison, and the top-performer leaderboards.
void main() {
  final september = AnalyticsPeriod.of(
    AnalyticsPeriodType.month,
    DateTime(2026, 9, 15),
  );

  AttendanceManagementRow row(
    String employeeId,
    String date, {
    String name = '',
    String position = '',
    String department = '',
    String branchName = '',
    String status = 'present',
    int lateMinutes = 0,
    double hours = 8,
    String geofence = 'inside',
    bool clockedIn = true,
    bool clockedOut = true,
  }) => AttendanceManagementRow(
    attendanceId: '$employeeId-$date',
    employeeId: employeeId,
    employeeName: name.isEmpty ? 'Staff $employeeId' : name,
    employeeNumber: 'IMFB/$employeeId',
    position: position,
    department: department,
    branchName: branchName,
    attendanceDate: date,
    clockIn: clockedIn ? '${date}T08:00:00Z' : null,
    clockOut: clockedOut ? '${date}T17:00:00Z' : null,
    status: status,
    workHours: hours,
    lateMinutes: lateMinutes,
    geofenceStatus: geofence,
  );

  group('AnalyticsPeriod windows', () {
    test('a month covers the whole month regardless of anchor day', () {
      // The anchor day must not clip the window: picking "September 2026" on
      // the 30th still has to include the 1st.
      for (final day in [1, 15, 30]) {
        final p = AnalyticsPeriod.of(
          AnalyticsPeriodType.month,
          DateTime(2026, 9, day),
        );
        expect(p.start, DateTime(2026, 9, 1));
        expect(p.end, DateTime(2026, 9, 30));
        expect(p.dayCount, 30);
      }
    });

    test('December rolls into the next January', () {
      final p = AnalyticsPeriod.of(
        AnalyticsPeriodType.month,
        DateTime(2026, 12, 10),
      );
      expect(p.start, DateTime(2026, 12, 1));
      expect(p.end, DateTime(2026, 12, 31));
      expect(p.dayCount, 31);
    });

    test('February in a leap year has 29 days', () {
      final leap = AnalyticsPeriod.of(
        AnalyticsPeriodType.month,
        DateTime(2028, 2, 5),
      );
      expect(leap.dayCount, 29);
      expect(leap.end, DateTime(2028, 2, 29));
    });

    test('quarters are Jan-Mar, Apr-Jun, Jul-Sep, Oct-Dec', () {
      expect(AnalyticsPeriod.quarterOf(DateTime(2026, 1, 5)), 1);
      expect(AnalyticsPeriod.quarterOf(DateTime(2026, 3, 31)), 1);
      expect(AnalyticsPeriod.quarterOf(DateTime(2026, 4, 1)), 2);
      expect(AnalyticsPeriod.quarterOf(DateTime(2026, 7, 1)), 3);
      expect(AnalyticsPeriod.quarterOf(DateTime(2026, 9, 30)), 3);
      expect(AnalyticsPeriod.quarterOf(DateTime(2026, 10, 1)), 4);
      expect(AnalyticsPeriod.quarterOf(DateTime(2026, 12, 31)), 4);

      final q3 = AnalyticsPeriod.of(
        AnalyticsPeriodType.quarter,
        DateTime(2026, 8, 20),
      );
      expect(q3.start, DateTime(2026, 7, 1));
      expect(q3.end, DateTime(2026, 9, 30));
      expect(q3.label, 'Q3 2026');
    });

    test('a year spans 1 Jan to 31 Dec', () {
      final p = AnalyticsPeriod.of(
        AnalyticsPeriodType.year,
        DateTime(2026, 7, 4),
      );
      expect(p.start, DateTime(2026, 1, 1));
      expect(p.end, DateTime(2026, 12, 31));
      expect(p.dayCount, 365);
      expect(p.label, '2026');
    });

    test('a single day covers only itself', () {
      final p = AnalyticsPeriod.of(
        AnalyticsPeriodType.day,
        DateTime(2026, 9, 16),
      );
      expect(p.start, DateTime(2026, 9, 16));
      expect(p.end, DateTime(2026, 9, 16));
      expect(p.contains(DateTime(2026, 9, 16)), isTrue);
      expect(p.contains(DateTime(2026, 9, 17)), isFalse);
    });

    test('a week runs Monday to Sunday', () {
      // 16 Sep 2026 is a Wednesday.
      final p = AnalyticsPeriod.of(
        AnalyticsPeriodType.week,
        DateTime(2026, 9, 16),
      );
      expect(p.start, DateTime(2026, 9, 14));
      expect(p.end, DateTime(2026, 9, 20));
      expect(p.start.weekday, DateTime.monday);
      expect(p.end.weekday, DateTime.sunday);
      expect(p.dayCount, 7);
    });

    test('a reversed custom range is ordered rather than empty', () {
      final p = AnalyticsPeriod.of(
        AnalyticsPeriodType.custom,
        DateTime(2026, 9, 1),
        customStart: DateTime(2026, 9, 20),
        customEnd: DateTime(2026, 9, 5),
      );
      expect(p.start, DateTime(2026, 9, 5));
      expect(p.end, DateTime(2026, 9, 20));
      expect(p.contains(DateTime(2026, 9, 10)), isTrue);
    });

    test('month boundaries are inclusive on both ends', () {
      expect(september.contains(DateTime(2026, 9, 1)), isTrue);
      expect(september.contains(DateTime(2026, 9, 30)), isTrue);
      expect(september.contains(DateTime(2026, 8, 31)), isFalse);
      expect(september.contains(DateTime(2026, 10, 1)), isFalse);
    });
  });

  group('per-person scorecards', () {
    test('a perfect month scores 100', () {
      final m = StaffAttendanceMetrics.fromRows(
        [
          for (var d = 1; d <= 20; d++)
            row('e1', '2026-09-${d.toString().padLeft(2, '0')}'),
        ],
        period: september,
      );

      expect(m.daysPresent, 20);
      expect(m.lateDays, 0);
      expect(m.geofenceViolations, 0);
      expect(m.score, 100);
      expect(m.scoreFor(AttendanceMetricKind.attendance), 100);
      expect(m.scoreFor(AttendanceMetricKind.hours), 100);
    });

    test('late days lower punctuality but not attendance', () {
      final m = StaffAttendanceMetrics.fromRows(
        [
          for (var d = 1; d <= 10; d++)
            row(
              'e1',
              '2026-09-${d.toString().padLeft(2, '0')}',
              lateMinutes: d <= 3 ? 20 : 0,
            ),
        ],
        period: september,
      );

      expect(m.daysPresent, 10);
      expect(m.lateDays, 3);
      expect(m.onTimeDays, 7);
      expect(m.scoreFor(AttendanceMetricKind.attendance), 100);
      expect(m.scoreFor(AttendanceMetricKind.punctuality), 70);
      expect(m.totalLateMinutes, 60);
    });

    test('an outside-geofence clock-in counts as a violation', () {
      final m = StaffAttendanceMetrics.fromRows(
        [
          for (var d = 1; d <= 4; d++)
            row(
              'e1',
              '2026-09-0$d',
              geofence: d == 1 ? 'outside' : 'inside',
            ),
        ],
        period: september,
      );

      expect(m.geofenceViolations, 1);
      expect(m.scoreFor(AttendanceMetricKind.geofence), 75);
    });

    test('an unknown location is not counted as a violation', () {
      // Only a captured "outside" verdict is a violation. Treating a missing
      // geofence as one would punish staff whose device had no fix.
      final m = StaffAttendanceMetrics.fromRows(
        [
          for (var d = 1; d <= 4; d++)
            row('e1', '2026-09-0$d', geofence: ''),
        ],
        period: september,
      );

      expect(m.geofenceViolations, 0);
      expect(m.scoreFor(AttendanceMetricKind.geofence), 100);
    });

    test('two rows on one day count as one present day', () {
      final m = StaffAttendanceMetrics.fromRows(
        [
          row('e1', '2026-09-01', hours: 8),
          row('e1', '2026-09-01', hours: 8),
        ],
        period: september,
      );

      expect(m.records, 1);
      expect(m.daysPresent, 1);
      expect(m.totalHours, 8);
    });

    test('the completed row wins over an open duplicate', () {
      // A corrected clock-in wrote a second row: one open, one closed. The
      // closed row is the real one, so its hours must be the ones counted.
      final m = StaffAttendanceMetrics.fromRows(
        [
          row('e1', '2026-09-01', hours: 0, clockedOut: false),
          row('e1', '2026-09-01', hours: 8),
        ],
        period: september,
      );

      expect(m.records, 1);
      expect(m.totalHours, 8);
      expect(m.incompleteDays, 0);
    });

    test('an employee with no rows scores 0 and never 100', () {
      final m = StaffAttendanceMetrics.fromRows(const [], period: september);

      expect(m.hasData, isFalse);
      expect(m.score, 0);
      expect(m.scoreFor(AttendanceMetricKind.attendance), 0);
      expect(m.scoreFor(AttendanceMetricKind.punctuality), 0);
      expect(m.daysPresent, 0);
      expect(m.averageHoursPerPresentDay, 0);
    });

    test('an open session with no clock-out is flagged incomplete', () {
      final m = StaffAttendanceMetrics.fromRows(
        [
          row('e1', '2026-09-01', clockedOut: false),
          row('e1', '2026-09-02'),
        ],
        period: september,
      );

      expect(m.daysPresent, 2);
      expect(m.incompleteDays, 1);
    });

    test('hours are capped at 100 so a long day cannot inflate the score', () {
      final m = StaffAttendanceMetrics.fromRows(
        [row('e1', '2026-09-01', hours: 40)],
        period: september,
      );

      expect(m.scoreFor(AttendanceMetricKind.hours), 100);
      expect(m.totalHours, 40);
      expect(m.score, 100);
    });

    test('an absent row with no clock-in is not counted as present', () {
      final m = StaffAttendanceMetrics.fromRows(
        [
          row(
            'e1',
            '2026-09-01',
            status: 'absent',
            hours: 0,
            clockedIn: false,
            clockedOut: false,
          ),
          row('e1', '2026-09-02'),
        ],
        period: september,
      );

      expect(m.daysAbsent, 1);
      expect(m.daysPresent, 1);
      expect(m.scoreFor(AttendanceMetricKind.attendance), 50);
    });

    test('identity is carried onto the scorecard', () {
      final m = StaffAttendanceMetrics.fromRows(
        [
          row(
            'e7',
            '2026-09-01',
            name: 'ADA OBI',
            position: 'Branch Manager',
            department: 'Operations',
            branchName: 'Ketu',
          ),
        ],
        period: september,
      );

      expect(m.employeeId, 'e7');
      expect(m.employeeName, 'ADA OBI');
      expect(m.position, 'Branch Manager');
      expect(m.department, 'Operations');
      expect(m.branchName, 'Ketu');
    });
  });

  group('comparison of 2-3 staff', () {
    late StaffAttendanceMetrics ada;
    late StaffAttendanceMetrics bole;
    late StaffAttendanceMetrics chi;

    setUp(() {
      ada = StaffAttendanceMetrics.fromRows(
        [
          for (var d = 1; d <= 10; d++)
            row('a', '2026-09-${d.toString().padLeft(2, '0')}'),
        ],
        period: september,
      );
      bole = StaffAttendanceMetrics.fromRows(
        [
          for (var d = 1; d <= 10; d++)
            row(
              'b',
              '2026-09-${d.toString().padLeft(2, '0')}',
              lateMinutes: 30,
            ),
        ],
        period: september,
      );
      chi = StaffAttendanceMetrics.fromRows(
        [
          for (var d = 1; d <= 5; d++)
            row('c', '2026-09-0${d + 1}'),
        ],
        period: september,
      );
    });

    test('up to three employees can be compared', () {
      var c = const StaffComparison(employees: []);
      expect(c.isEmpty, isTrue);

      c = c.add(ada).add(bole).add(chi);
      expect(c.employees.length, 3);
      expect(c.isFull, isTrue);
    });

    test('a fourth employee is refused', () {
      final fourth = StaffAttendanceMetrics.fromRows(
        [row('d', '2026-09-01')],
        period: september,
      );
      final c = const StaffComparison(employees: [])
          .add(ada)
          .add(bole)
          .add(chi)
          .add(fourth);

      expect(c.employees.length, 3);
      expect(c.employees.any((e) => e.employeeId == 'd'), isFalse);
    });

    test('the same employee cannot be added twice', () {
      final c = const StaffComparison(employees: []).add(ada).add(ada);
      expect(c.employees.length, 1);
    });

    test('the leader is picked per metric, not overall', () {
      final c = StaffComparison(employees: [ada, bole, chi]);

      // All three attended the same number of days, so attendance ties.
      expect(c.isTiedOn(AttendanceMetricKind.attendance), isTrue);
      // Ada was never late, so she leads on punctuality.
      expect(
        c.leaderFor(AttendanceMetricKind.punctuality)?.employeeId,
        'a',
      );
      // Chi only has five records, so she leads on attendance rate.
      expect(c.leaderFor(AttendanceMetricKind.attendance)?.employeeId, 'a');
    });

    test('removing an employee updates the comparison', () {
      final c = StaffComparison(employees: [ada, bole]).removeAt(0);
      expect(c.employees.single.employeeId, 'b');
    });

    test('removing an out-of-range index is a no-op', () {
      final base = StaffComparison(employees: [ada, bole]);
      expect(base.removeAt(5).employees.length, 2);
      expect(base.removeAt(-1).employees.length, 2);
    });

    test('the spread is the gap between best and worst', () {
      final c = StaffComparison(employees: [ada, bole]);
      // Ada is never late (100%) and Bole is late every day (0%), so the
      // punctuality gap is the full 100 points.
      expect(c.spreadFor(AttendanceMetricKind.punctuality), 100);
      // Both attended every day, so their attendance spread is zero.
      expect(c.spreadFor(AttendanceMetricKind.attendance), 0);
    });

    test('a single-employee comparison reports no spread', () {
      final c = StaffComparison(employees: [ada]);
      // 100 points against a nonexistent rival would be meaningless.
      expect(c.spreadFor(AttendanceMetricKind.attendance), 0);
      expect(c.isTiedOn(AttendanceMetricKind.attendance), isFalse);
    });

    test('a comparison with nobody having data has no leader', () {
      final empty = StaffAttendanceMetrics.fromRows(
        const [],
        period: september,
      );
      final c = StaffComparison(employees: [empty, ada]);
      expect(c.leaderFor(AttendanceMetricKind.punctuality)?.employeeId, 'a');
    });
  });

  group('top-performer leaderboards', () {
    /// Builds a report where each employee's score is controlled, so ordering
    /// assertions are exact rather than incidental: employee `i` is late on `i`
    /// days out of 10, so scores strictly decrease as `i` rises.
    StaffAnalyticsReport reportWith({
      required int employees,
      String branch = 'Head Office',
      String position = 'Officer',
      String department = 'Operations',
    }) {
      final rows = <AttendanceManagementRow>[];
      for (var i = 0; i < employees; i++) {
        for (var d = 1; d <= 10; d++) {
          rows.add(
            row(
              'e$i',
              '2026-09-${d.toString().padLeft(2, '0')}',
              name: 'Person $i',
              position: position,
              department: department,
              branchName: branch,
              lateMinutes: d <= i ? 15 : 0,
            ),
          );
        }
      }
      return StaffAnalyticsReport.fromRows(rows, september);
    }

    test('the best employee overall is pinned for HR', () {
      final report = reportWith(employees: 4);
      final best = Leaderboards.overallBest(report.all);

      expect(best, isNotNull);
      expect(best!.employeeId, 'e0');
      expect(best.score, 100);
    });

    test('there is no best employee when nobody has data', () {
      expect(Leaderboards.overallBest(const []), isNull);
      final empty = StaffAnalyticsReport.fromRows(const [], september);
      expect(Leaderboards.overallBest(empty.all), isNull);
    });

    test('the top 5 is capped at five and ordered by score', () {
      final report = reportWith(employees: 9);
      final top = Leaderboards.top(report.all, limit: 5);

      expect(top.length, 5);
      expect(
        top.map((e) => e.metrics.employeeId).toList(),
        ['e0', 'e1', 'e2', 'e3', 'e4'],
      );
      // Ranks run 1..5 because every score here is distinct.
      expect(top.map((e) => e.rank).toList(), [1, 2, 3, 4, 5]);
    });

    test('fewer than five employees yields a shorter board', () {
      expect(Leaderboards.top(reportWith(employees: 3).all).length, 3);
    });

    test('equal scores share a rank', () {
      // Three identical employees must produce 1, 1, 1 - not 1, 2, 3.
      final rows = [
        for (var i = 0; i < 3; i++)
          for (var d = 1; d <= 5; d++)
            row('e$i', '2026-09-0$d', name: 'Person $i'),
      ];
      final report = StaffAnalyticsReport.fromRows(rows, september);

      expect(
        Leaderboards.top(report.all).map((e) => e.rank).toList(),
        [1, 1, 1],
      );
    });

    test('employees with no data are excluded from the board', () {
      const noData = StaffAttendanceMetrics(employeeId: 'ghost');
      final top = Leaderboards.top([...reportWith(employees: 3).all, noData]);

      expect(top.length, 3);
      expect(top.any((e) => e.metrics.employeeId == 'ghost'), isFalse);
    });

    test('top performers can be scoped to one branch', () {
      final rows = <AttendanceManagementRow>[];
      for (var i = 0; i < 3; i++) {
        for (var d = 1; d <= 10; d++) {
          rows.add(
            row(
              'ketu$i',
              '2026-09-${d.toString().padLeft(2, '0')}',
              name: 'Ketu $i',
              branchName: 'Ketu',
              lateMinutes: d <= i ? 15 : 0,
            ),
          );
          rows.add(
            row(
              'lek$i',
              '2026-09-${d.toString().padLeft(2, '0')}',
              name: 'Lekki $i',
              branchName: 'Lekki',
            ),
          );
        }
      }
      final report = StaffAnalyticsReport.fromRows(rows, september);

      final ketu = Leaderboards.topIn(
        report.all,
        LeaderboardDimension.branch,
        'Ketu',
      );
      expect(ketu.first.metrics.branchName, 'Ketu');
      expect(ketu.first.metrics.employeeId, 'ketu0');

      // An unknown branch returns nothing rather than the whole workforce,
      // which would read as a plausible-looking answer to the wrong question.
      expect(
        Leaderboards.topIn(
          report.all,
          LeaderboardDimension.branch,
          'Nowhere',
        ),
        isEmpty,
      );
    });

    test('leaderboards group by branch, role and department', () {
      final rows = <AttendanceManagementRow>[];
      for (var i = 0; i < 2; i++) {
        for (var d = 1; d <= 6; d++) {
          final day = '2026-09-0$d';
          rows.add(
            row(
              'hr$i',
              day,
              name: 'HR $i',
              branchName: 'Head Office',
              position: 'HR Officer',
              department: 'Human Resources',
              lateMinutes: d <= i ? 20 : 0,
            ),
          );
          rows.add(
            row(
              'ops$i',
              day,
              name: 'Ops $i',
              branchName: 'Ketu',
              position: 'Loan Officer',
              department: 'Operations',
            ),
          );
        }
      }
      final report = StaffAnalyticsReport.fromRows(rows, september);

      final byBranch = Leaderboards.byGroup(
        report.all,
        LeaderboardDimension.branch,
      );
      expect(byBranch.keys.toSet(), {'Head Office', 'Ketu'});
      expect(byBranch['Ketu']!.first.metrics.employeeId, 'ops0');

      final byRole = Leaderboards.byGroup(
        report.all,
        LeaderboardDimension.role,
      );
      expect(byRole.keys.toSet(), {'HR Officer', 'Loan Officer'});
      expect(byRole['HR Officer']!.first.metrics.employeeId, 'hr0');

      final byDept = Leaderboards.byGroup(
        report.all,
        LeaderboardDimension.department,
      );
      expect(byDept.keys.toSet(), {'Human Resources', 'Operations'});
      expect(byDept['Human Resources']!.first.metrics.employeeId, 'hr0');
    });

    test('the report exposes the branches, roles and departments present', () {
      final report = reportWith(employees: 2);
      expect(report.branches, ['Head Office']);
      expect(report.positions, ['Officer']);
      expect(report.departments, ['Operations']);
    });

    test('rows outside the period are excluded entirely', () {
      // The server may return a slightly wider window; the report must not let
      // neighbouring months inflate the numbers.
      final report = StaffAnalyticsReport.fromRows(
        [
          row('e1', '2026-08-31'),
          row('e1', '2026-09-01'),
          row('e1', '2026-09-02'),
          row('e1', '2026-10-01'),
        ],
        september,
      );
      final m = report.byId('e1')!;

      expect(m.records, 2);
      expect(m.daysPresent, 2);
    });

    test('a period with no rows produces an empty report', () {
      final report = StaffAnalyticsReport.fromRows(const [], september);
      expect(report.all, isEmpty);
      expect(report.scored, isEmpty);
    });

    test('employees are matched by name when the row has no id', () {
      // Legacy rows may lack employee_id; they must still aggregate rather than
      // being dropped from the board entirely.
      final report = StaffAnalyticsReport.fromRows(
        [
          for (var d = 1; d <= 3; d++)
            AttendanceManagementRow(
              attendanceId: 'x$d',
              employeeName: 'Legacy Person',
              attendanceDate: '2026-09-0$d',
              clockIn: '2026-09-0${d}T08:00:00Z',
              clockOut: '2026-09-0${d}T17:00:00Z',
              workHours: 8,
            ),
        ],
        september,
      );

      expect(report.all.length, 1);
      expect(report.all.first.employeeName, 'Legacy Person');
      expect(report.all.first.daysPresent, 3);
    });
  });
}
