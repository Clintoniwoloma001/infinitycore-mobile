import 'package:flutter/material.dart';

import '../../core/routing/app_router.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import 'messages_service.dart';

/// Direct one-to-one thread screen. Offline-first via the ChatService outbox,
/// live-updated through the thread's realtime subscription.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.threadId});

  final String threadId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  List<ChatMessage> _messages = [];
  String _otherName = '';
  bool _loading = true;
  String? _error;
  bool _sending = false;

  String get _me => SupabaseService.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
      final thread = await SupabaseService.client
          .from('chat_threads')
          .select()
          .eq('id', widget.threadId)
          .maybeSingle();
      final messages = await ChatService.instance.listMessages(widget.threadId);
      if (!mounted) return;
      final t = thread is Map ? ChatThread.fromJson(thread) : null;
      setState(() {
        _otherName = t?.otherName ?? '';
        _messages = messages;
      });
      ChatService.instance.subscribeToThread(widget.threadId, _onIncoming);
      _scrollToBottom();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onIncoming(Map<String, dynamic> record) {
    if (!mounted) return;
    final id = '${record['id']}';
    if (_messages.any((m) => m.id == id)) return;
    setState(() {
      _messages = [..._messages, ChatMessage.fromJson(record)];
    });
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
      final optimistic = await ChatService.instance.sendMessage(
        threadId: widget.threadId,
        body: body,
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
    } catch (_) {
      if (mounted) {
        showSnack('Message could not be sent. Try again.', isError: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _otherName.isEmpty ? 'Chat' : _otherName,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
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
                          physics: AlwaysScrollableScrollPhysics(),
                          children: [
                            SizedBox(height: 180),
                            PageEmptyView(
                              title: 'No messages yet',
                              description:
                                  'Say hello and start the conversation.',
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

  Widget _bubble(ChatMessage m) {
    final mine = m.senderId == _me;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          top: 6,
          bottom: 6,
          left: mine ? 48 : 0,
          right: mine ? 0 : 48,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
            if (m.fileUrl.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      m.fileType == 'document'
                          ? Icons.insert_drive_file_outlined
                          : Icons.attachment,
                      size: 14,
                      color: mine ? Colors.white70 : AppColors.blue,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        m.fileUrl,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: mine ? Colors.white70 : AppColors.blue,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              m.body,
              style: TextStyle(
                fontSize: 15,
                height: 1.35,
                color: mine ? Colors.white : AppColors.slate900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              Fmt.timeShort(m.createdAt),
              style: TextStyle(
                fontSize: 10,
                color: mine ? Colors.white60 : Colors.black38,
              ),
            ),
          ],
        ),
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
                hintText: 'Type a message…',
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
