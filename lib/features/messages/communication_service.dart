import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';

/// Typed client for the InfinityCore corporate communication backend.
///
/// Every method maps 1:1 onto a table, RPC or Edge Function the web platform
/// already uses (`corporateChatService.js`). Nothing here invents schema, and
/// no method grants authority the caller lacks: every mutation goes through a
/// SECURITY DEFINER RPC or an RLS-scoped table write, so the database remains
/// the security boundary.
///
/// The client holds no service-role key. The only credential is the
/// publishable anon key inside [SupabaseService], so every request is
/// evaluated against the signed-in user's JWT.
class CommunicationService {
  CommunicationService._();
  static final CommunicationService instance = CommunicationService._();

  // ------------------------------------------------------------------
  // Result helpers
  // ------------------------------------------------------------------

  static Map<String, dynamic> _map(dynamic v) {
    if (v == null) return const {};
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return const {};
  }

  static List<Map<String, dynamic>> _rows(dynamic v) {
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  /// Translates a raw backend failure into text that is safe to show a normal
  /// employee. Raw PostgREST/Postgres messages are never surfaced verbatim;
  /// they are logged for diagnostics and replaced with a stable sentence.
  static String friendlyError(
    Object error, {
    String fallback = 'Something went wrong. Please try again.',
  }) {
    final raw = error.toString();
    debugPrint('[CommunicationService] $raw');
    final lower = raw.toLowerCase();
    if (lower.contains('jwt') ||
        lower.contains('expired') ||
        lower.contains('invalid claim') ||
        lower.contains('pgrst301')) {
      return 'Your session has expired. Please sign in again.';
    }
    if (lower.contains('row-level security') ||
        lower.contains('rls') ||
        lower.contains('permission denied') ||
        lower.contains('not authorized')) {
      return 'You do not have permission to perform this action.';
    }
    if (lower.contains('failed to fetch') ||
        lower.contains('socketexception') ||
        lower.contains('connection') ||
        lower.contains('no address') ||
        lower.contains('network')) {
      return 'No network connection. Check your internet and try again.';
    }
    if (lower.contains('exceeds the 25mb') ||
        lower.contains('attachment exceeds')) {
      return 'That file is too large. Attachments must be 25 MB or smaller.';
    }
    if (lower.contains('at most six attachments')) {
      return 'You can attach up to 6 files to a message.';
    }
    if (error is StateError && error.message.trim().isNotEmpty) {
      return error.message;
    }
    return fallback;
  }

  /// Calls the first RPC that exists. The web client probes the same
  /// alternates, so a rolling backend deployment keeps working either way.
  Future<dynamic> _callRpcCandidates(
    List<String> names,
    Map<String, dynamic> args,
  ) async {
    for (final name in names) {
      try {
        return await SupabaseService.client.rpc(name, params: args);
      } on PostgrestException catch (e) {
        final m = e.message.toLowerCase();
        final missing =
            m.contains('pgrst202') ||
            m.contains('could not find the function') ||
            m.contains('schema cache') ||
            m.contains('does not exist');
        if (!missing) rethrow;
      }
    }
    throw StateError(
      'This communication feature is not available on this server yet.',
    );
  }

  // ------------------------------------------------------------------
  // Direct threads
  // ------------------------------------------------------------------

  /// Threads the signed-in user belongs to, annotated with per-user mute and
  /// archive state. An archived thread stays hidden unless a newer message
  /// arrived after the archive timestamp — exactly the web behaviour.
  Future<List<Map<String, dynamic>>> listMyThreadsWithSettings() async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return const [];
    final threads = _rows(
      await SupabaseService.client
          .from('chat_threads')
          .select('*')
          .or('member_a.eq.${user.id},member_b.eq.${user.id}')
          .order('last_message_at', ascending: false),
    );
    if (threads.isEmpty) return const [];
    final ids = threads
        .map((t) => '${t['id']}')
        .where((e) => e.isNotEmpty)
        .toList();
    final settings = _rows(
      await SupabaseService.client
          .from('chat_thread_user_settings')
          .select('thread_id, is_muted, deleted_at')
          .eq('user_id', user.id)
          .inFilter('thread_id', ids),
    );
    final byThread = <String, Map<String, dynamic>>{
      for (final s in settings) '${s['thread_id']}': s,
    };
    final result = <Map<String, dynamic>>[];
    for (final t in threads) {
      final s = byThread['${t['id']}'];
      final deletedAt = s?['deleted_at']?.toString() ?? '';
      if (deletedAt.isNotEmpty) {
        final last = DateTime.tryParse('${t['last_message_at'] ?? ''}');
        final deleted = DateTime.tryParse(deletedAt);
        if (last == null || deleted == null || !last.isAfter(deleted)) continue;
      }
      result.add({
        ...t,
        'is_muted': s?['is_muted'] ?? false,
        'deleted_at': deletedAt,
      });
    }
    return result;
  }

