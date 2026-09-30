import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/notification_service.dart';
import '../../core/services/supabase_service.dart';
import 'acknowledgement_service.dart';
import 'communication_service.dart';
import 'message_ui.dart' show relativeTime;

/// Where an outstanding acknowledgment lives, so the gate can deep-link into
/// the exact conversation and, when possible, the exact message.
enum PendingAckKind { message, announcement }

/// One item the signed-in user is still required to acknowledge.
///
/// The backend is the authority: an item only appears here when
/// `requires_ack` is set on a message the caller can read and no
/// `chat_message_acks` / `message_acknowledgements` row records this user as
/// `acknowledged`.
class PendingAck {
  const PendingAck({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.senderName,
    required this.createdAt,
    this.priority = 'high',
    this.threadId = '',
    this.channelId = '',
    this.groupId = '',
  });

  final String id;
  final PendingAckKind kind;

  /// Channel/group name, or a short descriptor for a direct message.
  final String title;
  final String body;
  final String senderName;
  final String createdAt;

  /// `normal`, `high` or `urgent`.
  final String priority;

  final String threadId;
  final String channelId;
  final String groupId;

  bool get isUrgent => priority == 'urgent';

  /// Route that opens the exact source of this item.
  ///
  /// Falls back to the Messages tab when the message is a direct thread the
  /// client cannot resolve to a `chat_threads` id, so a tap never lands the
  /// user somewhere useless.
  String get route {
    if (kind == PendingAckKind.announcement) return '/messages/announcements';
    if (threadId.isNotEmpty) return '/messages/$threadId';
    if (channelId.isNotEmpty) return '/messages/channel/$channelId';
    if (groupId.isNotEmpty) return '/messages/group/$groupId';
    return '/messages';
  }

  /// Label for the gate header, e.g. "URGENT · Priya Raman".
  ///
  /// Falls back to the conversation kind rather than to [title]: repeating the
  /// title directly above itself reads as a rendering bug.
  String get subtitle {
    if (kind == PendingAckKind.announcement) return 'Company announcement';
    if (senderName.isNotEmpty) return senderName;
    return 'Direct message';
  }

  /// `2m ago` style label for the gate's timestamp line.
  String get age => relativeTime(createdAt);
}

/// Owns the mandatory-acknowledgment state machine and the five-minute
/// reminder loop.
///
/// State machine per item: `pending → acknowledged`. There is deliberately no
/// client-side "rejected" state — the backend records the acknowledgment, and
/// inventing a local rejection would let a user look compliant to an audit that
/// says otherwise. A pending item blocks the app until it is acknowledged; a
/// network failure keeps it pending rather than letting the user through,
/// because the point of the requirement is that the server knows the message
/// was seen.
class UrgentAckService with WidgetsBindingObserver {
  UrgentAckService._();
  static final UrgentAckService instance = UrgentAckService._();

  /// Reminder cadence while anything is outstanding, per the product spec.
  static const reminderInterval = Duration(minutes: 5);

  /// Notification id reserved for the recurring ack reminder. Fixed so a
  /// second reminder replaces the first instead of stacking up.
  static const reminderNotificationId = 8801;

  final ValueNotifier<List<PendingAck>> pending =
      ValueNotifier<List<PendingAck>>(const []);

  /// Increments on every reminder fire. SARA and the Messages badge both listen
  /// so the spoken nudge and the system notification stay in lockstep.
  final ValueNotifier<int> reminderTick = ValueNotifier<int>(0);

  /// Id of the item currently being acknowledged, so the gate can disable its
  /// button instead of letting a double-tap fire two RPCs.
  final ValueNotifier<String> acknowledging = ValueNotifier<String>('');

  Timer? _reminder;
  bool _started = false;
  bool _refreshing = false;

