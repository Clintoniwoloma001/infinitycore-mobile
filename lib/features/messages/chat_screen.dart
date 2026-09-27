import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/app_router.dart';
import '../../core/services/supabase_service.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/common.dart';
import 'communication_service.dart';
import 'message_composer.dart';
import 'message_ui.dart';
import 'messages_service.dart';
import 'messaging_hub.dart';
import 'urgent_ack_service.dart';

/// Direct one-to-one thread screen.
///
/// Preserves the existing offline-first outbox and realtime subscription, and
/// layers the web feature set on top: read-state sync, reactions, edit/delete/
/// copy, per-message read receipts, attachments, and an employee profile sheet
/// with a phone-call action.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.threadId});

  final String threadId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll = ScrollController();

  List<ChatMessage> _messages = [];
  Map<String, Map<String, dynamic>> _directory = const {};
  Map<String, List<Map<String, dynamic>>> _reactions = {};
  Map<String, List<Map<String, dynamic>>> _attachments = {};

  /// message_id → `chat_message_acks` rows, used to render the "N of M
  /// acknowledged" line and to decide whether the local user still owes one.
  Map<String, List<Map<String, dynamic>>> _acks = {};

  Map<String, dynamic> _other = const {};
  String _otherName = '';
  bool _muted = false;
  bool _loading = true;
  String? _error;

  String get _me => SupabaseService.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    // Tell the hub this conversation is on screen so incoming messages update
    // in place instead of raising a redundant notification.
    MessagingHub.instance.setActiveConversation('direct:${widget.threadId}');
    _load();
  }

  @override
  void dispose() {
    MessagingHub.instance.setActiveConversation(null);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final thread = await SupabaseService.client
          .from('chat_threads')
          .select('*')
          .eq('id', widget.threadId)
          .maybeSingle();
      final messages = await ChatService.instance.listMessages(widget.threadId);
      if (!mounted) return;

      final t = thread is Map
          ? Map<String, dynamic>.from(thread as Map)
          : <String, dynamic>{};
      final me = _me;
      final otherId = me.isEmpty
          ? ''
          : (t['member_a'] == me ? '${t['member_b']}' : '${t['member_a']}');

      // Enrichment is best effort: a failure here must not stop the
      // conversation from rendering.
      var dir = const <String, Map<String, dynamic>>{};
      var reactions = <String, List<Map<String, dynamic>>>{};
      var attachments = <String, List<Map<String, dynamic>>>{};
      var acks = <String, List<Map<String, dynamic>>>{};
      var muted = false;
      try {
        dir = await CommunicationService.instance.resolveDirectory([
          otherId,
          for (final m in messages) m.senderId,
        ]);
        final ids = messages.map((m) => m.id).toList();
        for (final row in await CommunicationService.instance.reactionsFor(
          ids,
        )) {
          reactions.putIfAbsent('${row['message_id']}', () => []).add(row);
        }
        for (final row in await CommunicationService.instance.attachmentsFor(
          ids,
        )) {
          attachments.putIfAbsent('${row['message_id']}', () => []).add(row);
        }
        for (final row in await CommunicationService.instance.acksFor(ids)) {
          acks.putIfAbsent('${row['message_id']}', () => []).add(row);
        }
      } catch (_) {}

      try {
        final settings = await SupabaseService.client
            .from('chat_thread_user_settings')
            .select('is_muted')
            .eq('thread_id', widget.threadId)
            .eq('user_id', _me)
            .maybeSingle();
        // `maybeSingle()` returns null when no settings row exists yet, which
        // means the thread has never been muted.
        final s = settings;
        muted = s != null && s['is_muted'] == true;
      } catch (_) {}

      if (!mounted) return;
      final identity = dir[otherId] ?? const <String, dynamic>{};
      setState(() {
        _directory = dir;
        _reactions = reactions;
        _attachments = attachments;
        _acks = acks;
        _muted = muted;
        _other = identity;
        _otherName = '${identity['full_name'] ?? identity['email'] ?? ''}'
            .trim();
        _messages = messages;
      });
      ChatService.instance.subscribeToThread(widget.threadId, _onIncoming);
      _markRead();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = CommunicationService.friendlyError(
            e,
            fallback: 'This conversation could not be opened.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onIncoming(Map<String, dynamic> record) {
    if (!mounted) return;
    final id = '${record['id']}';
    // Realtime can replay an optimistic local echo; de-duplicate by id so the
    // bubble never appears twice.
    if (_messages.any((m) => m.id == id)) return;
    setState(() => _messages = [..._messages, ChatMessage.fromJson(record)]);
    _scrollToBottom();
    _markRead();
  }

  Future<void> _markRead() async {
    try {
      await CommunicationService.instance.markDirectThreadRead(widget.threadId);
      await MessagingHub.instance.refreshUnread();
    } catch (_) {
      // Read state is best effort; never interrupt the conversation.
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Sends a composed message.
  ///
  /// A plain text message keeps the existing offline-first outbox so a message
  /// typed on the underground still arrives later. Anything with a priority, an
  /// acknowledgment requirement or an attachment goes through
  /// `send_rich_message`, which cannot be queued locally: the server has to
  /// write the `message_attachments` rows and open the acknowledgment
  /// obligations atomically with the message, so a failure is reported to the
  /// user instead of being silently retried later.
  Future<void> _send(MessageDraft draft) async {
    if (!draft.isRich) {
      final optimistic = await ChatService.instance.sendMessage(
        threadId: widget.threadId,
        body: draft.body,
        senderId: _me,
      );
      if (mounted) {
        setState(() {
          _messages = [
            ..._messages.where((m) => !m.id.startsWith('optimistic_')),
            optimistic,
          ];
        });
        _scrollToBottom();
      }
      return;
    }

    try {
      await CommunicationService.instance.sendRichMessage(
        contextType: 'direct',
        contextId: widget.threadId,
        body: draft.body,
        priority: draft.priority,
        requiresAck: draft.requiresAck,
        files: draft.rpcFiles,
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(
        CommunicationService.friendlyError(
          e,
          fallback: 'That message could not be sent. Your text is still here — try again.',
        ),
        isError: true,
      );
      rethrow;
    }

    // The RPC returns the created row(s); a reload is the simplest way to pick
    // up the server-assigned id, the `priority`/`requires_ack` columns and the
    // attachment rows without duplicating the RPC's return shape here.
    await _load();
    if (draft.requiresAck) {
      // Refresh the gate so the recipient-facing obligation is reflected for
      // the sender's own queue too (e.g. they also owe someone else an ack).
      UrgentAckService.instance.refresh();
    }
  }

  // ------------------------------------------------------------------
  // Message actions
  // ------------------------------------------------------------------

  Future<void> _reloadEnrichment() async {
    final ids = _messages.map((m) => m.id).toList();
    try {
      final reactions = <String, List<Map<String, dynamic>>>{};
      for (final row in await CommunicationService.instance.reactionsFor(ids)) {
        reactions.putIfAbsent('${row['message_id']}', () => []).add(row);
      }
      final attachments = <String, List<Map<String, dynamic>>>{};
      for (final row in await CommunicationService.instance.attachmentsFor(
        ids,
      )) {
        attachments.putIfAbsent('${row['message_id']}', () => []).add(row);
      }
      final acks = <String, List<Map<String, dynamic>>>{};
      for (final row in await CommunicationService.instance.acksFor(ids)) {
        acks.putIfAbsent('${row['message_id']}', () => []).add(row);
      }
      if (mounted) {
        setState(() {
          _reactions = reactions;
          _attachments = attachments;
          _acks = acks;
        });
      }
    } catch (_) {
      // Enrichment is non-critical.
    }
  }

  /// Runs [action], showing [label] on success and a friendly error on failure.
  ///
  /// Returns `true` only when the action actually completed, so callers can
  /// chain follow-up refreshes without duplicating the try/catch.
  Future<bool> _runAction(
    String label,
    Future<void> Function() action, {
    bool reload = true,
  }) async {
    try {
      await action();
      if (!mounted) return false;
      showSnack(label);
      if (reload) await _reloadEnrichment();
      return true;
    } catch (e) {
      if (!mounted) return false;
      showSnack(
        CommunicationService.friendlyError(
          e,
          fallback: 'That action could not be completed.',
        ),
        isError: true,
      );
      return false;
    }
  }

  Future<void> _toggleReaction(ChatMessage m) async {
    final emoji = await pickReactionEmoji(context);
    if (emoji == null) return;
    final mine = (_reactions[m.id] ?? [])
        .where((r) => r['user_id'] == _me)
        .any((r) => r['emoji'] == emoji);
    await _runAction(
      mine ? 'Reaction removed' : 'Reaction added',
      () => mine
          ? CommunicationService.instance.removeReaction(m.id, emoji)
          : CommunicationService.instance.addReaction(m.id, emoji),
    );
  }

  Future<void> _edit(ChatMessage m) async {
    final controller = TextEditingController(text: m.body);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: controller,
          minLines: 2,
          maxLines: 6,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty || result == m.body) return;
    await _runAction(
      'Message updated',
      () => CommunicationService.instance.editMessage(m.id, result),
    );
  }

  Future<void> _delete(ChatMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text(
          'This removes the message for everyone. The record is retained for '
          'audit purposes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runAction(
      'Message deleted',
      () => CommunicationService.instance.deleteMessage(m.id),
    );
  }

  Future<void> _report(ChatMessage m) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Report message'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'What is wrong with this message?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Report'),
          ),
        ],
      ),
    );
    final details = controller.text.trim();
    controller.dispose();
    if (ok != true || details.isEmpty) return;
    await _runAction(
      'Report submitted',
      () => CommunicationService.instance.reportMessage(
        m.id,
        'inappropriate',
        details: details,
      ),
    );
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    setState(() => _muted = next);
    await _runAction(
      next ? 'Conversation muted' : 'Conversation unmuted',
      () => CommunicationService.instance.setThreadMuted(widget.threadId, next),
      reload: false,
    );
  }

  Future<void> _archive() async {
    await _runAction(
      'Conversation archived',
      () => CommunicationService.instance.deleteThreadForMe(widget.threadId),
      reload: false,
    );
    if (!mounted) return;
    if (context.canPop()) context.pop();
  }

  Future<void> _showActions(ChatMessage m) async {
    final mine = m.senderId == _me;
    final pinned = m.raw['is_pinned'] == true || m.raw['is_pinned'] == 'true';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: const Text('Copy message'),
              onTap: () {
                Navigator.of(sheet).pop();
                copyToClipboard(context, m.body);
              },
            ),
            ListTile(
              leading: const Icon(Icons.face_outlined),
              title: const Text('React'),
              onTap: () {
                Navigator.of(sheet).pop();
                _toggleReaction(m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('Bookmark'),
              onTap: () {
                Navigator.of(sheet).pop();
                _runAction(
                  'Bookmark updated',
                  () => CommunicationService.instance.toggleBookmark(m.id),
                  reload: false,
                );
              },
            ),
            ListTile(
              leading: Icon(
                pinned ? Icons.check_circle : Icons.check_circle_outline,
              ),
              title: Text(pinned ? 'Unpin message' : 'Pin message'),
              onTap: () {
                Navigator.of(sheet).pop();
                _runAction(
                  pinned ? 'Message unpinned' : 'Message pinned',
                  () => pinned
                      ? CommunicationService.instance.unpinMessage(m.id)
                      : CommunicationService.instance.pinMessage(m.id),
                  reload: false,
                );
              },
            ),
            if (mine) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _edit(m);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel),
                title: const Text('Delete'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _delete(m);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded),
              title: const Text('Report'),
              onTap: () {
                Navigator.of(sheet).pop();
                _report(m);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showProfile() {
    if (_other.isEmpty) return;
    showEmployeeProfileSheet(context, identity: _other);
  }

  @override
  Widget build(BuildContext context) {
    final hasPhone = '${_other['phone'] ?? ''}'.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: _showProfile,
          child: Row(
            children: [
              AvatarCircle(
                name: _otherName,
                size: 34,
                onTap: _showProfile,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _otherName.isEmpty ? 'Chat' : _otherName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${_other['position'] ?? _other['department'] ?? ''}'
                          .trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          // Only offer the phone-call action when a valid number exists.
          if (hasPhone)
            IconButton(
              tooltip: 'Call',
              icon: const Icon(Icons.phone_android),
              onPressed: () async {
                final ok = await placePhoneCall('${_other['phone']}');
                if (!ok && context.mounted) {
                  showSnack(
                    'This device cannot place phone calls.',
                    isError: true,
                  );
                }
              },
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'mute') {
                _toggleMute();
              } else if (value == 'archive') {
                _archive();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'mute',
                child: Text(
                  _muted ? 'Unmute conversation' : 'Mute conversation',
                ),
              ),
              const PopupMenuItem(
                value: 'archive',
                child: Text('Archive conversation'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const PageLoadingView(label: 'Loading chat…')
          : _error != null
          ? PageErrorView(message: _error!, onRetry: _load)
          : Column(
              children: [
                Expanded(
                  child: _messages.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 180),
                            PageEmptyView(
                              title: 'No messages yet',
                              description:
                                  'Say hello and start the conversation.',
                            ),
                          ],
                        )
                      : ListView.builder(
                          controller: _scroll,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) => _bubble(_messages[i]),
                        ),
                ),
                _inputBar(context),
              ],
            ),
    );
  }

  /// message_id -> emoji -> user ids, as [MessageBubble] expects.
  Map<String, List<String>> _reactionsFor(String messageId) {
    final byEmoji = <String, List<String>>{};
    for (final r in _reactions[messageId] ?? const <Map<String, dynamic>>[]) {
      final emoji = '${r['emoji'] ?? ''}';
      if (emoji.isEmpty) continue;
      byEmoji.putIfAbsent(emoji, () => []).add('${r['user_id']}');
    }
    return byEmoji;
  }

  Widget _bubble(ChatMessage m) {
    final mine = m.senderId == _me;
    final acks = _acks[m.id] ?? const <Map<String, dynamic>>[];
    final needsMyAck = CommunicationService.ackRequired(m.raw, acks, _me);
    return MessageBubble(
      message: m.raw,
      isMine: mine,
      senderName: '${_directory[m.senderId]?['full_name'] ?? 'Colleague'}',
      attachments: _attachments[m.id] ?? const [],
      reactions: _reactionsFor(m.id),
      myUserId: _me,
      acks: acks,
      needsMyAck: needsMyAck,
      onAcknowledge: needsMyAck
          ? () => _acknowledge(m)
          : null,
      onLongPress: () => _showActions(m),
      onToggleReaction: (emoji, mineReaction) => _runAction(
        mineReaction ? 'Reaction removed' : 'Reaction added',
        () => mineReaction
            ? CommunicationService.instance.removeReaction(m.id, emoji)
            : CommunicationService.instance.addReaction(m.id, emoji),
      ),
    );
  }

  /// Records the local user's acknowledgment and refreshes both the in-thread
  /// ack tally and the global blocking gate.
  Future<void> _acknowledge(ChatMessage m) async {
    final ok = await _runAction(
      'Acknowledged',
      () => CommunicationService.instance.acknowledgeMessage(m.id),
    );
    if (!ok) return;
    await _reloadEnrichment();
    await UrgentAckService.instance.refresh();
  }

  /// The composer. `MessageComposer` owns its own text field, attachment strip
  /// and recorder, so the screen no longer keeps a controller or send flag.
  Widget _inputBar(BuildContext context) => MessageComposer(
    contextType: 'direct',
    contextId: widget.threadId,
    onSend: _send,
  );
}