  Future<void> setThreadMuted(String threadId, bool muted) async {
    try {
      await SupabaseService.client.rpc(
        'set_chat_thread_muted',
        params: {'p_thread_id': threadId, 'p_muted': muted},
      );
    } on PostgrestException catch (e) {
      debugPrint('[CommunicationService] setThreadMuted: ${e.message}');
    }
  }

  Future<void> deleteThreadForMe(String threadId) async {
    await SupabaseService.client.rpc(
      'delete_chat_thread_for_me',
      params: {'p_thread_id': threadId},
    );
  }

  /// Restores an archived thread (web: `restore_chat_thread_for_me`).
  Future<void> restoreThreadForMe(String threadId) async {
    await SupabaseService.client.rpc(
      'restore_chat_thread_for_me',
      params: {'p_thread_id': threadId},
    );
  }

  // ------------------------------------------------------------------
  // Read state / unread
  // ------------------------------------------------------------------

  /// Per-conversation unread counts from the server-side
  /// `get_unread_message_counts()` aggregate, keyed `type:id`.
  Future<Map<String, int>> unreadCounts() async {
    final data = await _callRpcCandidates(const [
      'get_unread_message_counts',
      'get_chat_unread_counts',
      'get_unread_chat_counts',
      'get_unread_counts',
    ], const {});
    final counts = <String, int>{};
    for (final row in _rows(data)) {
      final type = '${row['conversation_type'] ?? ''}';
      final id = '${row['conversation_id'] ?? ''}';
      final n = int.tryParse('${row['unread_count'] ?? 0}') ?? 0;
      if (type.isEmpty || id.isEmpty || n <= 0) continue;
      counts['$type:$id'] = n;
    }
    return counts;
  }

  /// Marks a direct thread read, probing the alternate RPC names the web client
  /// also uses so a rolling deployment cannot strand read state.
  Future<void> markDirectThreadRead(String threadId) async {
    if (threadId.isEmpty) return;
    await _callRpcCandidates(
      const [
        'mark_chat_thread_read',
        'mark_thread_read',
        'mark_conversation_read',
      ],
      {'p_thread_id': threadId},
    );
  }

