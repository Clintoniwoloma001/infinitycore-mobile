import 'package:flutter/foundation.dart';

import '../../core/diagnostics/auth_trace.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/supabase_service.dart';
import 'communication_service.dart';
import 'urgent_ack_service.dart';

/// Mobile half of the shared acknowledgement contract.
///
/// Reads the SAME RPCs the web client uses (`list_pending_acks_for_me`,
/// `get_ack_rollup`, `acknowledge_chat_message`), which is what keeps the two
/// platforms showing identical counts, identical recipient lists and identical
/// wording. Nothing here re-derives the audience: the server freezes it at send
/// time and both clients merely report it.
///
/// Lifecycle, in the order the architecture requires:
///   Message -> Audience -> Acknowledgement state -> Notification -> Reminder
///
/// Point 1: a sender is never in debt. [ackRequiredByMe] returns false for
/// their own message, and the server's RPC short-circuits for the sender too.
class AcknowledgementService {
  AcknowledgementService._();

  static final AcknowledgementService instance = AcknowledgementService._();

  /// True when this message demands an acknowledgment from its recipients.
  static bool requiresAck(Map<String, dynamic> message) =>
      CommunicationService.messageRequiresAck(message);

  /// Normalised priority: normal | high | urgent.
  static String priority(Map<String, dynamic> message) =>
      CommunicationService.messagePriority(message);

  /// True when [me] sent [message] and therefore never owes an acknowledgment.
  static bool isOwn(Map<String, dynamic> message, String me) =>
      me.isNotEmpty && '${message['sender_id'] ?? ''}' == me;

  /// Whether [me] still owes an acknowledgment for [message].
  ///
  /// Point 1 excludes the sender; point 2 makes an acknowledgment sticky, so a
  /// recorded ack can never be re-demanded on a later launch.
  static bool ackRequiredByMe(
    Map<String, dynamic> message,
    List<Map<String, dynamic>> acks,
    String me,
  ) => CommunicationService.ackRequired(message, acks, me);

  /// Everything this device still owes, straight from the server.
  ///
  /// This replaces the client-side re-derivation the service used to do, which
  /// had drifted from the web implementation.
  Future<List<PendingAck>> listPending() async {
    final me = SupabaseService.userId ?? '';
    if (me.isEmpty) return const [];
    try {
      final rows = await SupabaseService.client.rpc<List<Map<String, dynamic>>>(
        'list_pending_acks_for_me',
      );
      if (rows.isEmpty) return const [];
      return [for (final r in rows) _toPendingAck(r, me)];
    } catch (e) {
      // Never clear the queue on a failure: staying blocked on stale data is the
      // safer direction, because a user who still owes an acknowledgment must
      // not be let through by a network blip.
      debugPrint('[AckService] listPending failed: $e');
      return const [];
    }
  }

  /// The sender's ledger for one message: progress plus the two rosters.
  Future<Map<String, dynamic>?> rollup(String messageId) async {
    if (messageId.isEmpty) return null;
    try {
      return await SupabaseService.client.rpc<Map<String, dynamic>>(
        'get_ack_rollup',
        params: {'p_message_id': messageId},
      );
    } catch (e) {
      debugPrint('[AckService] rollup failed: $e');
      return null;
    }
  }

  /// Split a rollup into the two clearly separated groups the UI renders.
  static ({int total, int done, int pending, bool complete}) summarize(
    Map<String, dynamic>? rollup,
  ) {
    if (rollup == null) return (total: 0, done: 0, pending: 0, complete: false);
    final total = (rollup['total'] as num?)?.toInt() ?? 0;
    final done = (rollup['acknowledged'] as num?)?.toInt() ?? 0;
    return (
      total: total,
      done: done,
      pending: (rollup['pending'] as num?)?.toInt() ?? 0,
      // An audience of zero is not "complete": there is nothing to have
      // acknowledged, and claiming otherwise would misrepresent the message.
      complete: total > 0 && done >= total,
    );
  }

  /// Recipients who have acknowledged, with timestamps.
  static List<Map<String, dynamic>> acknowledgedList(Map<String, dynamic>? r) =>
      _rows(r?['acknowledged_list']);

