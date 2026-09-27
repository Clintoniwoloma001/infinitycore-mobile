import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/dashboard/home_shell.dart';

/// Where a notification came from, used to build a deep link when the
/// `notifications.link` column is missing or is a web-only URL.
///
/// The backend's `link` was written for the browser SPA and is frequently a
/// full `https://…/#/messages/…` URL, which means nothing to a mobile router.
/// Falling back to the notification's `type` plus the source id it carries is
/// what makes a tap open the *exact* record rather than the notification list.
enum NotificationSource {
  directMessage,
  channelMessage,
  groupMessage,
  announcement,
  attendance,
  leave,
  task,
  sara,
  unknown;

  static NotificationSource parse(String? raw) {
    final v = (raw ?? "").trim().toLowerCase();
    return switch (v) {
      'direct' || 'direct_message' || 'chat' || 'message' || 'dm' =>
        NotificationSource.directMessage,
      'channel' || 'channel_message' => NotificationSource.channelMessage,
      'group' || 'group_message' => NotificationSource.groupMessage,
      'announcement' || 'announcements' => NotificationSource.announcement,
      'attendance' || 'clock_in' || 'clock_out' => NotificationSource.attendance,
      'leave' || 'leave_request' => NotificationSource.leave,
      'task' || 'support_case' => NotificationSource.task,
      'sara' => NotificationSource.sara,
      _ => NotificationSource.unknown,
    };
  }
}

/// Resolves a notification into a mobile route.
///
/// Resolution order matters: an explicit, already-mobile `link` always wins
/// because it is the most specific instruction the sender gave. Only when
/// there is no usable link does the type/id fallback kick in, and that
/// fallback still targets a real screen rather than a dead end.
abstract final class NotificationDeepLink {
  /// Mobile route prefixes the router actually knows about.
  static const _knownPrefixes = <String>[
    '/home',
    '/messages',
    '/sara',
    '/notifications',
    '/profile',
    '/bound-devices',
    '/comm-admin',
    '/attendance-terminal',
    '/attendance-management',
  ];

  /// Returns the route to navigate to, or `null` when the notification has no
  /// meaningful destination.
  static String? resolve({
    String? type,
    String? link,
    String? sourceId,
  }) {
    final fromLink = _fromLink(link);
    if (fromLink != null) return fromLink;
    return _fromSource(NotificationSource.parse(type), sourceId);
  }

  /// Handles both a bare mobile path and the web SPA's `…/#/path` form.
  static String? _fromLink(String? link) {
    final raw = (link ?? "").trim();
    if (raw.isEmpty) return null;

    // `https://app.example.com/#/messages/abc` → `/messages/abc`.
    final hash = raw.indexOf('#/');
    final candidate = (hash >= 0 ? raw.substring(hash + 1) : raw).trim();
    if (candidate.isEmpty || !candidate.startsWith('/')) return null;

    final base = candidate.split('?').first;
    for (final prefix in _knownPrefixes) {
      if (base == prefix || base.startsWith('$prefix/')) return base;
    }
    return null;
  }

  /// Builds a route from the notification's own source descriptor.
  static String? _fromSource(NotificationSource source, String? sourceId) {
    final id = (sourceId ?? "").trim();
    switch (source) {
      case NotificationSource.announcement:
        return '/messages/announcements';
      case NotificationSource.directMessage:
        return id.isEmpty ? '/messages' : '/messages/$id';
      case NotificationSource.channelMessage:
        return id.isEmpty ? '/messages' : '/messages/channel/$id';
      case NotificationSource.groupMessage:
        return id.isEmpty ? '/messages' : '/messages/group/$id';
      case NotificationSource.attendance:
        HomeShell.requestTab.value = 'attendance';
        return '/home';
      case NotificationSource.leave:
        HomeShell.requestTab.value = 'leave';
        return '/home';
      case NotificationSource.task:
        return '/home';
      case NotificationSource.sara:
        return '/sara';
      case NotificationSource.unknown:
        return null;
    }
  }

  /// Navigates to the resolved route, ignoring unknown sources.
  static void open(
    BuildContext context, {
    String? type,
    String? link,
    String? sourceId,
  }) {
    final route = resolve(type: type, link: link, sourceId: sourceId);
    if (route == null) return;
    if (!context.mounted) return;
    if (route != '/home' && context.canPop()) {
      context.push(route);
    } else {
      context.go(route);
    }
  }
}
