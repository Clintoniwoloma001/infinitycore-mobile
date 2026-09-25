import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/routing/app_router.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import 'communication_service.dart';
import 'create_sheets.dart';
import 'message_ui.dart';
import 'messaging_hub.dart';
import 'messaging_service.dart';

/// What kind of conversation lives at `/messages/…`.
enum ConversationKind { thread, channel, group }

/// A channel or group conversation. Multiple senders are rendered with their
/// resolved identity (never a raw UUID). Live via the shared realtime
/// subscription on `chat_messages`.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key, required this.kind, required this.id});

  final ConversationKind kind;
  final String id;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  List<Map<String, dynamic>> _messages = [];
  Map<String, Map<String, dynamic>> _directory = const {};
  Map<String, List<Map<String, dynamic>>> _reactions = {};
  Map<String, List<Map<String, dynamic>>> _attachments = {};
  String _title = '';
  String _description = '';
  bool _loading = true;
  String? _error;
  bool _sending = false;
  RealtimeChannel? _sub;

  String get _me => SupabaseService.client.auth.currentUser?.id ?? '';
  bool get _isGroup => widget.kind == ConversationKind.group;

  /// Matches the `chat_read_state.conversation_type` vocabulary.
  String get _conversationType =>
      widget.kind == ConversationKind.group ? 'group' : 'channel';

  @override
  void initState() {
    super.initState();
    // Suppress redundant notifications for the conversation on screen.
    MessagingHub.instance.setActiveConversation(
      '$_conversationType:${widget.id}',
    );
    _load();
  }

  @override
  void dispose() {
    MessagingHub.instance.setActiveConversation(null);
    _sub?.unsubscribe();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final meta = await _loadMeta();
      final messages = await (_isGroup
          ? MessagingService.instance.groupMessages(widget.id)
          : MessagingService.instance.channelMessages(widget.id));
      final senderIds = messages
          .map((m) => '${m['sender_id']}')
          .where((e) => e.isNotEmpty)
          .toList();
      final directory = await MessagingService.instance.resolveDirectory(
        senderIds,
      );
      if (!mounted) return;
      setState(() {
        _title = meta['title'] as String? ?? _title;
        _description = '${meta['description'] ?? ''}';
        _messages = messages;
        _directory = directory;
      });
      _loadEnrichment(messages);
      _subscribe();
      _markRead();
      _scrollToBottom();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Map<String, dynamic>> _loadMeta() async {
    if (_isGroup) {
      final res = await SupabaseService.client
          .from('message_groups')
          .select()
          .eq('id', widget.id)
          .maybeSingle();
      final m = res == null ? const {} : Map<String, dynamic>.from(res as Map);
      return {
        'title': '${m['name'] ?? 'Group'}',
        'description': '${m['description'] ?? ''}',
      };
    }
    final res = await SupabaseService.client
        .from('message_channels')
        .select()
        .eq('id', widget.id)
        .maybeSingle();
    final m = res == null ? const {} : Map<String, dynamic>.from(res as Map);
    return {
      'title': '${m['display_name'] ?? m['name'] ?? 'Channel'}',
      'description': '${m['description'] ?? ''}',
    };
  }

  void _subscribe() {
    _sub?.unsubscribe();
    _sub = MessagingService.instance.subscribeToConversation(
      _isGroup ? 'group_id' : 'channel_id',
      widget.id,
      _onIncoming,
    );
  }

  void _onIncoming(Map<String, dynamic> record) {
    if (!mounted) return;
    final id = '${record['id']}';
    if (_messages.any((m) => '${m['id']}' == id)) return;
    final sender = '${record['sender_id']}';
    setState(() {
      _messages = [..._messages, record];
    });
    if (sender.isNotEmpty && !_directory.containsKey(sender)) {
      MessagingService.instance
          .resolveDirectory([sender])
          .then((resolved) {
            if (mounted && resolved.containsKey(sender)) {
              setState(() => _directory = {..._directory, ...resolved});
            }
          })
          .catchError((_) {});
    }
    _scrollToBottom();
    _markRead();
  }

  /// Reactions + attachments are non-critical; a failure leaves the
  /// conversation fully readable without them.
  Future<void> _loadEnrichment(List<Map<String, dynamic>> messages) async {
    final ids = messages
        .map((m) => '${m['id']}')
        .where((e) => e.isNotEmpty)
        .toList();
    if (ids.isEmpty) return;
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
      if (!mounted) return;
      setState(() {
        _reactions = reactions;
        _attachments = attachments;
      });
    } catch (_) {
      // Non-critical enrichment.
    }
  }

  /// Marks the conversation read and refreshes the global badge. Group/channel
  /// read state is written to the caller's own `chat_read_state` row, which is
  /// RLS-restricted to the signed-in user.
  Future<void> _markRead() async {
    try {
      await CommunicationService.instance.markGroupOrChannelRead(
        _conversationType,
        widget.id,
      );
      await MessagingHub.instance.refreshUnread();
    } catch (_) {
      // Read state is best effort.
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

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _sending) return;
    _controller.clear();
    setState(() => _sending = true);
    try {
      if (_isGroup) {
        await MessagingService.instance.sendGroupMessage(widget.id, body);
      } else {
        await MessagingService.instance.sendChannelMessage(widget.id, body);
      }
    } catch (_) {
      if (mounted) {
        showSnack('Message could not be sent. Try again.', isError: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _shareInvite() async {
    final kindLabel = _isGroup ? ' group' : ' channel';
    final text = MessagingService.buildInviteText(
      kindLabel,
      _title.isEmpty ? _title : '#$_title',
    );
    await SharePlus.instance.share(ShareParams(text: text));
  }

  void _openInfo() {
    showConversationInfoSheet(
      context,
      kind: _isGroup ? 'group' : 'channel',
      id: widget.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (_description.isNotEmpty)
              Text(
                _description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
          ],
        ),
        titleTextStyle: const TextStyle(
          color: AppColors.slate900,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        actions: [
          IconButton(
            tooltip: 'Share invite',
            onPressed: _shareInvite,
            icon: const Icon(Icons.share_outlined, color: AppColors.green),
          ),
          IconButton(
            tooltip: 'Info & members',
            onPressed: _openInfo,
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: _loading
          ? PageLoadingView(
              label: _isGroup ? 'Loading group…' : 'Loading channel…',
            )
          : _error != null
          ? PageErrorView(message: _error!, onRetry: _load)
          : Column(
              children: [
                Expanded(
                  child: _messages.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            const SizedBox(height: 180),
                            PageEmptyView(
                              title: _isGroup
                                  ? 'No group messages yet'
                                  : 'No channel messages yet',
                              description:
                                  'Share the first update with your team.',
                            ),
                          ],
                        )
                      : ListView(
                          controller: _scroll,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16),
                          children: [for (final m in _messages) _bubble(m)],
                        ),
                ),
                _inputBar(context),
              ],
            ),
    );
  }

  Widget _bubble(Map<String, dynamic> raw) {
    final senderId = '${raw['sender_id']}';
    final mine = senderId == _me;
    final id = '${raw['id']}';
    final byEmoji = <String, List<String>>{};
    for (final r in _reactions[id] ?? const <Map<String, dynamic>>[]) {
      final emoji = '${r['emoji'] ?? ''}';
      if (emoji.isEmpty) continue;
      byEmoji.putIfAbsent(emoji, () => []).add('${r['user_id']}');
    }

    return MessageBubble(
      message: raw,
      isMine: mine,
      senderName: MessagingService.instance.directoryName(_directory, senderId),
      attachments: _attachments[id] ?? const [],
      reactions: byEmoji,
      myUserId: _me,
      onLongPress: () => _showActions(raw),
      onToggleReaction: (emoji, mineReaction) => _runAction(
        mineReaction ? 'Reaction removed' : 'Reaction added',
        () => mineReaction
            ? CommunicationService.instance.removeReaction(id, emoji)
            : CommunicationService.instance.addReaction(id, emoji),
      ),
    );
  }

  Future<void> _runAction(String label, Future<void> Function() action) async {
    try {
      await action();
      if (!mounted) return;
      showSnack(label);
      await _loadEnrichment(_messages);
    } catch (e) {
      if (!mounted) return;
      showSnack(
        CommunicationService.friendlyError(
          e,
          fallback: 'That action could not be completed.',
        ),
        isError: true,
      );
    }
  }

  /// Copy / react / bookmark / pin / edit / delete / report, mirroring the web
  /// message action set. Authorization stays server-side on each RPC.
  Future<void> _showActions(Map<String, dynamic> raw) async {
    final id = '${raw['id']}';
    final body = '${raw['body'] ?? ''}';
    final mine = '${raw['sender_id']}' == _me;
    final pinned = raw['is_pinned'] == true || raw['is_pinned'] == 'true';

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Copy message'),
              onTap: () {
                Navigator.of(sheet).pop();
                copyToClipboard(context, body);
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: Text(pinned ? 'Unpin message' : 'Pin message'),
              onTap: () {
                Navigator.of(sheet).pop();
                _runAction(
                  pinned ? 'Message unpinned' : 'Message pinned',
                  () => pinned
                      ? CommunicationService.instance.unpinMessage(id)
                      : CommunicationService.instance.pinMessage(id),
                );
              },
            ),
            if (mine) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _edit(raw);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel),
                title: const Text('Delete'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _delete(raw);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded),
              title: const Text('Report'),
              onTap: () {
                Navigator.of(sheet).pop();
                _report(raw);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(Map<String, dynamic> raw) async {
    final id = '${raw['id']}';
    final controller = TextEditingController(text: '${raw['body'] ?? ''}');
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
    if (result == null || result.isEmpty || result == '${raw['body'] ?? ''}') {
      return;
    }
    await _runAction(
      'Message updated',
      () => CommunicationService.instance.editMessage(id, result),
    );
  }

  Future<void> _delete(Map<String, dynamic> raw) async {
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
      () => CommunicationService.instance.deleteMessage('${raw['id']}'),
    );
  }

  Future<void> _report(Map<String, dynamic> raw) async {
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
        '${raw['id']}',
        'inappropriate',
        details: details,
      ),
    );
  }

  Widget _inputBar(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Message $_title…',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _sending ? null : _send,
            style: IconButton.styleFrom(
              backgroundColor: AppColors.green,
              disabledBackgroundColor: AppColors.green.withValues(alpha: 0.4),
            ),
            icon: const Icon(Icons.send, color: Colors.white),
          ),
        ],
      ),
    );
  }
}
