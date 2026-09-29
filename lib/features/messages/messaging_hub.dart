import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/notification_service.dart';
import '../../core/services/supabase_service.dart';
import 'acknowledgement_service.dart';
import 'communication_service.dart';
import 'messages_service.dart';

/// A realtime change to a conversation, already normalised for the UI.
class MessagingEvent {
  const MessagingEvent({
    required this.type,
    required this.conversationId,
    required this.message,
    required this.isInsert,
  });

  /// `direct`, `group`, `channel` or `announcement`.
  final String type;
  final String conversationId;
  final Map<String, dynamic> message;
  final bool isInsert;

  /// Stable `type:id` key used for active-conversation suppression.
  String get key => '$type:$conversationId';
}

/// Process-wide bridge between Supabase Realtime and the messaging UI.
///
/// Design constraints this satisfies:
///  * **One subscription, not N.** A single channel listens for `chat_messages`
///    inserts/updates instead of one per open screen, so opening ten chats does
///    not create ten subscriptions. Per-conversation filtering happens in the
///    [MessagingEvent] consumers.
///  * **Web <-> mobile sync.** Both platforms write through the same tables and
///    read through Realtime, so a message sent on the web arrives here and vice
///    versa — no bespoke transport.
///  * **No duplicate messages.** Realtime can replay a row after a reconnect or
///    echo an optimistic local insert, so every incoming id passes through a
///    bounded LRU and is dropped if already seen.
///  * **No redundant push.** When the target conversation is on screen, or the
///    direct thread is muted, no local notification is raised — the in-app
///    realtime update *is* the notification.
class MessagingHub with WidgetsBindingObserver {
  MessagingHub._();
  static final MessagingHub instance = MessagingHub._();

  /// Total unread across every conversation. Drives the nav badge.
  final ValueNotifier<int> unreadTotal = ValueNotifier<int>(0);

  /// Incremented whenever a new message arrives, so open list screens can
  /// refresh without each holding their own subscription.
  final ValueNotifier<int> messageTick = ValueNotifier<int>(0);

  final _events = StreamController<MessagingEvent>.broadcast();
  Stream<MessagingEvent> get events => _events.stream;

  RealtimeChannel? _channel;
  StreamSubscription<dynamic>? _authSub;
  bool _started = false;
  bool _disposed = false;

  /// Conversation currently on screen, as `type:id`.
  String? _activeConversation;

  /// Recently seen message ids, to suppress duplicate realtime deliveries.
  final _seen = <String>{};
  static const _seenLimit = 400;

  /// Muted direct threads, refreshed alongside unread counts.
  final _mutedThreads = <String>{};

  String get _me => SupabaseService.client.auth.currentUser?.id ?? '';

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  /// Idempotent. Safe to call from `main()` and from any screen initState.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);

