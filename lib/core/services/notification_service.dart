import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/routing/app_router.dart';
import '../../features/dashboard/home_shell.dart';
import '../../shared/models/models.dart';

/// Local notification capability.
///
/// Push from the server would require FCM/APNs credentials configured in a
/// Supabase Edge Function — that is out of scope for the client. Local
/// notifications are used for in-app events (clock-in/out confirmations,
/// SARA replies) and tapping a notification routes to the relevant screen.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _android = AndroidInitializationSettings('@mipmap/ic_launcher');
  bool _ready = false;

  /// Map of notification id → route.
  static const _routeKey = 'route';

  /// Fixed ids for the daily clock-in / clock-out reminders.
  static const reminderClockInId = 901;
  static const reminderClockOutId = 902;

  /// Quick action title shown on reminder notifications.
  static const quickClockInAction = 'quick_clock_in';

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    final settings = InitializationSettings(
      android: _android,
      iOS: darwinInit,
      macOS: darwinInit,
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onTap,
    );
    _ready = true;
  }

  Future<void> requestPermissions() async {
    await init();
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Permission prompting unsupported on this platform.
    }
  }

  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? route,
  }) async {
    await init();
    try {
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'infinitycore',
            'InfinityCore',
            channelDescription: 'Attendance and operational alerts',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_launcher',
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        payload: route == null ? null : '{"$_routeKey":"$route"}',
      );
    } catch (_) {
      // Local notification unavailable (e.g. disabled).
    }
  }

  void _onTap(NotificationResponse? response) {
    if (response?.actionId == quickClockInAction) {
      appRouter.go('/home');
      HomeShell.requestTab.value = 'attendance';
      return;
    }
    final payload = response?.payload;
    if (payload == null) return;
    String? route;
    try {
      final decoded = jsonDecode(payload) as Map<String, dynamic>?;
      route = decoded?[_routeKey]?.toString();
    } catch (_) {}
    if (route != null && route.isNotEmpty) {
      appRouter.go(route);
    }
  }

  /// Schedule the next clock-in / clock-out reminder in [location] timezone.
  /// One-shot (not repeating) so reminders stop once the action is done and
  /// are re-armed on the next app open / attendance change via
  /// [ReminderService.sync].
  ///
  /// Skips the clock-in reminder when already clocked in today and the
  /// clock-out reminder when not clocked in (or already out) — the alarm stays
  /// relevant instead of nagging.
  Future<void> scheduleReminders(
    ReminderSettings settings,
    tz.Location location, {
    required bool clockedInToday,
    required bool clockedOutToday,
  }) async {
    await init();
    await cancelReminders();
    if (!settings.enabled) return;

    final partsIn = _hhmm(settings.clockInTime);
    final partsOut = _hhmm(settings.clockOutTime);

    if (!clockedInToday && partsIn != null) {
      await _scheduleOne(
        id: reminderClockInId,
        title: 'Time to clock in',
        body: 'Record your clock-in while you are at your approved location.',
        when: _nextAt(location, partsIn.$1, partsIn.$2),
      );
    }
    if (clockedInToday && !clockedOutToday && partsOut != null) {
      await _scheduleOne(
        id: reminderClockOutId,
        title: 'Time to clock out',
        body: 'Remember to clock out before you leave your approved location.',
        when: _nextAt(location, partsOut.$1, partsOut.$2),
      );
    }
  }

  Future<void> _scheduleOne({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime when,
  }) async {
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        when,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'infinitycore',
            'InfinityCore',
            channelDescription: 'Attendance and operational alerts',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_launcher',
            playSound: true,
            enableVibration: true,
            actions: [
              AndroidNotificationAction(
                quickClockInAction,
                'Clock in now',
                showsUserInterface: true,
              ),
            ],
          ),
          iOS: DarwinNotificationDetails(
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (_) {
      // Scheduled notifications unavailable (permissions or platform limits).
    }
  }

  /// Next occurrence of [hour]:[minute] strictly in the future.
  tz.TZDateTime _nextAt(tz.Location location, int hour, int minute) {
    final now = tz.TZDateTime.now(location);
    var next = tz.TZDateTime(
      location,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (!next.isAfter(now)) {
      next = tz.TZDateTime(
        location,
        now.year,
        now.month,
        now.day + 1,
        hour,
        minute,
      );
    }
    return next;
  }

  (int, int)? _hhmm(String value) {
    final m = RegExp(r'^([01][0-9]|2[0-3]):([0-5][0-9])$').firstMatch(value);
    if (m == null) return null;
    return (int.parse(m[1]!), int.parse(m[2]!));
  }

  Future<void> cancelReminders() async {
    await init();
    await _plugin.cancel(reminderClockInId);
    await _plugin.cancel(reminderClockOutId);
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}

/// Helpers that centralize notification-side navigation.
void notifyAndGo({
  required int id,
  required String title,
  required String body,
  String? route,
}) {
  NotificationService.instance.show(
    id: id,
    title: title,
    body: body,
    route: route,
  );
  if (route != null) {
    // Handled by tap handler; no automatic navigation here.
  }
}

void notifyMessenger(String message) {
  final messenger = rootScaffoldMessengerKey.currentState;
  messenger?.showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}
