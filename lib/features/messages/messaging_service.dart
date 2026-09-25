import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';

/// Channels + groups client. Mirrors `corporateChatService.js` (channels &
/// groups namespaced APIs) so the mobile app talks to the exact same RPCs.
///
/// Membership is resolved server-side (`message_channel_members` /
/// `message_group_members`) — including the automatic branch/area/department/
/// role membership model. This client never synthesizes membership locally.
class MessagingService {
  MessagingService._();
  static final MessagingService instance = MessagingService._();

  static List<Map<String, dynamic>> _rows(List<Map<String, dynamic>>? rows) =>
      rows ?? const [];

  static Map<String, dynamic> _map(dynamic v) {
    if (v == null) return const {};
    return v is Map<String, dynamic> ? v : Map<String, dynamic>.from(v as Map);
  }

  /// Invite URL shared with colleagues/WhatsApp. It points at the canonical
  /// web platform — internal table UUIDs are never used as the invitation
  /// mechanism.
  static String buildInviteUrl() => 'https://infinitymfbcore.vercel.app';

  static String buildInviteText(String kind, String name) =>
      'Join me on InfinityCore$kind: $name\n${buildInviteUrl()}';

  // ---- Channels ----

  Future<List<Map<String, dynamic>>> listChannels() async {
    final res = await SupabaseService.client
        .from('message_channels')
        .select('*')
        .eq('status', 'active')
        .order('display_name', ascending: true);
    return _rows(res);
  }

  Future<Map<String, dynamic>> ensureOrganizational() async {
    final data = await SupabaseService.client.rpc(
      'ensure_organizational_channels',
      params: const {},
    );
    return _map(data);
  }

