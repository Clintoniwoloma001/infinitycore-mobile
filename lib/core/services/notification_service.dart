import 'dart:convert';
import 'dart:typed_data';

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

/// How well the clock-in/out alarm can actually be delivered on this device.
///
/// The clock-in reminder is only trustworthy if it is *alarm grade*: posting on
/// the alarm channel with exact-alarm access. Any other state means it can be
/// silenced or delayed, so it is recorded and surfaced rather than left to fail
/// silently — a broken reminder must not look identical to a working one.
enum ReminderDeliveryStatus {
  /// Not evaluated yet (before the first permission pass).
  unknown,

  /// Alarm channel live plus exact-alarm access — sounds in silent/DND.
  alarmGrade,

  /// Notifications or exact-alarm access is missing; delivery is best-effort.
  degraded,

  /// Notifications are switched off entirely; nothing will be shown.
  blocked,
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _android = AndroidInitializationSettings('ic_launcher_foreground');
  bool _ready = false;

  /// Delivery capability of the clock-in/out alarm on this device. Bumped
  /// whenever the channel or permissions are (re)evaluated so the UI can warn
  /// about a degraded reminder instead of the user silently missing it.
  static final ValueNotifier<ReminderDeliveryStatus> deliveryStatus =
      ValueNotifier<ReminderDeliveryStatus>(ReminderDeliveryStatus.unknown);

  /// Map of notification id → route.
  static const _routeKey = 'route';

  /// Fixed ids for the daily clock-in / clock-out reminders.
  static const reminderClockInId = 901;
  static const reminderClockOutId = 902;

  /// Android channel ids. Messaging and announcements are separated so a user
  /// can silence routine chat without losing official notices.
  static const channelMessages = 'infinitycore_messages';
  static const channelAnnouncements = 'infinitycore_announcements';
  static const channelId = 'infinitycore';

  /// Dedicated *alarm* channel for the clock-in / clock-out reminders.
  ///
  /// This is a deliberately NEW channel id rather than a tweak to
  /// [channelId]: Android freezes a channel's importance, sound and audio
  /// usage at creation time, so an existing channel can never be upgraded to
  /// alarm behaviour. The old channel stays for routine notices; reminders
  /// move here.
  ///
  /// The decisive setting is `audioAttributesUsage: AudioAttributesUsage.alarm`
  /// (Android `AudioAttributes.USAGE_ALARM`). It routes playback through the
  /// device's *alarm* volume stream, which is what lets the reminder sound
  /// while the phone is on silent or vibrate — a channel using the default
  /// `notification` usage is suppressed in both. This is the same channel
  /// shape alarm-clock and reminder apps use. It cannot be substituted with a
  /// louder normal notification.
  static const channelReminders = 'infinitycore_reminders_alarm';

  static const AndroidNotificationChannel _reminderChannel =
      AndroidNotificationChannel(
        channelReminders,
        'Clock-in and clock-out alarms',
        description:
            'Audible, unavoidable clock-in and clock-out reminders. Plays '
            'through the alarm volume stream so it still sounds in silent and '
            'vibrate mode.',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
      );

  /// `FLAG_INSISTENT` — repeats the alarm sound until the user responds.
  static const int _flagInsistent = 4;

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
    // Register the alarm channel up front so a reminder scheduled later can
    // never land on a channel that does not exist yet (which would silently
    // fall back to default-importance behaviour).
    await _ensureReminderChannel();
    _ready = true;

