import 'package:flutter/material.dart';

import '../../core/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import 'sara_chat_service.dart';

class SaraScreen extends StatefulWidget {
  const SaraScreen({super.key});

  @override
  State<SaraScreen> createState() => _SaraScreenState();
}

class _SaraScreenState extends State<SaraScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<SaraMessage> _messages = [];
  List<String>? _summaryBullets;
  bool _busy = false;
  String? _summaryError;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
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

  Future<void> _loadSummary() async {
    setState(() => _summaryError = null);
    try {
      final result = await SaraChatService.instance.requestSummary(
        route: AuthService.instance.access.accessModules.isEmpty
            ? ''
            : 'dashboard',
      );
      if (mounted) {
        setState(() => _summaryBullets = result.bullets);
        _summaryError = null;
      }
    } catch (e) {
      if (mounted) setState(() => _summaryError = e.toString());
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    _controller.clear();
    setState(() {
      _messages.add(SaraMessage(role: 'user', content: text));
      _busy = true;
    });
    _scrollToBottom();
    try {
      final result = await SaraChatService.instance.requestReply(
        message: text,
        history: _messages,
        route: '',
      );
      if (mounted) {
        setState(() {
          _messages.add(SaraMessage(role: 'assistant', content: result.reply));
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _messages.isEmpty && _summaryBullets == null
              ? _EmptySara(onSummary: _loadSummary)
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_summaryBullets != null)
                      _SummaryCard(bullets: _summaryBullets!),
                    if (_summaryError != null)
                      _InlineError(message: _summaryError!),
                    for (final m in _messages) _SaraBubble(message: m),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'SARA is thinking…',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black45,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: Icon(Icons.bolt, color: AppColors.green, size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: 'Ask SARA anything…',
                    hintStyle: const TextStyle(
                      fontSize: 13,
                      color: Colors.black38,
                    ),
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: Color(0xFFE8EDF4)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: AppColors.green),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _busy ? null : _send,
                style: IconButton.styleFrom(backgroundColor: AppColors.green),
                icon: const Icon(
                  Icons.arrow_upward,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptySara extends StatelessWidget {
  const _EmptySara({required this.onSummary});

  final VoidCallback onSummary;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.green, Color(0xFF00C46C)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.bolt, color: Colors.white, size: 36),
          ),
          const SizedBox(height: 12),
          const Text(
            'SARA',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const Text(
            'Your InfinityCore awareness assistant',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onSummary,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Summarise my context'),
          ),
          const SizedBox(height: 20),
          const _ChipRow(),
        ],
      ),
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow();

  static const _hints = [
    ('How many people are at work today?', Icons.schedule),
    ('Any exceptions I should know about?', Icons.warning_amber),
    ('Summarise my leave balance', Icons.event_note),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (text, icon) in _hints)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ActionChip(
                avatar: Icon(icon, size: 16, color: AppColors.green),
                label: Text(text, style: const TextStyle(fontSize: 12)),
                onPressed: () {},
              ),
            ),
          ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.bullets});

  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.auto_awesome, size: 14, color: AppColors.green),
              SizedBox(width: 6),
              Text(
                'SARA summary',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppColors.greenDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final b in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '• ',
                    style: TextStyle(color: AppColors.green, fontSize: 13),
                  ),
                  Expanded(
                    child: Text(b, style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.rose.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        style: const TextStyle(fontSize: 12, color: AppColors.rose),
      ),
    );
  }
}

class _SaraBubble extends StatelessWidget {
  const _SaraBubble({required this.message});

  final SaraMessage message;

  @override
  Widget build(BuildContext context) {
    final fromUser = message.role == 'user';
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          color: fromUser ? AppColors.green : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(fromUser ? 14 : 4),
            bottomRight: Radius.circular(fromUser ? 4 : 14),
          ),
        ),
        child: Text(
          message.content,
          style: TextStyle(
            fontSize: 13,
            height: 1.35,
            color: fromUser ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }
}
