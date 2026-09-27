import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Unread counts behind the app-bar notification bell.
///
/// Official `notifications` rows and unread chat messages are counted
/// separately: chat unread already lives in `MessagingHub.unreadTotal`, while
/// this class owns the `notifications` table. Keeping them apart lets the bell
/// say what is actually waiting instead of showing one unexplained number.
class NotificationBadge {
  NotificationBadge._();

  static final NotificationBadge instance = NotificationBadge._();

  /// Unread rows in `notifications` for the signed-in user.
  final ValueNotifier<int> unreadNotifications = ValueNotifier<int>(0);

  RealtimeChannel? _channel;
  Timer? _timer;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await refresh();
    // Realtime pushes most changes; the timer only covers a dropped socket.
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => refresh());
    try {
      _channel = SupabaseService.client
          .channel('notification_badge')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'notifications',
            callback: (_) => refresh(),
          )
          .subscribe();
    } catch (_) {
      // Realtime is a nicety here — the periodic refresh keeps the badge
      // roughly current when the socket cannot be established.
    }
  }

  Future<void> refresh() async {
    try {
      final user = SupabaseService.client.auth.currentUser;
      if (user == null) {
        unreadNotifications.value = 0;
        return;
      }
      final rows = await SupabaseService.client
          .from('notifications')
          .select('id')
          .eq('user_id', user.id)
          .eq('read', false);
      unreadNotifications.value = (rows as List<dynamic>? ?? []).length;
    } catch (_) {
      // A badge is never worth surfacing an error for.
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(channel.unsubscribe());
    unreadNotifications.value = 0;
    _started = false;
  }
}
