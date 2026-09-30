import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/app_router.dart';
import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';
import '../dashboard/host_fab.dart';
import 'communication_service.dart';
import 'create_sheets.dart';
import 'message_ui.dart';
import 'messages_service.dart';
import 'messaging_hub.dart';
import 'messaging_service.dart';

/// Internal chat + channels + groups hub. Mirrors the web messaging hub:
///   - Chats tab: direct one-to-one threads (server-authoritative RPCs)
///   - Channels tab: organisation channels incl. automatic branch/dept/role
///     membership (managed server-side)
///   - Groups tab: user-created groups with member management
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key, this.embedded = false});

  /// True when the screen is hosted inside [HomeShell]'s tab bar. HomeShell
  /// already paints a shell app bar carrying the title, bell and overflow
  /// menu, so an embedded instance must not draw a second one on top of it.
  /// The Announcements / Comm Admin actions move into a row under the shell
  /// bar instead of being dropped.
  final bool embedded;

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
  Map<String, int> _unread = const {};

  /// Resolved auth user id -> employee name, for the thread tiles.
  Map<String, Map<String, dynamic>> _directory = const {};
  String _query = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The published button is tab-specific, so a tab swipe must republish it.
    _tabs.addListener(_onTabChanged);
    MessagingHub.instance.start();
    _load();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    // The hub is a process-wide singleton started at launch; this screen only
    // listens, so nothing is torn down here.
    super.dispose();
  }

  void _onTabChanged() {
    if (!mounted) return;
    // Rebuild so HostFabPublisher re-runs its builder with the new tab index.
    setState(() {});
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
      // `chat_threads` stores only member_a/member_b, so peer names must come
      // from the directory RPC — never from a raw UUID or a missing column.
      Map<String, Map<String, dynamic>> directory = const {};
      final peerIds = <String>{};
      for (final t in threadsDone) {
        final peer = t.memberA == SupabaseService.userId
            ? t.memberB
            : t.memberA;
        if (peer.isNotEmpty && peer != SupabaseService.userId) {
          peerIds.add(peer);
        }
      }
      if (peerIds.isNotEmpty) {
        try {
          directory = await CommunicationService.instance.resolveDirectory(
            peerIds.toList(),
          );
        } catch (_) {
          // Directory resolution is best effort; tiles fall back to 'Colleague'.
        }
      }
      if (!mounted) return;
      // Unread totals are cosmetic; never fail the whole screen over them.
      Map<String, int> unread = const {};
      try {
        unread = await CommunicationService.instance.unreadCounts();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _threads = threadsDone;
        _channels = channelsDone;
        _groups = groupsDone;
        _directory = directory;
        _unread = unread;
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = CommunicationService.friendlyError(
            e,
            fallback: 'Messages could not be loaded.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The compose button for the visible tab, handed to the shell's FAB slot.
  ///
  /// Only the embedded instance publishes: a standalone Messages route owns its
  /// own Scaffold and shows the button itself, so publishing there would leave
  /// a duplicate.
  Widget? _composeFab(BuildContext context) {
    if (!widget.embedded) return null;
    final (label, heroTag, onPressed) = switch (_tabs.index) {
      1 => ('New channel', 'new_channel', _newChannel),
      2 => ('New group', 'new_group', _newGroup),
      _ => ('New chat', 'new_chat', _newChat),
    };
    return FloatingActionButton.small(
      heroTag: heroTag,
      tooltip: label,
      backgroundColor: AppColors.accent(context),
      foregroundColor: Colors.white,
      onPressed: onPressed,
      child: const Icon(Icons.edit),
    );
  }

  Future<void> _newChat() => showPersonPickerSheet(
    context,
    title: 'Start a conversation',
    onPick: (userId) async {
      final thread = await MessagingService.instance.getOrCreateThread(userId);
      final threadId = '${thread['id'] ?? ''}';
      if (threadId.isEmpty) {
        if (mounted) showSnack('Conversation could not be opened.');
        return;
      }
      if (mounted) await context.push('/messages/$threadId');
    },
  );

  Future<void> _newChannel() => showCreateChannelSheet(
    context,
    onCreated: (id) async {
      if (mounted) await context.push('/messages/channel/$id');
      if (mounted) await _load();
    },
  );

  Future<void> _newGroup() => showCreateGroupSheet(
    context,
    onCreated: (id) async {
      if (mounted) await context.push('/messages/group/$id');
      if (mounted) await _load();
    },
  );

  Future<void> _openThread(BuildContext context, String threadId) async {
    await context.push('/messages/$threadId');
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    // Comm Admin visibility mirrors the web `CommunicationAdmin` gate. The
    // server remains the authority; this only keeps the nav honest.
    final canAdmin = canAccessCommAdmin(AuthService.instance.role);
    final actions = <Widget>[
      IconButton(
        tooltip: 'Announcements',
        icon: const Icon(Icons.notifications_active_outlined),
        onPressed: () async {
          await context.push('/messages/announcements');
          if (mounted) await _load();
        },
      ),
      if (canAdmin)
        IconButton(
          tooltip: 'Comm Admin',
          icon: const Icon(Icons.shield),
          onPressed: () => context.push('/comm-admin'),
        ),
    ];
    return Scaffold(
      // See `embedded`: inside HomeShell the shell owns the app bar.
      appBar: widget.embedded
          ? null
          : shellAppBar(context, title: 'Messages', actionsExtra: actions),
      body: _loading
          ? const PageLoadingView(label: 'Loading messages…')
          : _error != null
          ? PageErrorView(message: _error!, onRetry: _load)
          : Column(
              children: [
                if (widget.embedded)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: actions,
                      ),
                    ),
                  ),
                // Publish the tab's compose button into the shell's FAB slot
                // instead of floating it here. The shell's SARA mark paints
                // above the whole body, so a button positioned in this Stack
                // was covered by it and could not be tapped.
                HostFabPublisher(builder: (context) => _composeFab(context)),
                _SearchBar(onChanged: (v) => setState(() => _query = v)),
                TabBar(
                  controller: _tabs,
                  tabs: const [
                    Tab(text: 'Chats'),
                    Tab(text: 'Channels'),
                    Tab(text: 'Groups'),
                  ],
                  // Theme-aware: the tab strip was the worst offender in dark
                  // mode — a hard-coded near-black unselected label on a dark
                  // scaffold was effectively invisible.
                  labelColor: AppColors.accent(context),
                  unselectedLabelColor: AppColors.textSecondary(context),
                  indicatorColor: AppColors.accent(context),
                  indicatorSize: TabBarIndicatorSize.tab,
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _ThreadList(
                        threads: _threads,
                        unread: _unread,
                        directory: _directory,
                        query: _query,
                        onRefresh: _load,
                        onOpenThread: (id) => _openThread(context, id),
                        onNewChat: _newChat,
                      ),
                      _ChannelList(
                        channels: _channels,
                        unread: _unread,
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
                        onCreate: _newChannel,
                      ),
                      _GroupList(
                        groups: _groups,
                        unread: _unread,
                        onRefresh: _load,
                        onOpenGroup: (id) async {
                          if (context.mounted) {
                            await context.push('/messages/group/$id');
                          }
                          if (mounted) await _load();
                        },
                        onCreate: _newGroup,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _SearchBar extends StatefulWidget {
  const _SearchBar({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search conversations',
          prefixIcon: const Icon(Icons.search, size: 20),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _controller.clear();
                    widget.onChanged('');
                    setState(() {});
                  },
                ),
        ),
        onTap: () => setState(() {}),
      ),
    );
  }
}

class _ThreadList extends StatelessWidget {
  const _ThreadList({
    required this.threads,
    required this.unread,
    required this.directory,
    required this.query,
    required this.onRefresh,
    required this.onOpenThread,
    required this.onNewChat,
  });

  final List<ChatThread> threads;
  final Map<String, int> unread;
  final Map<String, Map<String, dynamic>> directory;
  final String query;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onOpenThread;
  final VoidCallback onNewChat;

  /// Display name for a direct thread. `chat_threads` has no `other_name`
  /// column, so the peer id is derived from the members and resolved through
  /// the employee directory.
  String _nameOf(ChatThread t) {
    final me = SupabaseService.userId ?? '';
    final peer = t.memberA == me ? t.memberB : t.memberA;
    final resolved = peer.isEmpty || peer == me
        ? t.otherName
        : MessagingService.instance.directoryName(directory, peer);
    return resolved.trim().isEmpty ? 'Colleague' : resolved;
  }

  @override
  Widget build(BuildContext context) {
    // Client-side filter over the already-loaded thread list only — this is a
    // convenience filter, not a server search, so no extra data is fetched.
    final q = query.trim().toLowerCase();
    final visible = q.isEmpty
        ? threads
        : threads
              .where(
                (t) =>
                    _nameOf(t).toLowerCase().contains(q) ||
                    t.lastMessage.toLowerCase().contains(q),
              )
              .toList();
    if (visible.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 200),
          PageEmptyView(
            title: q.isEmpty ? 'No conversations yet' : 'No matches',
            description: q.isEmpty
                ? 'Start a new chat with a colleague using the compose button.'
                : 'No conversation matches "$query".',
          ),
        ],
      );
    }
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final t = visible[i];
              final displayName = _nameOf(t);
              final unreadCount = CommunicationService.unreadFor(
                'direct',
                t.id,
                unread,
              );
              return Material(
                color: AppColors.surface(context),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: () => onOpenThread(t.id),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        AvatarCircle(name: displayName, size: 44),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: unreadCount > 0
                                      ? FontWeight.w800
                                      : FontWeight.w700,
                                ),
                              ),
                              if (t.lastMessage.isNotEmpty)
                                Text(
                                  t.lastMessage,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: unreadCount > 0
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: AppColors.textSecondary(context),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (unreadCount > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accent(context),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              unreadCount > 99 ? '99+' : '$unreadCount',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        if (t.lastMessageAt.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              relativeTime(t.lastMessageAt),
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.iconMuted(context),
                              ),
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
      ],
    );
  }
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.channels,
    required this.unread,
    required this.onRefresh,
    required this.onOpenChannel,
    required this.onCreate,
  });

  final List<Map<String, dynamic>> channels;
  final Map<String, int> unread;
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
                    final id = c['id']?.toString() ?? '';
                    final unreadCount = CommunicationService.unreadFor(
                      'channel',
                      id,
                      unread,
                    );
                    return _ConversationTile(
                      icon: Icons.notifications_active_outlined,
                      iconColor: AppColors.blue,
                      title: name,
                      subtitle: '${c['description'] ?? ''}',
                      trailing: unreadCount > 0
                          ? _UnreadBadge(count: unreadCount)
                          : Text(
                              Fmt.titleCase('${c['channel_type'] ?? 'team'}'),
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textTertiary(context),
                              ),
                            ),
                      onTap: () => onOpenChannel(id, name),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _GroupList extends StatelessWidget {
  const _GroupList({
    required this.groups,
    required this.unread,
    required this.onRefresh,
    required this.onOpenGroup,
    required this.onCreate,
  });

  final List<Map<String, dynamic>> groups;
  final Map<String, int> unread;
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
                    final id = '${g['id']}';
                    final unreadCount = CommunicationService.unreadFor(
                      'group',
                      id,
                      unread,
                    );
                    return _ConversationTile(
                      icon: Icons.groups,
                      iconColor: AppColors.violet,
                      title: '${g['name'] ?? 'Group'}',
                      subtitle: count == 0
                          ? desc
                          : '$count member${count == 1 ? '' : 's'}'
                                '${desc.isEmpty ? '' : ' · $desc'}',
                      trailing: unreadCount > 0
                          ? _UnreadBadge(count: unreadCount)
                          : null,
                      onTap: () => onOpenGroup(id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Small unread pill used on conversation, channel and group rows.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.accent(context),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
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
      // Theme-aware: this was a hard-coded white sheet, so every channel /
      // group / chat row stayed bright white in dark mode with a white title
      // on top of it — the washed-out, unreadable list in the bug report.
      color: AppColors.surface(context),
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
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.iconMuted(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
