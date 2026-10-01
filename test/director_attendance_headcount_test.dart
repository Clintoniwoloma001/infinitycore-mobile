import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/director/director_service.dart';

/// The "Absent 4220" incident, pinned.
///
/// The server's `summary.absent` is `SUM(expected_days) - SUM(attendance_present)`
/// where `expected_days` is a flat 20 per employee that does NOT scale with the
/// requested window. On the 211-person production roster for a window where
/// nobody had registered attendance that is 211 x 20 = 4220, which rendered as
/// "Absent 4220" and read as "4220 people are absent" on a 211-person roster.
///
/// [AttendanceTotals] is what the executive home tiles must use instead: a
/// STAFF headcount. These tests stop the day-count from ever reaching the
/// director home screen again.
void main() {
  group('Director attendance headcounts count PEOPLE, not days', () {
    // Mirrors the production shape: 211 staff, each expected 20 days.
    final roster211 = <Map<String, dynamic>>[
      for (var i = 0; i < 211; i++)
        <String, dynamic>{
          'expected_days': 20,
          // 40 people clocked in that day; the rest did not.
          'attendance_present': i < 40 ? 1 : 0,
        },
    ];

    test('never reports more absent staff than exist on the roster', () {
      final totals = AttendanceTotals.fromStaff(roster211);

      expect(totals.totalStaff, 211);
      expect(
        totals.absentStaff,
        lessThanOrEqualTo(totals.totalStaff),
        reason: 'a headcount cannot exceed the roster',
      );
      expect(totals.absentStaff, 171); // 211 - 40 who attended
      expect(totals.presentStaff, 40);
    });

    test('the raw day total is what produced the impossible 4220', () {
      // The exact production incident: a window where nobody had registered
      // attendance yet, so `expected - present` collapses to the full expected
      // total = 211 x 20 = 4220. Asserted so the discrepancy is documented
      // rather than folklore. If someone "simplifies" the service back to
      // `expected - present`, this is the number that reappears.
      final noAttendanceYet = <Map<String, dynamic>>[
        for (var i = 0; i < 211; i++)
          {'expected_days': 20, 'attendance_present': 0},
      ];

      var expected = 0;
      var present = 0;
      for (final p in noAttendanceYet) {
        expected += (p['expected_days']! as num).toInt();
        present += (p['attendance_present']! as num).toInt();
      }
      expect(expected - present, 4220);
      expect(
        expected - present,
        greaterThan(noAttendanceYet.length),
        reason: 'why the day-count read as an impossible headcount',
      );

      // The headcount for the same roster stays inside the organisation.
      final totals = AttendanceTotals.fromStaff(noAttendanceYet);
      expect(totals.absentStaff, 211);
      expect(totals.absentStaff, lessThanOrEqualTo(totals.totalStaff));
    });

    test('present and absent always partition the roster', () {
      final totals = AttendanceTotals.fromStaff(roster211);

      expect(
        totals.presentStaff + totals.absentStaff,
        totals.totalStaff,
        reason: 'every employee is either present or absent, never both',
      );
    });

    test('a partly-attending person is not counted as absent', () {
      // Someone who worked 1 of 5 expected days has attended; counting them as
      // absent would overstate absence.
      final totals = AttendanceTotals.fromStaff([
        {'expected_days': 5, 'attendance_present': 1},
        {'expected_days': 5, 'attendance_present': 0},
      ]);

      expect(totals.presentStaff, 1);
      expect(totals.absentStaff, 1);
    });

    test('an empty or partial payload yields zero, not a crash', () {
      // A snapshot that failed to load staff must still render the tiles.
      expect(AttendanceTotals.fromStaff(const []).absentStaff, 0);
      expect(AttendanceTotals.fromStaff(const []).presentStaff, 0);

      final partial = AttendanceTotals.fromStaff([
        <String, dynamic>{}, // missing both fields
      ]);
      expect(partial.totalStaff, 1);
      expect(partial.absentStaff, 1);
    });

    test('absent days never go negative when the server over-reports', () {
      final totals = AttendanceTotals.fromStaff([
        {'expected_days': 2, 'attendance_present': 9},
      ]);

      expect(totals.absentDays, 0);
      expect(totals.presentStaff, 1);
    });

    test('attendance rate is zero when nothing was expected', () {
      // Guards a divide-by-zero rendering as NaN or a bogus 100%.
      final totals = AttendanceTotals.fromStaff([
        {'expected_days': 0, 'attendance_present': 0},
      ]);

      expect(totals.rate, 0);
    });
  });
}