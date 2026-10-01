import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/dashboard/dashboard_service.dart';
import 'package:infinitycore/shared/models/models.dart';

/// Month filtering for the staff dashboard's four metric cards.
///
/// The cards were previously always scoped to the current calendar month with no
/// way to look back, so "Late days" and "Hours this month" could only ever mean
/// one month. These tests pin the filtered behaviour, including the month
/// boundary cases that a naive year/month comparison gets wrong.
void main() {
  // 15 March 2026, midday - mid-month so both bounds are exercised.
  final now = DateTime(2026, 3, 15, 12);
  final march = DateTime(2026, 3);
  final february = DateTime(2026, 2);

  AttendanceRecord record(String date, {int lateMinutes = 0, double hours = 8}) =>
      AttendanceRecord(
        id: date,
        employeeId: 'e1',
        attendanceDate: date,
        clockIn: '${date}T08:00:00Z',
        clockOut: '${date}T17:00:00Z',
        workHours: hours,
        lateMinutes: lateMinutes,
      );

  group('DashboardMetrics honours the selected month', () {
    test('counts only the selected month', () {
      final records = [
        record('2026-03-02', hours: 8),
        record('2026-03-03', hours: 8),
        record('2026-03-04', lateMinutes: 10),
        record('2026-02-10', hours: 8),
        record('2026-02-11', hours: 8),
        record('2026-02-12', hours: 8),
      ];

      final mar = DashboardMetrics.fromRecords(records, now: now, month: march);
      expect(mar.daysPresent, 3);
      expect(mar.totalHours, 24);
      expect(mar.lateDays, 1);

      final feb = DashboardMetrics.fromRecords(records, now: now, month: february);
      expect(feb.daysPresent, 3);
      expect(feb.totalHours, 24);
      expect(feb.lateDays, 0, reason: 'February had no late days');
    });

    test('omitting the month keeps the original current-month behaviour', () {
      // Back-compat: callers that never pass `month` must still get the
      // current month, which is what the cards showed before the filter.
      final records = [record('2026-03-02'), record('2026-02-10')];

      final metrics = DashboardMetrics.fromRecords(records, now: now);
      expect(metrics.daysPresent, 1);
    });

    test('a month with no records reads as zero, not as stale data', () {
      final metrics = DashboardMetrics.fromRecords(
        [record('2026-03-02')],
        now: now,
        month: DateTime(2025, 11),
      );

      expect(metrics.daysPresent, 0);
      expect(metrics.totalHours, 0);
      expect(metrics.lateDays, 0);
      // A zero-day month must not claim a perfect on-time rate.
      expect(metrics.onTimeRate, 0);
    });

    test('a January selection does not silently match December', () {
      // The bug a naive `month == 12 ? previous-year++` shortcut introduces.
      final records = [record('2026-01-05'), record('2025-12-05')];

      final jan = DashboardMetrics.fromRecords(
        records,
        now: now,
        month: DateTime(2026, 1),
      );
      expect(jan.daysPresent, 1);

      final dec = DashboardMetrics.fromRecords(
        records,
        now: now,
        month: DateTime(2025, 12),
      );
      expect(dec.daysPresent, 1);
    });

    test('the same day in a different year is a different day', () {
      final records = [record('2025-03-05')];
      final metrics = DashboardMetrics.fromRecords(
        records,
        now: now,
        month: DateTime(2026, 3),
      );
      expect(metrics.daysPresent, 0);
    });

    test('two records on one day count as one present day', () {
      // Guards against double-counting when history has duplicate rows for a
      // date (e.g. a corrected clock-in).
      final records = [
        record('2026-03-02', hours: 8),
        record('2026-03-02', hours: 8),
      ];

      final metrics = DashboardMetrics.fromRecords(records, now: now, month: march);
      expect(metrics.daysPresent, 1);
    });

    test('a day with no clock-in contributes no hours', () {
      final metrics = DashboardMetrics.fromRecords(
        [
          AttendanceRecord(
            id: 'x',
            employeeId: 'e1',
            attendanceDate: '2026-03-02',
            workHours: 0,
            lateMinutes: 0,
          ),
        ],
        now: now,
        month: march,
      );

      expect(metrics.totalHours, 0);
    });

    test('unparseable dates are skipped rather than crashing', () {
      final metrics = DashboardMetrics.fromRecords(
        [record('2026-03-02'), record('not-a-date')],
        now: now,
        month: march,
      );

      expect(metrics.daysPresent, 1);
    });
  });
}
