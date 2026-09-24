import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../shared/models/models.dart';

class _OutboxItem {
  final String threadId;
  final String body;
  final String queuedAt;

  _OutboxItem({
    required this.threadId,
    required this.body,
    required this.queuedAt,
  });

  Map<String, dynamic> toJson() => {
    'thread_id': threadId,
    'body': body,
    'queued_at': queuedAt,
  };
}

/// Internal chat client. Mirrors `chatService.js`:
///   - network writes go through RPCs (server-authoritative)
///   - sends are optimistic + queued to a persisted outbox when offline
///   - realtime subscriptions keep open threads live
class ChatService {
  ChatService._();
  static final ChatService instance = ChatService._();

  final List<_OutboxItem> _outbox = [];

  File _outboxFile(String userId) => File(
    '${Directory.systemTemp.path}/infinitycore_chat_outbox_$userId.json',
  );

  List<Map<String, dynamic>> readOutbox() {
    final me = SupabaseService.client.auth.currentUser;
    if (me == null) return [];
    final file = _outboxFile(me.id);
    try {
      if (file.existsSync()) {
        final parsed = jsonDecode(file.readAsStringSync());
        if (parsed is List) {
          _outbox
            ..clear()
            ..addAll(
              parsed.map((e) {
                final m = Map<String, dynamic>.from(e as Map);
                return _OutboxItem(
                  threadId: '${m['thread_id']}',
                  body: '${m['body'] ?? ''}',
                  queuedAt: '${m['queued_at'] ?? ''}',
                );
              }),
            );
        }
      }
    } catch (_) {}
    return _outbox.map((e) => e.toJson()).toList();
  }

  void _writeOutbox() {
    final me = SupabaseService.client.auth.currentUser;
    if (me == null) return;
    final file = _outboxFile(me.id);
    try {
      final sliced = _outbox.length > 200
          ? _outbox.sublist(_outbox.length - 200)
          : _outbox;
      file.writeAsStringSync(
        jsonEncode(sliced.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  static String pairKey(String a, String b) =>
      a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

  Future<Map<String, dynamic>> getOrCreateThread(String otherUserId) async {
    try {
      final data = await SupabaseService.client.rpc(
        'get_or_create_chat_thread',
        params: {'p_other_user': otherUserId},
      );
      return data is Map
          ? Map<String, dynamic>.from(data)
          : <String, dynamic>{};
    } on PostgrestException catch (e) {
      throw StateError(e.message);
    }
  }

  Future<List<ChatThread>> listMyThreads() async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return [];
    readOutbox();
    final res = await SupabaseService.client
        .from('chat_threads')
        .select()
        .or('member_a.eq.${user.id},member_b.eq.${user.id}')
        .order('last_message_at', ascending: false);
    return (res as List<dynamic>? ?? []).map(ChatThread.fromJson).toList();
  }

  Future<List<ChatMessage>> listMessages(
    String threadId, {
    int limit = 200,
  }) async {
    final res = await SupabaseService.client
        .from('chat_messages')
        .select()
        .eq('thread_id', threadId)
        .order('created_at')
        .limit(limit);
    return (res as List<dynamic>? ?? []).map(ChatMessage.fromJson).toList();
  }

  Future<void> _sendNow(String threadId, String body) async {
    await SupabaseService.client.rpc(
      'send_chat_message',
      params: {'p_thread_id': threadId, 'p_body': body},
    );
  }

  /// Offline-first send. Returns `queued` so the UI renders instantly.
  Future<ChatMessage> sendMessage({
    required String threadId,
    required String body,
    required String senderId,
  }) async {
    final min = DateTime.now();
    final optimistic = ChatMessage(
      id: 'optimistic_${min.millisecondsSinceEpoch}_${min.microsecond}',
      threadId: threadId,
      senderId: senderId,
      body: body,
      createdAt: min.toIso8601String(),
    );
    try {
      await _sendNow(threadId, body);
    } catch (_) {
      readOutbox();
      _outbox.add(
        _OutboxItem(
          threadId: threadId,
          body: body,
          queuedAt: min.toIso8601String(),
        ),
      );
      _writeOutbox();
    }
    return optimistic;
  }

  /// Flush any messages queued while offline.
  Future<({int sent, int remaining})> syncOutbox() async {
    if (_outbox.isEmpty) return (sent: 0, remaining: 0);
    int sent = 0;
    final remaining = <_OutboxItem>[];
    for (final item in _outbox) {
      try {
        await _sendNow(item.threadId, item.body);
        sent += 1;
      } catch (_) {
        remaining.add(item);
      }
    }
    _outbox
      ..clear()
      ..addAll(remaining);
    _writeOutbox();
    return (sent: sent, remaining: remaining.length);
  }

  RealtimeChannel subscribeToThread(
    String threadId,
    void Function(Map<String, dynamic> payload) onMessage,
  ) {
    return SupabaseService.client
        .channel('chat_thread_$threadId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'thread_id',
            value: threadId,
          ),
          callback: (payload) {
            onMessage(Map<String, dynamic>.from(payload.newRecord));
          },
        )
        .subscribe();
  }
}
