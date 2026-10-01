import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/dashboard/dashboard_screen.dart';
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

  group('DashboardMonthFilter picks the month the user actually tapped', () {
    // This is the exact report: "I tapped September 2026 and every card was
    // still 0, even though there was data for September 2026".
    test('resolving September 2026 yields September 2026, not a far-future date', () {
      final resolved = DashboardMonthFilter.resolve(
        DateTime(2026, 10, 1),
        DateTime(2026, 9, 1),
      );

      expect(resolved.year, 2026);
      expect(resolved.month, 9);
    });

    test('a resolved month is never outside the range a human could pick', () {
      // Guards the class of bug: Dart silently normalises an out-of-range month
      // instead of throwing, so a year landing in the month slot produced the
      // year 2194 and silently matched no records.
      for (var m = 1; m <= 12; m++) {
        for (final year in [2024, 2025, 2026, 2027]) {
          final resolved = DashboardMonthFilter.resolve(
            DateTime(2026, 10, 1),
            DateTime(year, m, 1),
          );
          expect(resolved.year, year);
          expect(resolved.month, m);
          expect(
            resolved.year,
            inInclusiveRange(year - 1, year + 1),
            reason: 'year must not run away from the selected year',
          );
        }
      }
    });

    test('no selection means the current month', () {
      final now = DateTime(2026, 10, 1);
      expect(
        DashboardMonthFilter.resolve(now, null),
        DateTime(2026, 10),
      );
    });

    test('the selected year wins over the current year', () {
      // Tapping an older month must not fall back to the current year.
      final resolved = DashboardMonthFilter.resolve(
        DateTime(2026, 10, 1),
        DateTime(2025, 3, 1),
      );
      expect(resolved.year, 2025);
      expect(resolved.month, 3);
    });

    test('options walk backwards and roll over the year boundary', () {
      final options = DashboardMonthFilter.options(DateTime(2026, 2, 14));
      expect(options.length, 5);
      expect(options.first, DateTime(2026, 2));
      expect(options[1], DateTime(2026, 1));
      expect(options[2], DateTime(2025, 12));
      expect(options[3], DateTime(2025, 11));
    });

    test('options are strictly newest-first with no duplicates', () {
      final options = DashboardMonthFilter.options(
        DateTime(2026, 10, 1),
        depth: 12,
      );
      for (var i = 1; i < options.length; i++) {
        expect(options[i].isAfter(options[i - 1]), isFalse);
      }
      expect(options.toSet().length, options.length);
    });

    test('isCurrentMonth only matches the month now falls in', () {
      final now = DateTime(2026, 10, 1);
      expect(DashboardMonthFilter.isCurrentMonth(now, DateTime(2026, 10, 1)), isTrue);
      expect(DashboardMonthFilter.isCurrentMonth(now, DateTime(2026, 10, 28)), isTrue);
      expect(DashboardMonthFilter.isCurrentMonth(now, DateTime(2026, 9, 30)), isFalse);
      expect(DashboardMonthFilter.isCurrentMonth(now, DateTime(2025, 10, 1)), isFalse);
    });
  });

  group('the resolved month actually drives the metric cards', () {
    // The pure month maths and the metrics are separately correct, so the bug
    // only showed up in the seam between them. This test closes that gap by
    // feeding the REAL resolved month through the REAL metrics factory.
    test('tapping a month with data shows that month, not zero', () {
      final records = [
        record('2026-09-01'),
        record('2026-09-02'),
        record('2026-09-03', lateMinutes: 5),
        record('2026-10-01'),
      ];
      final now = DateTime(2026, 10, 1);

      final tapped = DateTime(2026, 9, 1);
      final resolved = DashboardMonthFilter.resolve(now, tapped);
      final metrics = DashboardMetrics.fromRecords(
        records,
        now: now,
        month: resolved,
      );

      expect(metrics.daysPresent, 3, reason: 'September has 3 records');
      expect(metrics.lateDays, 1);
      expect(metrics.totalHours, 24);

      // Switching back to the current month shows a different, also non-zero
      // set - proving the filter is genuinely re-scoping the data.
      final current = DashboardMonthFilter.resolve(now, null);
      final currentMetrics = DashboardMetrics.fromRecords(
        records,
        now: now,
        month: current,
      );
      expect(currentMetrics.daysPresent, 1);
    });

    test('every offered month is selectable and none silently reads zero', () {
      // Regression guard for the original symptom: with the broken selector,
      // every month except the one the arithmetic accidentally produced
      // resolved to a date nothing could match.
      final records = [for (var d = 1; d <= 20; d++) record('2026-09-${d.toString().padLeft(2, '0')}')];
      final now = DateTime(2026, 10, 1);

      for (final option in DashboardMonthFilter.options(now)) {
        final resolved = DashboardMonthFilter.resolve(now, option);
        final metrics = DashboardMetrics.fromRecords(
          records,
          now: now,
          month: resolved,
        );
        final hasSeptemberData = resolved.year == 2026 && resolved.month == 9;
        expect(
          metrics.daysPresent,
          hasSeptemberData ? 20 : 0,
          reason: 'unexpected day count for ${resolved.year}-${resolved.month}',
        );
      }
    });
  });
}
