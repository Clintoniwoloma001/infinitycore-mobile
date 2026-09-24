import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/routing/app_router.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import 'create_sheets.dart';
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
  String _title = '';
  String _description = '';
  bool _loading = true;
  String? _error;
  bool _sending = false;
  RealtimeChannel? _sub;

  String get _me => SupabaseService.client.auth.currentUser?.id ?? '';
  bool get _isGroup => widget.kind == ConversationKind.group;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
      _subscribe();
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
      if (mounted)
        showSnack('Message could not be sent. Try again.', isError: true);
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
    final body = '${raw['body'] ?? ''}';
    final createdAt = '${raw['created_at'] ?? ''}';
    final name = MessagingService.instance.directoryName(_directory, senderId);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!mine) ...[
          AvatarCircle(name: name, size: 32),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: mine ? AppColors.green : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(14),
                topRight: const Radius.circular(14),
                bottomLeft: Radius.circular(mine ? 14 : 4),
                bottomRight: Radius.circular(mine ? 4 : 14),
              ),
              border: mine ? null : Border.all(color: const Color(0xFFE8EDF4)),
            ),
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!mine)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      name,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.blue,
                      ),
                    ),
                  ),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: mine ? Colors.white : AppColors.slate900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  Fmt.timeShort(createdAt),
                  style: TextStyle(
                    fontSize: 10,
                    color: mine ? Colors.white60 : Colors.black38,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (mine) const SizedBox(width: 8),
      ],
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