  /// Marks a group/channel conversation read. The server exposes no RPC for
  /// these, so this writes the caller's own `chat_read_state` row. That table
  /// is RLS-restricted to `user_id = auth.uid()`, so it cannot be used to
  /// touch another person's read marker.
  Future<void> markGroupOrChannelRead(
    String conversationType,
    String id,
  ) async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null || id.isEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      final existing = _rows(
        await SupabaseService.client
            .from('chat_read_state')
            .select('id')
            .eq('user_id', user.id)
            .eq('conversation_type', conversationType)
            .eq('conversation_id', id)
            .limit(1),
      );
      if (existing.isEmpty) {
        await SupabaseService.client.from('chat_read_state').insert({
          'user_id': user.id,
          'conversation_type': conversationType,
          'conversation_id': id,
          'last_read_at': now,
          'updated_at': now,
        });
      } else {
        await SupabaseService.client
            .from('chat_read_state')
            .update({'last_read_at': now, 'updated_at': now})
            .eq('id', existing.first['id']);
      }
    } catch (e) {
      debugPrint('[CommunicationService] markRead($conversationType): $e');
    }
  }

  static int unreadFor(String type, String id, Map<String, int> counts) =>
      counts['$type:$id'] ?? 0;

  static int unreadTotal(Map<String, int> counts) =>
      counts.values.fold(0, (sum, n) => sum + n);

  // ------------------------------------------------------------------
  // Message actions (all SECURITY DEFINER RPCs on the server)
  // ------------------------------------------------------------------

  Future<void> editMessage(String messageId, String body) async {
    await SupabaseService.client.rpc(
      'edit_my_message',
      params: {'p_message_id': messageId, 'p_new_body': body},
    );
  }

  Future<void> deleteMessage(String messageId) async {
    await SupabaseService.client.rpc(
      'soft_delete_my_message',
      params: {'p_message_id': messageId},
    );
  }

  Future<void> restrictMessage(String messageId, String reason) async {
    await SupabaseService.client.rpc(
      'restrict_message',
      params: {'p_message_id': messageId, 'p_reason': reason},
    );
  }

  Future<void> pinMessage(String messageId) async {
    await SupabaseService.client.rpc(
      'pin_message',
      params: {'p_message_id': messageId},
    );
  }

  Future<void> unpinMessage(String messageId) async {
    await SupabaseService.client.rpc(
      'unpin_message',
      params: {'p_message_id': messageId},
    );
  }

  Future<void> markMessageOfficial(String messageId) async {
    await SupabaseService.client.rpc(
      'mark_message_official',
      params: {'p_message_id': messageId},
    );
  }

  Future<void> toggleBookmark(String messageId) async {
    await SupabaseService.client.rpc(
      'toggle_bookmark',
      params: {'p_message_id': messageId},
    );
  }

  /// Adds a reaction. `user_id` comes from the live session rather than the
  /// caller, so a client cannot spoof a reaction on someone else's behalf.
  Future<void> addReaction(String messageId, String emoji) async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return;
    await SupabaseService.client.from('message_reactions').insert({
      'message_id': messageId,
      'user_id': user.id,
      'emoji': emoji,
    });
  }

  Future<void> removeReaction(String messageId, String emoji) async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return;
    await SupabaseService.client.from('message_reactions').delete().match({
      'message_id': messageId,
      'user_id': user.id,
      'emoji': emoji,
    });
  }

  /// Per-recipient acknowledgement for high/priority messages.
  Future<void> acknowledgeMessage(String messageId) async {
    await SupabaseService.client.rpc(
      'acknowledge_chat_message',
      params: {
        'p_message_id': messageId,
        'p_ip': null,
        'p_user_agent': 'mobile',
      },
    );
  }

  Future<Map<String, dynamic>> messageAckStatus(String messageId) async => _map(
    await SupabaseService.client.rpc(
      'get_chat_message_ack_status',
      params: {'p_message_id': messageId},
    ),
  );

  // ------------------------------------------------------------------
  // Rich send — attachments + priority + mandatory acknowledgment
  // ------------------------------------------------------------------

  /// Sends a message with the full option set the web `sendRichMessage`
  /// exposes: `priority` (`normal` / `high` / `urgent`), `requiresAck`, any
  /// uploaded [files], mentions and an optional threaded parent.
  ///
  /// Text-only, option-free messages keep using the cheaper
  /// `send_chat_message` path in [ChatService], so the common case keeps its
  /// offline outbox. Anything with a priority, an acknowledgment requirement
  /// or an attachment must go through `send_rich_message`, because that is the
  /// only RPC that writes `message_attachments` rows and the
  /// `requires_ack`/`priority` columns inside the same transaction as the
  /// message itself.
  ///
  /// The RPC is SECURITY DEFINER on the server, so a caller cannot escalate
  /// `requires_ack` onto somebody else's behalf, and RLS still decides which
  /// context the message may be posted into.
  Future<void> sendRichMessage({
    required String contextType,
    String? contextId,
    String body = '',
    String? priority,
    bool requiresAck = false,
    List<Map<String, dynamic>> files = const [],
    List<String>? mentionIds,
    String? parentMessageId,
  }) async {
    await _callRpcCandidates(
      ['send_rich_message'],
      {
        'p_message_type': contextType,
        'p_context_id': contextId,
        'p_body': body,
        'p_priority': (priority == null || priority == 'normal')
            ? null
            : priority,
        'p_requires_ack': requiresAck,
        'p_files': files.isEmpty ? null : files,
        'p_mention_ids': (mentionIds == null || mentionIds.isEmpty)
            ? null
            : mentionIds,
        'p_parent_message_id': parentMessageId,
      },
    );
  }

  /// Acknowledgement rows for the given messages.
  ///
  /// `chat_message_acks` is RLS-scoped to the caller's own rows plus the
  /// aggregate counts the sender is entitled to see, so this is safe to call
  /// for any conversation the user can already open.
  Future<List<Map<String, dynamic>>> acksFor(List<String> messageIds) async {
    if (messageIds.isEmpty) return const [];
    return _rows(
      await SupabaseService.client
          .from('chat_message_acks')
          .select('*')
          .inFilter('message_id', messageIds),
    );
  }

  /// True when [messageId] carries a mandatory-acknowledgment flag.
  ///
  /// PostgREST returns the column as a bool on Postgres and occasionally as the
  /// string `"true"` through a view, so both spellings are accepted.
  static bool messageRequiresAck(Map<String, dynamic> message) =>
      message['requires_ack'] == true || message['requires_ack'] == 'true';

  /// `priority` normalised to one of `normal`, `high`, `urgent`.
  static String messagePriority(Map<String, dynamic> message) {
    final raw = '${message['priority'] ?? 'normal'}'.trim().toLowerCase();
    return switch (raw) {
      'urgent' || 'critical' => 'urgent',
      'high' || 'important' => 'high',
      _ => 'normal',
    };
  }

  /// True when the signed-in user still owes an acknowledgment for [message].
  ///
  /// Mirrors `myAckRequired` in the web `DirectTab`: the message must be
  /// flagged `requires_ack`, and no `chat_message_acks` row for this user may
  /// already carry `status = 'acknowledged'`.
  static bool ackRequired(
    Map<String, dynamic> message,
    List<Map<String, dynamic>> acks,
    String myUserId,
  ) {
    if (!messageRequiresAck(message) || myUserId.isEmpty) return false;
    if ('${message['sender_id'] ?? ''}' == myUserId) return false;
    return !acks.any(
      (a) =>
          '${a['user_id'] ?? ''}' == myUserId &&
          '${a['status'] ?? ''}' == 'acknowledged',
    );
  }

  /// Every `requires_ack` message the caller has read access to that they have
  /// not acknowledged yet, newest first.
  ///
  /// RLS already limits `chat_messages` to conversations the caller belongs to,
  /// so this cannot leak messages from other teams; the client-side subtraction
  /// of [acksFor] is exactly what the web `DirectTab` does, and it keeps the
  /// mandatory-ack gate working on backends that have not yet shipped a
  /// dedicated `list_pending_message_acks` RPC.
  ///
  /// The result is capped at [limit] rows on purpose: the blocking dialog only
  /// ever shows the oldest outstanding item, and a hard bound stops a long
  /// history of unacknowledged broadcasts from turning into a slow query.
  Future<
    ({List<Map<String, dynamic>> pending, List<Map<String, dynamic>> acks})
  >
  pendingMessageAcks({int limit = 50}) async {
    final empty = <Map<String, dynamic>>[];
    final me = SupabaseService.client.auth.currentUser?.id;
    if (me == null || me.isEmpty) return (pending: empty, acks: empty);
    final List<Map<String, dynamic>> rows = _rows(
      await SupabaseService.client
          .from('chat_messages')
          .select('*')
          .eq('requires_ack', true)
          .neq('sender_id', me)
          .order('created_at', ascending: false)
          .limit(limit),
    );
    if (rows.isEmpty) return (pending: empty, acks: empty);
    final List<Map<String, dynamic>> acks = await acksFor([
      for (final r in rows) '${r['id'] ?? ''}',
    ]);
    final List<Map<String, dynamic>> pending = rows
        .where((r) => ackRequired(r, acks, me))
        .toList(growable: false);
    return (pending: pending, acks: acks);
  }

  Future<void> reportMessage(
    String messageId,
    String reason, {
    String? details,
  }) async {
    await SupabaseService.client.rpc(
      'report_message',
      params: {
        'p_message_id': messageId,
        'p_reason': reason,
        'p_details': details,
      },
    );
  }

  /// Marks a visible message read (per-message read receipt). Best-effort: the
  /// web client treats a failure here as non-fatal, so it must never surface
  /// as a user-visible error.
  Future<void> markMessageRead(String messageId) async {
    try {
      await SupabaseService.client.rpc(
        'mark_message_read',
        params: {'p_message_id': messageId},
      );
    } on PostgrestException catch (e) {
      debugPrint('[CommunicationService] markMessageRead: ${e.message}');
    }
  }

  // ------------------------------------------------------------------
  // Loaders for message enrichment
  // ------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> reactionsFor(
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return const [];
    return _rows(
      await SupabaseService.client
          .from('message_reactions')
          .select('*')
          .inFilter('message_id', messageIds),
    );
  }

  Future<List<Map<String, dynamic>>> attachmentsFor(
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return const [];
    return _rows(
      await SupabaseService.client
          .from('message_attachments')
          .select('*')
          .inFilter('message_id', messageIds),
    );
  }

  Future<List<Map<String, dynamic>>> readsFor(List<String> messageIds) async {
    if (messageIds.isEmpty) return const [];
    return _rows(
      await SupabaseService.client
          .from('message_reads')
          .select('*')
          .inFilter('message_id', messageIds),
    );
  }

  Future<List<Map<String, dynamic>>> myBookmarks() async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return const [];
    return _rows(
      await SupabaseService.client
          .from('message_bookmarks')
          .select('*')
          .eq('user_id', user.id)
          .order('created_at', ascending: false),
    );
  }

  Future<List<Map<String, dynamic>>> myMentions({int limit = 100}) async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return const [];
    return _rows(
      await SupabaseService.client
          .from('message_mentions')
          .select('*')
          .eq('user_id', user.id)
          .order('created_at', ascending: false)
          .limit(limit),
    );
  }

  /// Pinned messages in a group or channel.
  Future<List<Map<String, dynamic>>> pinnedIn({
    required String contextType,
    required String contextId,
  }) async {
    final column = contextType == 'group' ? 'group_id' : 'channel_id';
    return _rows(
      await SupabaseService.client
          .from('chat_messages')
          .select('*')
          .eq(column, contextId)
          .eq('is_pinned', true)
          .order('pinned_at', ascending: false)
          .limit(50),
    );
  }

  // ------------------------------------------------------------------
  // Announcements
  // ------------------------------------------------------------------

  /// Announcements visible to the caller. RLS restricts this to announcements
  /// whose audience contains the caller, or that the caller authored.
  Future<List<Map<String, dynamic>>> listAnnouncements() async {
    return _rows(
      await SupabaseService.client
          .from('announcements')
          .select('*')
          .order('published_at', ascending: false),
    );
  }

  Future<Map<String, dynamic>> announcementMessage(
    String announcementId,
  ) async => _map(
    await SupabaseService.client
        .from('announcements')
        .select('*, message:chat_messages(*)')
        .eq('id', announcementId)
        .single(),
  );

  /// Publishes an official announcement. Authorization is enforced by
  /// `can_author_announcement()` inside the RPC, never by this client.
  Future<Map<String, dynamic>> publishAnnouncement({
    required String title,
    required String body,
    String priority = 'normal',
    String targetType = 'organization',
    String? targetValue,
    bool requiresAck = false,
    DateTime? effectiveDate,
    DateTime? expiryDate,
  }) async {
    final data = await SupabaseService.client.rpc(
      'publish_announcement',
      params: {
        'p_title': title,
        'p_body': body,
        'p_priority': priority,
        'p_target_type': targetType,
        'p_target_value': targetValue,
        'p_requires_ack': requiresAck,
        'p_effective_date': (effectiveDate ?? DateTime.now())
            .toUtc()
            .toIso8601String(),
        'p_expiry_date': expiryDate?.toUtc().toIso8601String(),
      },
    );
    return _map(data);
  }

  Future<void> acknowledgeAnnouncement(String announcementId) async {
    await SupabaseService.client.rpc(
      'acknowledge_announcement',
      params: {
        'p_announcement_id': announcementId,
        'p_ip': null,
        'p_user_agent': 'mobile',
      },
    );
  }

  Future<Map<String, dynamic>> announcementAckStatus(
    String announcementId,
  ) async => _map(
    await SupabaseService.client.rpc(
      'get_announcement_ack_status',
      params: {'p_announcement_id': announcementId},
    ),
  );

  Future<Map<String, dynamic>> myAnnouncementAck(String announcementId) async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return const {};
    final rows = _rows(
      await SupabaseService.client
          .from('message_acknowledgements')
          .select('*')
          .eq('announcement_id', announcementId)
          .eq('user_id', user.id)
          .limit(1),
    );
    return rows.isEmpty ? const {} : rows.first;
  }

  // ------------------------------------------------------------------
  // Comm Admin
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> communicationStats() async =>
      _map(await SupabaseService.client.rpc('get_communication_stats'));

  Future<List<Map<String, dynamic>>> auditLog({int limit = 200}) async {
    return _rows(
      await SupabaseService.client
          .from('message_audit_log')
          .select('*')
          .order('timestamp', ascending: false)
          .limit(limit),
    );
  }

  Future<List<Map<String, dynamic>>> reports() async {
    return _rows(
      await SupabaseService.client
          .from('message_reports')
          .select('*')
          .order('created_at', ascending: false),
    );
  }

  Future<void> resolveReport(
    String reportId,
    String status, {
    String? note,
  }) async {
    await SupabaseService.client.rpc(
      'resolve_message_report',
      params: {'p_report_id': reportId, 'p_status': status, 'p_note': note},
    );
  }

  Future<List<Map<String, dynamic>>> holds() async {
    return _rows(
      await SupabaseService.client
          .from('message_holds')
          .select('*')
          .order('created_at', ascending: false),
    );
  }

  Future<void> createHold({
    required String scope,
    required String scopeId,
    required String reason,
    DateTime? endDate,
  }) async {
    await SupabaseService.client.rpc(
      'create_message_hold',
      params: {
        'p_scope': scope,
        'p_scope_id': scopeId,
        'p_reason': reason,
        'p_end_date': endDate?.toUtc().toIso8601String(),
      },
    );
  }

  Future<void> releaseHold(String holdId, {String? reason}) async {
    await SupabaseService.client.rpc(
      'release_message_hold',
      params: {'p_hold_id': holdId, 'p_reason': reason},
    );
  }

  Future<List<Map<String, dynamic>>> retentionPolicies() async {
    return _rows(
      await SupabaseService.client
          .from('message_retention_policies')
          .select('*'),
    );
  }

  Future<void> setRetentionPolicy({
    required String key,
    required String label,
    required int retentionDays,
    required bool isForever,
  }) async {
    await SupabaseService.client.rpc(
      'set_retention_policy',
      params: {
        'p_key': key,
        'p_label': label,
        'p_retention_days': retentionDays,
        'p_is_forever': isForever,
      },
    );
  }

  Future<List<Map<String, dynamic>>> exports() async {
    return _rows(
      await SupabaseService.client
          .from('message_exports')
          .select('*')
          .order('created_at', ascending: false),
    );
  }

  /// Requests a server-side export. The RPC applies the admin gate and writes
  /// an audit entry before returning the rows.
  Future<List<Map<String, dynamic>>> exportRecords({
    required String format,
    required String scope,
    String? scopeId,
    String? reason,
    String? query,
    Map<String, dynamic> filters = const {},
  }) async {
    final data = await SupabaseService.client.rpc(
      'create_message_export',
      params: {
        'p_format': format,
        'p_scope': scope,
        'p_scope_id': scopeId,
        'p_reason': reason,
        'p_query': query,
        'p_filters': filters,
      },
    );
    if (data is Map) {
      final rows = data['rows'];
      if (rows is List) return _rows(rows);
    }
    return _rows(data);
  }

  /// Server-side message search. Filtering happens in Postgres, so the device
  /// never downloads the corpus.
  Future<List<Map<String, dynamic>>> searchMessages(
    String query, {
    Map<String, dynamic> filters = const {},
  }) async {
    final data = await SupabaseService.client.rpc(
      'search_messages',
      params: {'p_query': query.isEmpty ? null : query, 'p_filters': filters},
    );
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // Channels (Comm Admin view)
  // ------------------------------------------------------------------

  /// Every channel, including inactive ones, for the Comm Admin channel list.
  /// RLS still keeps non-admin callers to their own memberships.
  Future<List<Map<String, dynamic>>> channelAdminList() async {
    return _rows(
      await SupabaseService.client
          .from('message_channels')
          .select('*')
          .order('display_name', ascending: true),
    );
  }

  /// Reconciles automatic (branch/department/role) membership for a channel.
  Future<void> syncAutoChannelMembers(String channelId) async {
    await SupabaseService.client.rpc(
      'sync_auto_channel_members',
      params: {'p_channel_id': channelId},
    );
  }

  // ------------------------------------------------------------------
  // Attachments
  // ------------------------------------------------------------------

  /// Builds a short-lived signed URL for a chat attachment.
  ///
  /// The `documents` bucket is private and the `chat_attachment_read` storage
  /// policy ties every object back to a message the caller may read, so a
  /// signed URL is both safer and more correct here than a public URL.
  Future<String?> signedAttachmentUrl(
    String path, {
    int expiresInSeconds = 600,
  }) async {
    if (path.isEmpty) return null;
    try {
      return await SupabaseService.client.storage
          .from('documents')
          .createSignedUrl(path, expiresInSeconds);
    } catch (e) {
      debugPrint('[CommunicationService] signedAttachmentUrl failed: $e');
      return null;
    }
  }

  // ------------------------------------------------------------------
  // Directory
  // ------------------------------------------------------------------

  /// Resolves auth user ids to employee identities through the server RPC
  /// `resolve_user_identity`, so the UI never renders a raw UUID.
  Future<Map<String, Map<String, dynamic>>> resolveDirectory(
    List<String> userIds,
  ) async {
    final ids = userIds.where((e) => e.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const {};
    final data = await SupabaseService.client.rpc(
      'resolve_user_identity',
      params: {'p_user_ids': ids},
    );
    final map = <String, Map<String, dynamic>>{};
    for (final r in _rows(data)) {
      final uid = '${r['user_id'] ?? ''}';
      if (uid.isNotEmpty) map[uid] = r;
    }
    return map;
  }
}
