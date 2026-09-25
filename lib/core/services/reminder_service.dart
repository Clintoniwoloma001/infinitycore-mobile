import 'package:flutter/widgets.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../features/attendance/attendance_service.dart';
import '../config/env.dart';
import '../diagnostics/auth_trace.dart';
import 'notification_service.dart';
import 'supabase_service.dart';

/// Clock-in / clock-out reminder alarms.
///
/// The app has no FCM/APNs credentials, so these are LOCAL scheduled
/// notifications driven by the HR-configured times on the server
/// (`mobile_reminder_settings_get`). Scheduling is re-armed on sign-in,
/// app start, and after every attendance write so reminders stop once the
/// corresponding punch is recorded.
class ReminderService with WidgetsBindingObserver {
  ReminderService._();

  static final ReminderService instance = ReminderService._();

  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);

    // Re-arm when the session changes (login/logout/binding).
    SupabaseService.client.auth.onAuthStateChange.listen((_) {
      sync();
    });
    // Initial sync for a restored session.
    sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      sync();
    }
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
      AuthTrace.log(
        'reminder.sync',
        'scheduled: clockIn=${settings.clockInTime} '
            'clockOut=${settings.clockOutTime} enabled=${settings.enabled} '
            'clockedInToday=$clockedInToday clockedOutToday=$clockedOutToday '
            'tz=${req.appTimezone}',
      );
    } catch (e, st) {
      // A failed reminder sync must never break app startup or login — but it
      // must not be silent either, otherwise a broken reminder system looks
      // identical to a working one from the outside.
      AuthTrace.log('reminder.sync', 'FAILED: $e\n$st');
      debugPrint('ReminderService.sync failed: $e');
    }
  }
}
