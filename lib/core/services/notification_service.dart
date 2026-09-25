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
enum NotificationQuickAction { clockIn, clockOut }

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _android = AndroidInitializationSettings('ic_launcher_foreground');
  bool _ready = false;

  /// Map of notification id → route.
  static const _routeKey = 'route';

  /// Fixed ids for the daily clock-in / clock-out reminders.
  static const reminderClockInId = 901;
  static const reminderClockOutId = 902;

  /// Actions shown on reminder notifications.
  static const quickClockInAction = 'quick_clock_in';
  static const quickClockOutAction = 'quick_clock_out';

  /// Attendance listens to this notifier so an action can run the real,
  /// geofence-checked punch path rather than merely opening the tab.
  static final ValueNotifier<int> quickActionChanged = ValueNotifier<int>(0);
  static NotificationQuickAction? _pendingQuickAction;

  static NotificationQuickAction? takePendingQuickAction() {
    final action = _pendingQuickAction;
    _pendingQuickAction = null;
    return action;
  }

  static void _queueQuickAction(NotificationQuickAction action) {
    _pendingQuickAction = action;
    quickActionChanged.value++;
  }

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

    // Handle a notification action that cold-started the app. The attendance
    // screen consumes the queued action after the router has mounted.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      _onTap(launch?.notificationResponse);
    }
  }

  /// Request notification and exact-alarm access before reminders are armed.
  /// Android 13+ requires POST_NOTIFICATIONS at runtime; Android 12+ requires
  /// exact-alarm access for the HR-configured minute.
  Future<bool> requestPermissions() async {
    await init();
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return true;
      final notifications = await android.requestNotificationsPermission();
      final exactAlarms = await android.requestExactAlarmsPermission();
      if (notifications == false) {
        debugPrint(
          'InfinityCore notifications are disabled; reminders cannot be shown.',
        );
      }
      if (exactAlarms == false) {
        debugPrint(
          'InfinityCore exact-alarm access is disabled; reminders may be delayed.',
        );
      }
      return notifications != false && exactAlarms != false;
    } catch (error, stack) {
      debugPrint('Notification permission request failed: $error\n$stack');
      return false;
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
            icon: 'ic_launcher_foreground',
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
    final actionId = response?.actionId;
    if (actionId == quickClockInAction || actionId == quickClockOutAction) {
      _queueQuickAction(
        actionId == quickClockInAction
            ? NotificationQuickAction.clockIn
            : NotificationQuickAction.clockOut,
      );
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
      if (route == '/home') HomeShell.requestTab.value = 'attendance';
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
        actionId: quickClockInAction,
        actionTitle: 'Yes, clock in',
      );
    }
    if (clockedInToday && !clockedOutToday && partsOut != null) {
      await _scheduleOne(
        id: reminderClockOutId,
        title: 'Time to clock out',
        body: 'Remember to clock out before you leave your approved location.',
        when: _nextAt(location, partsOut.$1, partsOut.$2),
        actionId: quickClockOutAction,
        actionTitle: 'Yes, clock out',
      );
    }
  }

  Future<void> _scheduleOne({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime when,
    required String actionId,
    required String actionTitle,
  }) async {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'infinitycore',
        'InfinityCore',
        channelDescription: 'Attendance and operational alerts',
        importance: Importance.high,
        priority: Priority.high,
        icon: 'ic_launcher_foreground',
        playSound: true,
        enableVibration: true,
        actions: [
          AndroidNotificationAction(
            actionId,
            actionTitle,
            showsUserInterface: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: '{"$_routeKey":"/home"}',
      );
    } catch (error) {
      // rather than silently dropping the reminder.
      debugPrint('Exact reminder scheduling failed; using inexact: $error');
      try {
        await _plugin.zonedSchedule(
          id,
          title,
          body,
          when,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: '{"$_routeKey":"/home"}',
        );
      } catch (fallbackError, fallbackStack) {
        debugPrint(
          'Reminder scheduling failed: $fallbackError\n$fallbackStack',
        );
      }
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