    // Follow sign-in/sign-out so a new account never inherits the previous
    // session's subscription, and logout cannot leak events to a screen.
    _authSub = SupabaseService.client.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.signedOut) {
        _teardownSubscription();
        _seen.clear();
        _mutedThreads.clear();
        unreadTotal.value = 0;
      } else if (event.event == AuthChangeEvent.signedIn) {
        _teardownSubscription();
        _seen.clear();
        _subscribe();
        unawaited(refresh());
      }
    });

    _subscribe();
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      // A backgrounded app can hold a dead socket. Recreating the channel and
      // flushing the outbox is more reliable than diagnosing the old one.
      _teardownSubscription();
      _subscribe();
      unawaited(refresh());
      unawaited(flushOutbox());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _teardownSubscription();
    }
  }

  // ------------------------------------------------------------------
  // Subscription
  // ------------------------------------------------------------------

  void _subscribe() {
    if (_disposed || _me.isEmpty) return;
    _teardownSubscription();
    _channel = SupabaseService.client
        .channel('messaging_hub')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_messages',
          callback: (payload) => _onRecord(
            Map<String, dynamic>.from(payload.newRecord),
            isInsert: true,
          ),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_messages',
          callback: (payload) => _onRecord(
            Map<String, dynamic>.from(payload.newRecord),
            isInsert: false,
          ),
        )
        .subscribe();
  }

  void _teardownSubscription() {
    final c = _channel;
    _channel = null;
    if (c != null) unawaited(c.unsubscribe());
  }

  bool _remember(String id) {
    if (id.isEmpty) return false;
    if (_seen.contains(id)) return false;
    _seen.add(id);
    while (_seen.length > _seenLimit) {
      _seen.remove(_seen.first);
    }
    return true;
  }

  void _onRecord(Map<String, dynamic> record, {required bool isInsert}) {
    if (_disposed) return;
    final me = _me;
    final senderId = '${record['sender_id'] ?? ''}';
    if (me.isEmpty || senderId == me) return;
    if (isInsert && !_remember('${record['id'] ?? ''}')) return;

    final type = _conversationTypeOf(record);
    final conversationId = _conversationIdOf(record);
    if (type == null || conversationId.isEmpty) return;

    final event = MessagingEvent(
      type: type,
      conversationId: conversationId,
      message: record,
      isInsert: isInsert,
    );
    if (!_events.isClosed) _events.add(event);

    if (isInsert) {
      messageTick.value++;
      if (_activeConversation != event.key) {
        unawaited(_notifyIncoming(event, record));
      }
    }
    unawaited(refreshUnread());
  }

  /// Raises a local notification only when it is warranted.
  Future<void> _notifyIncoming(
    MessagingEvent event,
    Map<String, dynamic> record,
  ) async {
    // Muted direct threads stay silent, matching the web notification
    // preference. Group/channel mute is not part of the existing schema.
    if (event.type == 'direct' &&
        _mutedThreads.contains(event.conversationId)) {
      return;
    }
    final isAnnouncement =
        '${record['message_type']}' == 'announcement' ||
        '${record['is_official']}' == 'true';
    final priority = '${record['priority'] ?? 'normal'}';
    final highPriority = isAnnouncement || priority == 'urgent';

    String sender = '';
    try {
      final dir = await CommunicationService.instance.resolveDirectory([
        '${record['sender_id']}',
      ]);
      final r = dir['${record['sender_id']}'];
      sender = '${r?['full_name'] ?? r?['email'] ?? ''}'.trim();
    } catch (_) {
      // Directory resolution is best effort; fall back to a generic label.
    }

    final title = isAnnouncement
        ? '${sender.isEmpty ? 'Announcement' : sender} · Official notice'
        : (sender.isEmpty ? 'New message' : sender);

    // Points 10/12/17: an Important or Urgent message that demands an
    // acknowledgment gets the canonical copy and the alarm-grade channel, so
    // it is unmistakable and still sounds with the app backgrounded or the
    // device locked. A `normal` message keeps the routine channel, and its
    // heading, so nothing else changes.
    final needsAck =
        CommunicationService.messageRequiresAck(record) &&
            !isAnnouncement;
    if (needsAck) {
      final copy = AcknowledgementService.notificationCopy(
        priority: priority,
        senderName: sender,
      );
      await NotificationService.instance.init();
      await NotificationService.instance.show(
        // Deterministic per message, so a replayed event cannot stack
        // duplicates while distinct messages still notify.
        id: _notificationId('${record['id'] ?? event.conversationId}'),
        title: copy.title,
        body: copy.body,
        // Focus the message so the tap lands on the acknowledgment control.
        route: '${_routeFor(event)}?focus=${record['id'] ?? ''}',
        channel: NotificationService.channelReminders,
        highPriority: true,
      );
      return;
    }

    await NotificationService.instance.init();
    await NotificationService.instance.show(
      // Deterministic per message, so a replayed event cannot stack duplicate
      // notifications while distinct messages still notify.
      id: _notificationId('${record['id'] ?? event.conversationId}'),
      title: title,
      body: '${record['body'] ?? ''}'.trim(),
      route: _routeFor(event),
      channel: highPriority
          ? NotificationService.channelAnnouncements
          : NotificationService.channelMessages,
      highPriority: highPriority,
    );
  }

  static int _notificationId(String seed) {
    var h = 0;
    for (final unit in seed.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    // Stay in the 32-bit range and clear of the fixed reminder ids.
    return 100000 + (h % 900000);
  }

  String _routeFor(MessagingEvent e) => switch (e.type) {
    'direct' => '/messages/${e.conversationId}',
    'group' => '/messages/group/${e.conversationId}',
    'channel' => '/messages/channel/${e.conversationId}',
    _ => '/messages/announcements',
  };

  // ------------------------------------------------------------------
  // Conversation identity
  // ------------------------------------------------------------------

  /// The conversation a `chat_messages` row belongs to. Mirrors the schema's
  /// mutually-exclusive context columns.
  static String? _conversationTypeOf(Map<String, dynamic> m) {
    final messageType = '${m['message_type'] ?? 'direct'}';
    if (messageType == 'announcement') return 'announcement';
    if ('${m['thread_id'] ?? ''}'.isNotEmpty) return 'direct';
    if ('${m['group_id'] ?? ''}'.isNotEmpty) return 'group';
    if ('${m['channel_id'] ?? ''}'.isNotEmpty) return 'channel';
    return null;
  }

  static String _conversationIdOf(Map<String, dynamic> m) {
    for (final k in ['thread_id', 'group_id', 'channel_id']) {
      final v = '${m[k] ?? ''}';
      if (v.isNotEmpty && v != 'null') return v;
    }
    return '';
  }

  /// Marks the conversation currently on screen so incoming messages update in
  /// place instead of raising a notification.
  void setActiveConversation(String? key) => _activeConversation = key;

  // ------------------------------------------------------------------
  // Unread + outbox
  // ------------------------------------------------------------------

  /// Refreshes the unread badge. Failures are swallowed: a badge is not worth
  /// interrupting the user, and the last known value stays on screen.
  Future<void> refreshUnread() async {
    try {
      final counts = await CommunicationService.instance.unreadCounts();
      if (_disposed) return;
      unreadTotal.value = CommunicationService.unreadTotal(counts);
    } catch (_) {
      // Network loss or missing RPC — keep the last known value.
    }
  }

  /// Full refresh: unread totals, mute settings, queued-message flush.
  Future<void> refresh() async {
    await refreshUnread();
    await _refreshMutes();
    await flushOutbox();
  }

  Future<void> _refreshMutes() async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return;
    try {
      final rows = await SupabaseService.client
          .from('chat_thread_user_settings')
          .select('thread_id, is_muted')
          .eq('user_id', user.id)
          .eq('is_muted', true);
      _mutedThreads
        ..clear()
        ..addAll(
          (rows as List? ?? [])
              .whereType<Map>()
              .map((e) => '${e['thread_id']}')
              .where((e) => e.isNotEmpty),
        );
    } catch (_) {
      // Keep the previous cache rather than wrongly unmuting.
    }
  }

  /// Flushes messages queued while offline. Delegates to the existing
  /// per-thread outbox in [ChatService] so there is exactly one queue.
  Future<void> flushOutbox() async {
    try {
      await ChatService.instance.syncOutbox();
    } catch (_) {
      // Still offline; the next resume or reconnect retries.
    }
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    _teardownSubscription();
    unawaited(_events.close());
    unreadTotal.dispose();
    messageTick.dispose();
  }
}
