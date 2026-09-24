import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../features/attendance/attendance_service.dart';
import '../config/env.dart';
import 'notification_service.dart';
import 'supabase_service.dart';

/// Clock-in / clock-out reminder alarms.
///
/// The app has no FCM/APNs credentials, so these are LOCAL scheduled
/// notifications driven by the HR-configured times on the server
/// (`mobile_reminder_settings_get`). Scheduling is re-armed on sign-in,
/// app start, and after every attendance write so reminders stop once the
/// corresponding punch is recorded.
class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();

  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    // Re-arm when the session changes (login/logout/binding).
    SupabaseService.client.auth.onAuthStateChange.listen((_) {
      sync();
    });
    // Initial sync for a restored session.
    sync();
  }

  Future<void> sync() async {
    final session = SupabaseService.client.auth.currentSession;
    if (session == null) {
      await NotificationService.instance.cancelReminders();
      return;
    }
    try {
      if (!Env.isConfigured) return;
      final settings = await AttendanceService.instance.getReminderSettings();
      final req = await AttendanceService.instance.getAttendanceRequirements();
      tzdata.initializeTimeZones();
      var location = tz.getLocation(req.appTimezone);

      bool clockedInToday = false;
      bool clockedOutToday = false;
      try {
        final employee = await AttendanceService.instance.getMyEmployee();
        if (employee != null) {
          final today = await AttendanceService.instance.getToday(employee.id);
          clockedInToday = today != null && today.isClockedIn;
          if (today != null) {
            clockedOutToday =
                today.clockOut != null && today.clockOut!.isNotEmpty;
          }
        }
      } catch (_) {}

      await NotificationService.instance.scheduleReminders(
        settings,
        location,
        clockedInToday: clockedInToday,
        clockedOutToday: clockedOutToday,
      );
    } catch (_) {
      // A failed reminder sync must never break app startup or login.
    }
  }
}
