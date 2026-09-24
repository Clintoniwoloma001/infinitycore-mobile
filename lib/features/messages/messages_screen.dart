import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';
import 'create_sheets.dart';
import 'messages_service.dart';
import 'messaging_service.dart';

/// Internal chat + channels + groups hub. Mirrors the web messaging hub:
///   - Chats tab: direct one-to-one threads (server-authoritative RPCs)
///   - Channels tab: organisation channels incl. automatic branch/dept/role
///     membership (managed server-side)
///   - Groups tab: user-created groups with member management
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: 0,
  );

  List<ChatThread> _threads = [];
  List<Map<String, dynamic>> _channels = [];
  List<Map<String, dynamic>> _groups = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      MessagingService.instance.ensureOrganizational().catchError(
        (_) => const <String, dynamic>{},
      );
      final threads = ChatService.instance.listMyThreads();
      final channels = MessagingService.instance.listChannels();
      final groups = MessagingService.instance.listGroups();
      final threadsDone = await threads;
      if (!mounted) return;
      final channelsDone = await channels;
      final groupsDone = await groups;
      if (!mounted) return;
      setState(() {
        _threads = threadsDone;
        _channels = channelsDone;
        _groups = groupsDone;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openThread(BuildContext context, String threadId) async {
    await context.push('/messages/$threadId');
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: 'Messages'),
      body: _loading
          ? const PageLoadingView(label: 'Loading messages…')
          : _error != null
          ? PageErrorView(message: _error!, onRetry: _load)
          : Column(
              children: [
                TabBar(
                  controller: _tabs,
                  tabs: const [
                    Tab(text: 'Chats'),
                    Tab(text: 'Channels'),
                    Tab(text: 'Groups'),
                  ],
                  labelColor: AppColors.green,
                  unselectedLabelColor: Colors.black54,
                  indicatorColor: AppColors.green,
                  indicatorSize: TabBarIndicatorSize.tab,
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _ThreadList(
                        threads: _threads,
                        onRefresh: _load,
                        onOpenThread: (id) => _openThread(context, id),
                        onNewChat: () => showPersonPickerSheet(
                          context,
                          title: 'Start a conversation',
                          onPick: (userId) async {
                            final thread = await MessagingService.instance
                                .getOrCreateThread(userId);
                            final threadId = '${thread['id'] ?? ''}';
                            if (threadId.isEmpty) {
                              if (context.mounted) {
                                showSnack('Conversation could not be opened.');
                              }
                              return;
                            }
                            if (context.mounted) {
                              await context.push('/messages/$threadId');
                            }
                          },
                        ),
                      ),
                      _ChannelList(
                        channels: _channels,
                        onRefresh: _load,
                        onOpenChannel: (id, title) async {
                          await MessagingService.instance
                              .syncAutoMembers(id)
                              .catchError((_) => false);
                          if (context.mounted) {
                            await context.push('/messages/channel/$id');
                          }
                          if (mounted) await _load();
                        },
                        onCreate: () => showCreateChannelSheet(
                          context,
                          onCreated: (id) async {
                            if (context.mounted) {
                              await context.push('/messages/channel/$id');
                            }
                            if (mounted) await _load();
                          },
                        ),
                      ),
                      _GroupList(
                        groups: _groups,
                        onRefresh: _load,
                        onOpenGroup: (id) async {
                          if (context.mounted) {
                            await context.push('/messages/group/$id');
                          }
                          if (mounted) await _load();
                        },
                        onCreate: () => showCreateGroupSheet(
                          context,
                          onCreated: (id) async {
                            if (context.mounted) {
                              await context.push('/messages/group/$id');
                            }
                            if (mounted) await _load();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _ThreadList extends StatelessWidget {
  const _ThreadList({
    required this.threads,
    required this.onRefresh,
    required this.onOpenThread,
    required this.onNewChat,
  });

  final List<ChatThread> threads;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onOpenThread;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: onRefresh,
          child: threads.isEmpty
              ? ListView(
                  physics: AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(height: 200),
                    PageEmptyView(
                      title: 'No conversations yet',
                      description: 'Start a new chat with a colleague using the compose button.',
                    ),
                  ],
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                  itemCount: threads.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final t = threads[i];
                    return Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        onTap: () => onOpenThread(t.id),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              AvatarCircle(name: t.otherName, size: 44),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t.otherName,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (t.lastMessage.isNotEmpty)
                                      Text(
                                        t.lastMessage,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.black54,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (t.lastMessageAt.isNotEmpty)
                                Text(
                                  Fmt.dateTimeShort(t.lastMessageAt),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Colors.black38,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Positioned(
          right: 16,
          bottom: 20,
          child: FloatingActionButton.small(
            backgroundColor: AppColors.green,
            foregroundColor: Colors.white,
            heroTag: 'new_chat',
            onPressed: onNewChat,
            child: const Icon(Icons.add_comment_outlined),
          ),
        ),
      ],
    );
  }
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.channels,
    required this.onRefresh,
    required this.onOpenChannel,
    required this.onCreate,
  });

  final List<Map<String, dynamic>> channels;
  final Future<void> Function() onRefresh;
  final void Function(String id, String title) onOpenChannel;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: onRefresh,
          child: channels.isEmpty
              ? ListView(
                  physics: AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(height: 200),
                    PageEmptyView(
                      title: 'No channels yet',
                      description:
                          'Organisational channels (branch, dept, role) sync '
                          'automatically when HR creates them.',
                    ),
                  ],
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                  itemCount: channels.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final c = channels[i];
                    final name =
                        '${c['display_name'] ?? c['name'] ?? 'Channel'}';
                    return _ConversationTile(
                      icon: Icons.campaign_outlined,
                      iconColor: AppColors.blue,
                      title: name,
                      subtitle: '${c['description'] ?? ''}',
                      trailing: Text(
                        Fmt.titleCase('${c['channel_type'] ?? 'team'}'),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.black45,
                        ),
                      ),
                      onTap: () =>
                          onOpenChannel(c['id']?.toString() ?? '', name),
                    );
                  },
                ),
        ),
        Positioned(
          right: 16,
          bottom: 20,
          child: FloatingActionButton.small(
            backgroundColor: AppColors.green,
            foregroundColor: Colors.white,
            heroTag: 'new_channel',
            onPressed: onCreate,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}

class _GroupList extends StatelessWidget {
  const _GroupList({
    required this.groups,
    required this.onRefresh,
    required this.onOpenGroup,
    required this.onCreate,
  });

  final List<Map<String, dynamic>> groups;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onOpenGroup;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: onRefresh,
          child: groups.isEmpty
              ? ListView(
                  physics: AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(height: 200),
                    PageEmptyView(
                      title: 'No groups yet',
                      description: 'Create a group to chat with several colleagues at once.',
                    ),
                  ],
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                  itemCount: groups.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final g = groups[i];
                    final members = g['members'];
                    final count = members is List ? members.length : 0;
                    final desc = '${g['description'] ?? ''}'.trim();
                    return _ConversationTile(
                      icon: Icons.groups_2_outlined,
                      iconColor: AppColors.violet,
                      title: '${g['name'] ?? 'Group'}',
                      subtitle: count == 0
                          ? desc
                          : '$count member${count == 1 ? '' : 's'}'
                                '${desc.isEmpty ? '' : ' · $desc'}',
                      trailing: null,
                      onTap: () => onOpenGroup('${g['id']}'),
                    );
                  },
                ),
        ),
        Positioned(
          right: 16,
          bottom: 20,
          child: FloatingActionButton.small(
            backgroundColor: AppColors.green,
            foregroundColor: Colors.white,
            heroTag: 'new_group',
            onPressed: onCreate,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor = AppColors.blue,
    this.trailing,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 22, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 18, color: Colors.black26),
            ],
          ),
        ),
      ),
    );
  }
}