  /// Ask the server to reconcile automatic membership for a channel. Called
  /// when entering a channel so branch/dept/role membership stays fresh.
  Future<bool> syncAutoMembers(String channelId) async {
    try {
      await SupabaseService.client.rpc(
        'sync_auto_channel_members',
        params: {'p_channel_id': channelId},
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> createChannel({
    required String name,
    String? displayName,
    String? description,
    String channelType = 'team',
    bool isAuto = false,
    String? autoSource,
    String? autoSourceId,
    String? autoSourceRole,
    List<String> memberIds = const [],
  }) async {
    final data = await SupabaseService.client.rpc(
      'create_message_channel',
      params: {
        'p_name': name,
        'p_display_name': displayName,
        'p_description': description,
        'p_channel_type': channelType,
        'p_is_auto': isAuto,
        'p_auto_source': autoSource,
        'p_auto_source_id': autoSourceId,
        'p_auto_source_role': autoSourceRole,
        'p_member_ids': memberIds,
      },
    );
    return _map(data);
  }

  Future<void> addChannelMember(String channelId, String memberId) async {
    await SupabaseService.client.rpc(
      'add_channel_member',
      params: {'p_channel_id': channelId, 'p_member_id': memberId},
    );
  }

  Future<void> removeChannelMember(String channelId, String memberId) async {
    await SupabaseService.client.rpc(
      'remove_channel_member',
      params: {'p_channel_id': channelId, 'p_member_id': memberId},
    );
  }

  Future<List<Map<String, dynamic>>> channelMembers(String channelId) async {
    final res = await SupabaseService.client
        .from('message_channel_members')
        .select('*')
        .eq('channel_id', channelId);
    return _rows(res);
  }

  Future<List<Map<String, dynamic>>> channelMessages(
    String channelId, {
    int limit = 300,
  }) async {
    final res = await SupabaseService.client
        .from('chat_messages')
        .select('*')
        .eq('channel_id', channelId)
        .order('created_at', ascending: true)
        .limit(limit);
    return _rows(res);
  }

  Future<Map<String, dynamic>> sendChannelMessage(
    String channelId,
    String body,
  ) async {
    final data = await SupabaseService.client.rpc(
      'send_mention_message',
      params: {
        'p_message_type': 'channel',
        'p_context_id': channelId,
        'p_body': body,
      },
    );
    return _map(data);
  }

  // ---- Groups ----

  Future<List<Map<String, dynamic>>> listGroups() async {
    final res = await SupabaseService.client
        .from('message_groups')
        .select('*, members:message_group_members(member_id, role, added_at)')
        .eq('status', 'active')
        .order('updated_at', ascending: false);
    return _rows(res);
  }

  Future<Map<String, dynamic>> createGroup({
    required String name,
    String? description,
    List<String> memberIds = const [],
  }) async {
    final data = await SupabaseService.client.rpc(
      'create_message_group',
      params: {
        'p_name': name,
        'p_description': description,
        'p_member_ids': memberIds,
      },
    );
    return _map(data);
  }

  Future<void> addGroupMember(String groupId, String memberId) async {
    await SupabaseService.client.rpc(
      'add_group_member',
      params: {'p_group_id': groupId, 'p_member_id': memberId},
    );
  }

  Future<void> removeGroupMember(String groupId, String memberId) async {
    await SupabaseService.client.rpc(
      'remove_group_member',
      params: {'p_group_id': groupId, 'p_member_id': memberId},
    );
  }

  Future<List<Map<String, dynamic>>> groupMembers(String groupId) async {
    final res = await SupabaseService.client
        .from('message_group_members')
        .select('*')
        .eq('group_id', groupId);
    return _rows(res);
  }

  Future<List<Map<String, dynamic>>> groupMessages(
    String groupId, {
    int limit = 300,
  }) async {
    final res = await SupabaseService.client
        .from('chat_messages')
        .select('*')
        .eq('group_id', groupId)
        .order('created_at', ascending: true)
        .limit(limit);
    return _rows(res);
  }

  Future<Map<String, dynamic>> sendGroupMessage(
    String groupId,
    String body,
  ) async {
    final data = await SupabaseService.client.rpc(
      'send_mention_message',
      params: {
        'p_message_type': 'group',
        'p_context_id': groupId,
        'p_body': body,
      },
    );
    return _map(data);
  }

  /// Resolve auth user ids into real employee identities. Mirrors the web
  /// `resolveDirectory()` helper via the same RPC — never renders raw UUIDs.
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
    for (final r in (data as List? ?? [])) {
      final m = _map(r);
      final uid = '${m['user_id']}';
      if (uid.isNotEmpty) map[uid] = m;
    }
    return map;
  }

  String directoryName(Map<String, Map<String, dynamic>> dir, String? userId) {
    final ident = userId == null ? null : dir[userId];
    // The `resolve_user_identity` RPC returns `full_name` + `email`; `name` is
    // kept as a fallback for older cached rows.
    for (final key in const ['full_name', 'name', 'email']) {
      final value = ident?[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return userId == null || userId.isEmpty ? 'Unknown User' : 'Colleague';
  }

  // ---- People (for add-user / new-chat, authoritative employee data) ----

  Future<List<Map<String, dynamic>>> searchPeople(String query) async {
    final q = query.trim();
    final base = SupabaseService.client
        .from('employees')
        .select(
          'id, user_id, full_name, employee_number, branch, department, position, area',
        )
        .eq('is_archived', false);
    final res = q.isEmpty
        ? await base.order('full_name').limit(500)
        : await base.ilike('full_name', '%$q%').order('full_name').limit(500);
    return _rows(res);
  }

  // ---- Realtime ----

  RealtimeChannel subscribeToConversation(
    String field, // 'group_id' | 'channel_id'
    String id,
    void Function(Map<String, dynamic>) onInsert,
  ) {
    return SupabaseService.client
        .channel('conv_$field$id')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: field,
            value: id,
          ),
          callback: (payload) =>
              onInsert(Map<String, dynamic>.from(payload.newRecord)),
        )
        .subscribe();
  }

  Future<Map<String, dynamic>> getOrCreateThread(String otherUserId) async {
    final data = await SupabaseService.client.rpc(
      'get_or_create_chat_thread',
      params: {'p_other_user': otherUserId},
    );
    return _map(data);
  }
}