  /// Recipients still outstanding.
  static List<Map<String, dynamic>> pendingList(Map<String, dynamic>? r) =>
      _rows(r?['pending_list']);

  static List<Map<String, dynamic>> _rows(Object? raw) {
    if (raw is List) {
      return [
        for (final r in raw)
          if (r is Map) Map<String, dynamic>.from(r),
      ];
    }
    return const [];
  }

  /// Record this user's acknowledgment.
  ///
  /// Idempotent: the server treats a repeat as success, so a double tap or a
  /// retry after a dropped connection cannot create a duplicate record. The
  /// table also carries a unique (message_id, user_id) constraint.
  Future<bool> acknowledge(String messageId) async {
    try {
      await CommunicationService.instance.acknowledgeMessage(messageId);
      await UrgentAckService.instance.refresh();
      return true;
    } catch (e) {
      debugPrint('[AckService] acknowledge failed: $e');
      return false;
    }
  }

  /// Push notification copy for an Important/Urgent message (point 10).
  ///
  /// Identical wording to the web service and the service worker, so a user who
  /// reads a lock-screen alert sees the same sentence on either platform.
  static ({String title, String body}) notificationCopy({
    required String priority,
    required String senderName,
  }) {
    final who = senderName.isEmpty ? 'Someone' : senderName;
    if (priority.toLowerCase() == 'urgent') {
      return (
        title: 'URGENT MESSAGE',
        body: '$who sent you an urgent message. Acknowledgement required.',
      );
    }
    return (
      title: 'IMPORTANT MESSAGE',
      body: '$who sent you an important message. Acknowledgement required.',
    );
  }

  /// Post the system notification for an incoming Important/Urgent message.
  ///
  /// Point 17: a real Android notification on the alarm-grade channel, not a
  /// Snackbar. A Snackbar cannot appear when the app is backgrounded or the
  /// device is locked, which is exactly the case that matters here.
  ///
  /// Deep links to the conversation, so a tap opens the right thread and
  /// exposes the acknowledgment control.
  Future<void> notifyIncoming({
    required String priority,
    required String senderName,
    required String route,
  }) async {
    final copy = notificationCopy(priority: priority, senderName: senderName);
    await NotificationService.instance.show(
      // One id per priority so a resend replaces its own notification instead
      // of stacking duplicates in the shade.
      id: priority.toLowerCase() == 'urgent' ? 9301 : 9302,
      title: copy.title,
      body: copy.body,
      route: route,
      channel: NotificationService.channelReminders,
      highPriority: true,
    );
    AuthTrace.log('ack.notify', '${copy.title} -> $route');
  }

  PendingAck _toPendingAck(Map<String, dynamic> row, String me) {
    return PendingAck(
      id: '${row['message_id'] ?? ''}',
      kind: PendingAckKind.message,
      title: _titleFor(row),
      body: '${row['body'] ?? ''}',
      // Resolved to a real name by the gate; an empty string makes `subtitle`
      // fall back to the conversation kind rather than printing a UUID.
      senderName: '',
      createdAt: '${row['created_at'] ?? ''}',
      priority: '${row['priority'] ?? 'high'}',
      threadId: '${row['thread_id'] ?? ''}',
      groupId: '${row['group_id'] ?? ''}',
      channelId: '${row['channel_id'] ?? ''}',
    );
  }

  /// A short descriptor for the banner header. The real name is resolved by the
  /// UI, which already loads the employee directory for the conversation.
  String _titleFor(Map<String, dynamic> row) {
    if (row['thread_id'] != null) return 'Direct message';
    if (row['group_id'] != null) return 'Group message';
    if (row['channel_id'] != null) return 'Channel message';
    return 'Important message';
  }

  /// In-app route for a message, so the banner and the notification tap both
  /// land on the right conversation with the message focused.
  static String deepLinkFor(Map<String, dynamic> row) {
    final messageId = '${row['message_id'] ?? ''}';
    final focus = messageId.isEmpty ? '' : '?focus=$messageId';
    if (row['thread_id'] != null) return '/messages/${row['thread_id']}$focus';
    if (row['group_id'] != null) {
      return '/messages/group/${row['group_id']}$focus';
    }
    if (row['channel_id'] != null) {
      return '/messages/channel/${row['channel_id']}$focus';
    }
    return '/messages';
  }
}
