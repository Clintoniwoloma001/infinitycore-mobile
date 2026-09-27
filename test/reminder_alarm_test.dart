import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/services/notification_service.dart';

void main() {
  group('isWeekendDay', () {
    test('identifies Saturday and Sunday as weekend', () {
      // 2026-09-26 is a Saturday
      final saturday = DateTime(2026, 9, 26, 8, 30);
      // 2026-09-27 is a Sunday
      final sunday = DateTime(2026, 9, 27, 9, 0);

      expect(isWeekendDay(saturday), isTrue);
      expect(isWeekendDay(sunday), isTrue);
    });

    test('identifies weekdays as non-weekend', () {
      // 2026-09-21 (Mon) to 2026-09-25 (Fri)
      for (var day = 21; day <= 25; day++) {
        final weekday = DateTime(2026, 9, day, 8, 0);
        expect(isWeekendDay(weekday), isFalse, reason: 'Failed for day $day');
      }
    });
  });

  group('nextWeekdayOccurrence', () {
    test('schedules for today if time is strictly in the future on a weekday', () {
      // Monday 2026-09-21 at 07:00 -> target 08:30
      final mondayMorning = DateTime(2026, 9, 21, 7, 0);
      final next = nextWeekdayOccurrence(mondayMorning, 8, 30);

      expect(next, DateTime(2026, 9, 21, 8, 30));
    });

    test('schedules for next day if target time today has already passed on a weekday', () {
      // Monday 2026-09-21 at 09:00 -> target 08:30 -> should be Tuesday 2026-09-22 08:30
      final mondayPast = DateTime(2026, 9, 21, 9, 0);
      final next = nextWeekdayOccurrence(mondayPast, 8, 30);

      expect(next, DateTime(2026, 9, 22, 8, 30));
    });

    test('skips from Friday afternoon to Monday morning', () {
      // Friday 2026-09-25 at 18:30 -> target 08:30 -> Saturday & Sunday skipped -> Monday 2026-09-28 08:30
      final fridayEvening = DateTime(2026, 9, 25, 18, 30);
      final next = nextWeekdayOccurrence(fridayEvening, 8, 30);

      expect(next, DateTime(2026, 9, 28, 8, 30));
      expect(next.weekday, DateTime.monday);
    });

    test('skips from Saturday or Sunday to Monday morning', () {
      // Saturday 2026-09-26 at 10:00 -> target 08:30 -> Monday 2026-09-28 08:30
      final saturday = DateTime(2026, 9, 26, 10, 0);
      final nextFromSat = nextWeekdayOccurrence(saturday, 8, 30);
      expect(nextFromSat, DateTime(2026, 9, 28, 8, 30));

      // Sunday 2026-09-27 at 06:00 -> target 08:30 -> Monday 2026-09-28 08:30
      final sunday = DateTime(2026, 9, 27, 6, 0);
      final nextFromSun = nextWeekdayOccurrence(sunday, 8, 30);
      expect(nextFromSun, DateTime(2026, 9, 28, 8, 30));
    });

    test('maintains identical wall-clock hour and minute', () {
      final from = DateTime(2026, 9, 25, 20, 0);
      final next = nextWeekdayOccurrence(from, 17, 15);

      expect(next.hour, 17);
      expect(next.minute, 15);
      expect(next.weekday, DateTime.monday);
    });
  });
}