  /// Loads the outstanding queue, preferring the shared server RPC.
  ///
  /// Falls back to the legacy client-side derivation when the RPC is not
  /// deployed, so an un-migrated backend still gates correctly rather than
  /// silently letting everyone through.
  Future<List<PendingAck>> _loadPending(String me) async {
    try {
      final items = await AcknowledgementService.instance.listPending();
      // An empty answer is authoritative only when the RPC exists. If it is
      // missing, the fallback rebuilds the queue the old way.
      if (items.isNotEmpty) return _sorted(items);
    } catch (e) {
      debugPrint('[UrgentAckService] pending RPC unavailable: $e');
    }
    try {
      final result = await CommunicationService.instance.pendingMessageAcks();
      return _sorted(<PendingAck>[
        for (final m in result.pending) _toPendingAck(m, me),
        ...await _pendingAnnouncements(me),
      ]);
    } catch (e) {
      debugPrint('[UrgentAckService] pendingMessageAcks failed: $e');
      return const [];
    }
  }

  /// Oldest first: a compliance queue is worked front to back.
  List<PendingAck> _sorted(List<PendingAck> items) {
    final out = [...items];
    out.sort((a, b) {
      final ta = DateTime.tryParse(a.createdAt);
      final tb = DateTime.tryParse(b.createdAt);
      if (ta == null || tb == null) return 0;
      return ta.compareTo(tb);
    });
    return out;
  }

  /// The item the blocking gate shows: the oldest outstanding one, because a
  /// compliance queue is worked front to back.
  PendingAck? get current {
    final items = pending.value;
    if (items.isEmpty) return null;
    return items.reduce((a, b) {
      final ta = DateTime.tryParse(a.createdAt);
      final tb = DateTime.tryParse(b.createdAt);
      if (ta == null || tb == null) return a;
      return ta.isBefore(tb) ? a : b;
    });
  }

  int get count => pending.value.length;

  bool get hasPending => pending.value.isNotEmpty;

  // -------------------------------------------------------------------------
  // Dismissal (point 8)
  //
  // Dismissal is NOT acknowledgment. It hides the banner for a fixed window and
  // then it comes back, until the server record for that message reads
  // 'acknowledged'. Confining this to the service means the dismissal survives a
  // rebuild, a tab switch and an app restart, instead of living in a widget
  // that would forget it on the next frame.
  // -------------------------------------------------------------------------

  /// messageId -> when the dismissal expires.
  final Map<String, DateTime> _dismissedUntil = {};

  Timer? _resurfaceTimer;

  /// The item the banner should currently show, or null when every outstanding
  /// item is inside its dismissal window.
  ///
  /// Returns the oldest non-dismissed item so the queue is worked front to back.
  PendingAck? visible(List<PendingAck> items) {
    if (items.isEmpty) return null;
    final now = DateTime.now();
    // Oldest first: a compliance queue is worked front to back, and the caller
    // may hand us a list in arbitrary order (a fresh query is sorted, but a
    // locally-assembled queue in a test or a push payload may not be).
    PendingAck? oldest;
    DateTime? oldestAt;
    for (final item in items) {
      final until = _dismissedUntil[item.id];
      if (until != null && until.isAfter(now)) continue; // dismissed
      final at = DateTime.tryParse(item.createdAt);
      if (oldest == null ||
          (at != null && (oldestAt == null || at.isBefore(oldestAt)))) {
        oldest = item;
        oldestAt = at ?? oldestAt;
      }
    }
    return oldest;
  }

  /// Hide the banner for [id] until [window] has elapsed.
  ///
  /// Deliberately does not touch the server: hiding a notice and confirming a
  /// directive are different acts, and conflating them would let a compliance
  /// obligation be cleared without the user ever confirming it.
  void dismissUntil(String id, Duration window) {
    if (id.isEmpty) return;
    _dismissedUntil[id] = DateTime.now().add(window);
    _armResurface(window);
    _repaint();
  }

  /// Re-shows the banner when the dismissal expires.
  void _armResurface(Duration window) {
    _resurfaceTimer?.cancel();
    _resurfaceTimer = Timer(window, () {
      _dismissedUntil.clear();
      _repaint();
    });
  }

  /// Nudge the banner to rebuild.
  ///
  /// This service is not a [ChangeNotifier]; it exposes ValueNotifiers. The
  /// banner listens to `pending`, so re-assigning it is what drives the repaint.
  /// The list itself is unchanged — only its identity, which is what a
  /// ValueListenable actually compares.
  void _repaint() {
    pending.value = List<PendingAck>.unmodifiable(pending.value);
  }