    // Handle a notification action that cold-started the app. The attendance
    // screen consumes the queued action after the router has mounted.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      _onTap(launch?.notificationResponse);
    }
  }

  /// Request notification, exact-alarm and full-screen-intent access before
  /// reminders are armed.
  ///
  /// Android 13+ requires POST_NOTIFICATIONS at runtime. Android 12+ requires
  /// exact-alarm access so the alarm fires on the HR-configured minute rather
  /// than "soon after". Android 14+ additionally gates `USE_FULL_SCREEN_INTENT`
  /// to alarm/calling apps — this app's reminder *is* the alarm use case, so
  /// the permission is declared in the manifest and exercised here.
  ///
  /// The resulting capability is recorded in [deliveryStatus] so a degraded
  /// alarm is visible rather than silent.
  Future<bool> requestPermissions() async {
    await init();
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) {
        // Non-Android: Darwin initialisation already requested its own
        // alert/sound permissions, and there is no alarm-stream equivalent to
        // verify.
        deliveryStatus.value = ReminderDeliveryStatus.alarmGrade;
        return true;
      }

      final notifications = await android.requestNotificationsPermission();
      if (notifications == false) {
        debugPrint(
          'InfinityCore notifications are disabled; the clock-in alarm cannot '
          'be shown at all. Enable notifications for InfinityCore in system '
          'settings.',
        );
        deliveryStatus.value = ReminderDeliveryStatus.blocked;
        return false;
      }

      final exactAlarms = await android.requestExactAlarmsPermission();
      if (exactAlarms == false) {
        debugPrint(
          'InfinityCore exact-alarm access is disabled; the clock-in alarm '
          'will still sound (alarm channel) but may fire late.',
        );
        deliveryStatus.value = ReminderDeliveryStatus.degraded;
        return false;
      }

      // Confirm the channel really carries alarm audio usage. If channel
      // creation failed, the reminder is only a normal notification and the
      // user needs to know.
      final channelReady = await _ensureReminderChannel();
      deliveryStatus.value = channelReady
          ? ReminderDeliveryStatus.alarmGrade
          : ReminderDeliveryStatus.degraded;
      debugPrint(
        '[notification.delivery] alarm-grade=${channelReady && exactAlarms != false} '
        'channelReady=$channelReady notifications=$notifications '
        'exactAlarms=$exactAlarms',
      );
      return channelReady;
    } catch (error, stack) {
      debugPrint('Notification permission request failed: $error\n$stack');
      deliveryStatus.value = ReminderDeliveryStatus.degraded;
      return false;
    }
  }

  /// Creates (or re-confirms) the alarm channel. Returns false when the channel
  /// could not be registered, which means reminders would degrade to a normal
  /// notification.
  Future<bool> _ensureReminderChannel() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return true;
      await android.createNotificationChannel(_reminderChannel);
      return true;
    } catch (error) {
      debugPrint(
        'Could not create the reminder alarm channel; reminders will fall back '
        'to normal-notification behaviour: $error',
      );
      return false;
    }
  }

  /// Shows an immediate in-app notification through the existing local
  /// notification system.
  ///
  /// [channel] selects the Android channel (routine messages vs official
  /// announcements) and [highPriority] controls heads-up behaviour. Both
  /// default to the existing InfinityCore channel, so pre-existing callers —
  /// attendance, SARA, reminders — behave exactly as before.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? route,
    String channel = channelId,
    bool highPriority = false,
  }) async {
    await init();
    try {
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channel,
            channel == channelAnnouncements
                ? 'Announcements'
                : channel == channelMessages
                ? 'Messages'
                : 'InfinityCore',
            channelDescription:
                'Messages, announcements and operational alerts',
            importance: highPriority
                ? Importance.high
                : Importance.defaultImportance,
            priority: highPriority ? Priority.high : Priority.defaultPriority,
            icon: 'ic_launcher_foreground',
          ),
          iOS: DarwinNotificationDetails(
            interruptionLevel: highPriority
                ? InterruptionLevel.timeSensitive
                : InterruptionLevel.active,
          ),
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
    // Alarm-grade presentation. These settings only work together:
    //  * the alarm channel (`audioAttributesUsage: alarm` on the channel) so the
    //    sound is played on the *alarm* volume stream, which Android does not
    //    silence in silent/vibrate mode — a `notification`-usage channel is
    //    suppressed in both;
    //  * `audioAttributesUsage: alarm` on the post itself, so the same usage
    //    applies even if the channel was created by an older build;
    //  * `category: alarm` + `fullScreenIntent` so it presents over the lock
    //    screen like a real alarm instead of waiting quietly in the shade;
    //  * `max` importance/priority, which is what permits the heads-up alert.
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _reminderChannel.id,
        _reminderChannel.name,
        channelDescription: _reminderChannel.description,
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        fullScreenIntent: true,
        icon: 'ic_launcher_foreground',
        playSound: true,
        enableVibration: true,
        // An alarm must not be swiped away accidentally, and should keep
        // sounding until it is dealt with.
        ongoing: true,
        autoCancel: false,
        additionalFlags: Int32List.fromList(const [_flagInsistent]),
        ticker: title,
        visibility: NotificationVisibility.public,
        actions: [
          AndroidNotificationAction(
            actionId,
            actionTitle,
            showsUserInterface: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        // `critical` requires Apple's special entitlement; `timeSensitive` is
        // the highest level a standard app may use and still breaks through
        // Focus modes.
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
  ///
  /// Weekends are skipped unconditionally, in addition to (not instead of) the
  /// HR-configured schedule. The clock-in/out reminder is a working-day alarm,
  /// so a Saturday/Sunday slot is never armed no matter what the server
  /// settings say.
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
      next = _shiftDays(location, next, 1, hour, minute);
    }
    while (isWeekendDay(next)) {
      next = _shiftDays(location, next, 1, hour, minute);
    }
    return next;
  }

  /// Moves [from] forward by [days] and re-pins the wall-clock time.
  ///
  /// Rebuilding the [tz.TZDateTime] from year/month/day rather than adding a
  /// `Duration` keeps the alarm on the intended wall-clock minute across a DST
  /// transition.
  tz.TZDateTime _shiftDays(
    tz.Location location,
    tz.TZDateTime from,
    int days,
    int hour,
    int minute,
  ) {
    final shifted = tz.TZDateTime(
      location,
      from.year,
      from.month,
      from.day + days,
      hour,
      minute,
    );
    return shifted;
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

/// True on Saturday or Sunday.
///
/// The clock-in/clock-out reminder is a working-day alarm. This predicate gates
/// scheduling *in addition to* the HR-configured times, so a weekend slot is
/// never armed regardless of what the server settings say. Public and pure so
/// the rule is unit-testable without a platform channel.
bool isWeekendDay(DateTime date) =>
    date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;

/// Next working-day occurrence of [hour]:[minute] strictly after [from].
///
/// Mirrors the scheduling logic in `NotificationService._nextAt` so the
/// weekday-only rule can be asserted directly in tests.
DateTime nextWeekdayOccurrence(DateTime from, int hour, int minute) {
  var candidate = DateTime(from.year, from.month, from.day, hour, minute);
  if (!candidate.isAfter(from)) {
    candidate = DateTime(from.year, from.month, from.day + 1, hour, minute);
  }
  while (isWeekendDay(candidate)) {
    candidate = DateTime(
      candidate.year,
      candidate.month,
      candidate.day + 1,
      hour,
      minute,
    );
  }
  return candidate;
}