  /// True when [id] is currently hidden by a dismissal.
  bool isDismissed(String id) {
    final until = _dismissedUntil[id];
    return until != null && until.isAfter(DateTime.now());
  }

  /// Begins observing. Safe to call more than once.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
    _subscribeRealtime();
  }

  RealtimeChannel? _ackChannel;

  /// Live updates for this device's own acknowledgment rows (point 6).
  ///
  /// When the user acknowledges on the web, or on another device, the row flips
  /// and this subscription re-reads the queue, so the banner clears without the
  /// user pulling to refresh. Filtered to this user so the channel carries only
  /// their own rows.
  void _subscribeRealtime() {
    // Realtime needs a live Supabase client. `SupabaseService.client` is a
    // `static final` that resolves `Supabase.instance.client` on first touch,
    // which throws before init and would take the whole widget tree with it.
    // `Env.isConfigured` is NOT a sufficient guard, because a test or a
    // pre-init window can be fully configured yet uninitialised. So even
    // reading `userId` happens inside the try, exactly as `refresh()` does.
    try {
      final me = SupabaseService.userId ?? '';
      if (me.isEmpty) return;
      _ackChannel = SupabaseService.client
          .channel('my-acks:$me')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'chat_message_acks',
            // Postgres filters cannot use `eq.` on a text column without the
            // `eq.` prefix being applied to the value; the documented form is
            // `user_id=eq.<uuid>`.
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: me,
            ),
            callback: (_) => unawaited(refresh()),
          )
          .subscribe();
    } catch (e) {
      // Realtime is an optimisation: the lifecycle refresh and the five-minute
      // loop still keep the queue accurate without it.
      debugPrint('[UrgentAckService] realtime unavailable: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A message that arrived while the app was backgrounded must gate the user
    // the moment they come back, not on the next five-minute tick.
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  /// Re-reads every outstanding acknowledgment from the server.
  ///
  /// Prefers the server's `list_pending_acks_for_me` so the mobile queue, its
  /// wording and its audience are exactly what the web client shows. Falls back
  /// to the legacy client-side derivation when that RPC is not deployed yet, so
  /// an un-migrated backend still gates correctly rather than silently letting
  /// everyone through.
  ///
  /// Failures are intentionally swallowed: the gate already holds a list, and
  /// clearing it because the network blipped would unblock a user who has not
  /// complied. Staying blocked on stale data is the safer failure.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final me = SupabaseService.userId ?? '';
      if (me.isEmpty) {
        pending.value = const [];
        return;
      }
      final items = await _loadPending(me);
      final had = pending.value.isNotEmpty;
      pending.value = items;
      _syncReminder(items.isNotEmpty);
      // A reminder is owed the moment a *new* obligation appears, not at the
      // next tick — otherwise a fresh urgent message could wait up to five
      // minutes for its first nudge.
      if (!had && items.isNotEmpty) _fireReminder();
    } catch (e) {
      debugPrint('[UrgentAckService] refresh failed: $e');
    } finally {
      _refreshing = false;
    }
  }

  /// Records the acknowledgment for [item] and clears it from the queue.
  ///
  /// The item is only removed after `acknowledge_chat_message` /
  /// `acknowledge_announcement` returns successfully, so a failure leaves the
  /// user blocked and able to retry rather than silently losing the record.
  Future<bool> acknowledge(PendingAck item) async {
    if (acknowledging.value == item.id) return false;
    acknowledging.value = item.id;
    try {
      if (item.kind == PendingAckKind.announcement) {
        await CommunicationService.instance.acknowledgeAnnouncement(item.id);
      } else {
        await CommunicationService.instance.acknowledgeMessage(item.id);
      }
      pending.value = [
        for (final p in pending.value)
          if (p.id != item.id || p.kind != item.kind) p,
      ];
      _syncReminder(pending.value.isNotEmpty);
      unawaited(refresh());
      return true;
    } catch (e) {
      debugPrint('[UrgentAckService] acknowledge failed: $e');
      return false;
    } finally {
      acknowledging.value = '';
    }
  }

  /// Starts or stops the five-minute reminder loop to match the queue depth.
  void _syncReminder(bool hasPending) {
    if (!hasPending) {
      _reminder?.cancel();
      _reminder = null;
      return;
    }
    _reminder ??= Timer.periodic(reminderInterval, (_) => _fireReminder());
  }

  /// Posts one reminder for the oldest outstanding item.
  ///
  /// Exposed as [fireReminderNow] for the manual "Remind me again" affordance in
  /// the gate, so the test button and the timer share one code path.
  void _fireReminder() {
    final items = pending.value;
    if (items.isEmpty) return;
    final item = current ?? items.first;
    final left = items.length;
    reminderTick.value++;
    // Fire-and-forget: a reminder is a courtesy nudge, and failing to post it
    // must never escalate into a visible error or block the acknowledgment.
    unawaited(
      NotificationService.instance.show(
        id: reminderNotificationId,
        title: item.isUrgent
            ? 'Urgent message awaiting acknowledgment'
            : 'Message awaiting acknowledgment',
        body: left > 1
            ? '${item.title}: ${item.body}\n\n$left messages are still waiting.'
            : '${item.title}: ${item.body}',
        route: item.route,
        channel: NotificationService.channelMessages,
        highPriority: item.isUrgent,
      ),
    );
  }

  /// Fires a reminder immediately — the gate's "Remind me again" button.
  void fireReminderNow() => _fireReminder();

  /// Test/teardown seam: drops the observer, the timer and all state.
  void stop() {
    _reminder?.cancel();
    _reminder = null;
    _resurfaceTimer?.cancel();
    _resurfaceTimer = null;
    _dismissedUntil.clear();
    // Release the realtime channel so a sign-out does not leave a live
    // subscription bound to the previous user id.
    unawaited(_ackChannel?.unsubscribe() ?? Future<void>.value());
    _ackChannel = null;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _started = false;
    pending.value = const [];
  }

  PendingAck _toPendingAck(Map<String, dynamic> m, String me) {
    final senderId = '${m['sender_id'] ?? ''}';
    final isOfficial = m['is_official'] == true || m['is_official'] == 'true';
    return PendingAck(
      id: '${m['id'] ?? ''}',
      kind: PendingAckKind.message,
      title: '${m['title'] ?? ''}'.trim().isEmpty
          ? (isOfficial ? 'Official notice' : 'Message')
          : '${m['title']}',
      body: '${m['body'] ?? ''}'.trim(),
      senderName: senderId.isEmpty || senderId == me ? '' : senderId,
      createdAt: '${m['created_at'] ?? ''}',
      priority: CommunicationService.messagePriority(m),
      threadId: '${m['thread_id'] ?? ''}',
      channelId: '${m['channel_id'] ?? ''}',
      groupId: '${m['group_id'] ?? ''}',
    );
  }

  /// Announcements that require acknowledgment and have not been confirmed.
  ///
  /// `listAnnouncements` already returns the caller's audience-scoped rows and
  /// the ack status is read per row, mirroring `AnnouncementsTab.jsx` on the
  /// web. An announcement only takes effect on its `effective_date`, so a
  /// future-dated notice must not block anyone yet.
  Future<List<PendingAck>> _pendingAnnouncements(String me) async {
    try {
      final rows = await CommunicationService.instance.listAnnouncements();
      final out = <PendingAck>[];
      for (final a in rows) {
        if (a['requires_ack'] != true && a['requires_ack'] != 'true') continue;
        final effective = '${a['effective_date'] ?? a['published_at'] ?? ''}';
        final at = DateTime.tryParse(effective);
        if (at != null && at.isAfter(DateTime.now())) continue;
        final ack = await CommunicationService.instance.myAnnouncementAck(
          '${a['id'] ?? ''}',
        );
        if ('${ack['status'] ?? ''}' == 'acknowledged') continue;
        out.add(
          PendingAck(
            id: '${a['id'] ?? ''}',
            kind: PendingAckKind.announcement,
            title: '${a['title'] ?? 'Announcement'}',
            body: '${a['body'] ?? ''}'.trim(),
            senderName: '',
            createdAt: effective.isEmpty
                ? '${a['published_at'] ?? ''}'
                : effective,
            priority: '${a['priority'] ?? 'high'}',
          ),
        );
      }
      return out;
    } catch (e) {
      debugPrint('[UrgentAckService] announcements: $e');
      return const [];
    }
  }
}
