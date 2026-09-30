import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/routing/app_router.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import 'messaging_service.dart';

// ---------------------------------------------------------------------------
// Person picker (single-select) — used for new direct chats and adding members.
// ---------------------------------------------------------------------------

Future<void> showPersonPickerSheet(
  BuildContext context, {
  required String title,
  required Future<void> Function(String userId) onPick,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PersonPickerSheet(title: title, onPick: onPick),
  );
}

class _PersonPickerSheet extends StatefulWidget {
  const _PersonPickerSheet({required this.title, required this.onPick});

  final String title;
  final Future<void> Function(String userId) onPick;

  @override
  State<_PersonPickerSheet> createState() => _PersonPickerSheetState();
}

class _PersonPickerSheetState extends State<_PersonPickerSheet> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _people = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _query('');
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _query(String q) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await MessagingService.instance.searchPeople(q);
      final withAccounts = rows.where((r) {
        final uid = '${r['user_id']}';
        return uid.isNotEmpty && uid != 'null';
      }).toList();
      if (!mounted) return;
      setState(() => _people = withAccounts);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).viewPadding.top;
    return Padding(
      padding: EdgeInsets.only(top: pad + 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TextField(
                controller: _search,
                onChanged: _query,
                decoration: const InputDecoration(
                  hintText: 'Search colleagues by name…',
                  prefixIcon: Icon(Icons.search, size: 20),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: _loading
                  ? const PageLoadingView(label: 'Loading colleagues…')
                  : _error != null
                  ? PageErrorView(
                      message: _error!,
                      onRetry: () => _query(_search.text),
                    )
                  : _people.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: PageEmptyView(
                        title: 'No colleagues match',
                        description: 'Only employees with a linked account can be reached.',
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(8),
                      itemCount: _people.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final p = _people[i];
                        final name = '${p['full_name'] ?? 'Colleague'}';
                        final detail = [
                          if ((p['position'] as String?)?.isNotEmpty ?? false)
                            '${p['position']}',
                          if ((p['branch'] as String?)?.isNotEmpty ?? false)
                            '${p['branch']}',
                        ].join(' · ');
                        return ListTile(
                          leading: AvatarCircle(name: name),
                          title: Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: detail.isEmpty
                              ? null
                              : Text(
                                  detail,
                                  style: const TextStyle(fontSize: 12),
                                ),
                          trailing: Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: AppColors.textTertiary(context),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onPick('${p['user_id']}');
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create channel (mobile-friendly subset: manual team/dept/etc. channels).
// ---------------------------------------------------------------------------

Future<void> showCreateChannelSheet(
  BuildContext context, {
  required Future<void> Function(String id) onCreated,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CreateChannelSheet(onCreated: onCreated),
  );
}

class _CreateChannelSheet extends StatefulWidget {
  const _CreateChannelSheet({required this.onCreated});

  final Future<void> Function(String id) onCreated;

  @override
  State<_CreateChannelSheet> createState() => _CreateChannelSheetState();
}

class _CreateChannelSheetState extends State<_CreateChannelSheet> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  static const _types = <String>[
    'team',
    'branch',
    'department',
    'role',
    'area',
  ];
  String _type = 'team';
  bool _saving = false;

  static const _typeLabels = {
    'team': 'Team',
    'branch': 'Branch',
    'department': 'Department',
    'role': 'Role',
    'area': 'Area',
  };

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showSnack('Channel name is required.', isError: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final created = await MessagingService.instance.createChannel(
        name: name.toLowerCase().replaceAll(RegExp(r'\s+'), '-'),
        displayName: name,
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        channelType: _type,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      await widget.onCreated('${created['id']}');
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack('Channel could not be created: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).viewPadding.top;
    return Padding(
      padding: EdgeInsets.only(
        top: topPad + 12,
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Create channel',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Channel name',
                hintText: 'e.g. All Hands',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Channel type'),
              items: [
                for (final t in _types)
                  DropdownMenuItem(value: t, child: Text(_typeLabels[t] ?? t)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _type = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'What is this channel for?',
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create group (name + description + member multi-select).
// ---------------------------------------------------------------------------

Future<void> showCreateGroupSheet(
  BuildContext context, {
  required Future<void> Function(String id) onCreated,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CreateGroupSheet(onCreated: onCreated),
  );
}

class _CreateGroupSheet extends StatefulWidget {
  const _CreateGroupSheet({required this.onCreated});

  final Future<void> Function(String id) onCreated;

  @override
  State<_CreateGroupSheet> createState() => _CreateGroupSheetState();
}

class _CreateGroupSheetState extends State<_CreateGroupSheet> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _search = TextEditingController();
  final Map<String, dynamic> _selected = {};
  List<Map<String, dynamic>> _people = [];
  bool _loadingPeople = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadPeople('');
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadPeople(String q) async {
    setState(() => _loadingPeople = true);
    try {
      final rows = await MessagingService.instance.searchPeople(q);
      final withAccounts = rows.where((r) {
        final uid = '${r['user_id']}';
        return uid.isNotEmpty && uid != 'null';
      }).toList();
      if (!mounted) return;
      setState(() => _people = withAccounts);
    } catch (_) {
      if (mounted) setState(() => _people = []);
    } finally {
      if (mounted) setState(() => _loadingPeople = false);
    }
  }

  void _toggle(Map<String, dynamic> p) {
    final uid = '${p['user_id']}';
    setState(() {
      if (_selected.containsKey(uid)) {
        _selected.remove(uid);
      } else {
        _selected[uid] = p;
      }
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showSnack('Group name is required.', isError: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final created = await MessagingService.instance.createGroup(
        name: name,
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        memberIds: _selected.keys.toList(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      await widget.onCreated('${created['id']}');
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack('Group could not be created: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).viewPadding.top;
    return Padding(
      padding: EdgeInsets.only(
        top: topPad + 12,
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Create group',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Column(
                children: [
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Group name',
                      hintText: 'e.g. Marketing Leads',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _description,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _search,
                    onChanged: _loadPeople,
                    decoration: const InputDecoration(
                      hintText: 'Add colleagues by name…',
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                  ),
                  if (_selected.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (final e in _selected.entries)
                            Chip(
                              backgroundColor: AppColors.green.withValues(
                                alpha: 0.1,
                              ),
                              label: Text(
                                '${(e.value as Map)['full_name'] ?? '?'}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.greenDark,
                                ),
                              ),
                              onDeleted: () =>
                                  _toggle(e.value as Map<String, dynamic>),
                              deleteIcon: const Icon(Icons.close, size: 16),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: _loadingPeople
                  ? const PageLoadingView(label: 'Loading colleagues…')
                  : _people.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: PageEmptyView(
                        title: 'No colleagues match',
                        description: 'Only employees with a linked account can be added.',
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(8),
                      itemCount: _people.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final p = _people[i];
                        final uid = '${p['user_id']}';
                        final name = '${p['full_name'] ?? 'Colleague'}';
                        final detail = [
                          if ((p['position'] as String?)?.isNotEmpty ?? false)
                            '${p['position']}',
                          if ((p['branch'] as String?)?.isNotEmpty ?? false)
                            '${p['branch']}',
                        ].join(' · ');
                        return CheckboxListTile(
                          value: _selected.containsKey(uid),
                          onChanged: (_) => _toggle(p),
                          controlAffinity: ListTileControlAffinity.trailing,
                          secondary: AvatarCircle(name: name),
                          title: Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: detail.isEmpty
                              ? null
                              : Text(
                                  detail,
                                  style: const TextStyle(fontSize: 12),
                                ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${_selected.length} selected',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Create group'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Conversation info sheet — members + invite share + add/remove.
// ---------------------------------------------------------------------------

Future<void> showConversationInfoSheet(
  BuildContext context, {
  required String kind,
  required String id,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ConversationInfoSheet(kind: kind, id: id),
  );
}

class _ConversationInfoSheet extends StatefulWidget {
  const _ConversationInfoSheet({required this.kind, required this.id});

  final String kind;
  final String id;

  @override
  State<_ConversationInfoSheet> createState() => _ConversationInfoSheetState();
}

class _ConversationInfoSheetState extends State<_ConversationInfoSheet> {
  bool get _isGroup => widget.kind == 'group';

  List<Map<String, dynamic>> _members = [];
  Map<String, Map<String, dynamic>> _directory = const {};
  String _title = '';
  String _description = '';
  bool _loading = true;
  String? _error;

  String get _me => SupabaseService.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final table = _isGroup ? 'message_groups' : 'message_channels';
      final metaRes = await SupabaseService.client
          .from(table)
          .select()
          .eq('id', widget.id)
          .maybeSingle();
      final meta = metaRes == null
          ? const {}
          : Map<String, dynamic>.from(metaRes as Map);
      final members = await (_isGroup
          ? MessagingService.instance.groupMembers(widget.id)
          : MessagingService.instance.channelMembers(widget.id));
      final ids = members
          .map((m) => '${m[_isGroup ? 'member_id' : 'member_id']}')
          .where((e) => e.isNotEmpty)
          .toList();
      final directory = await MessagingService.instance.resolveDirectory(ids);
      if (!mounted) return;
      setState(() {
        _title =
            '${meta['display_name'] ?? meta['name'] ?? (_isGroup ? 'Group' : 'Channel')}';
        _description = '${meta['description'] ?? ''}';
        _members = members;
        _directory = directory;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addMember() async {
    await showPersonPickerSheet(
      context,
      title: _isGroup ? 'Add to group' : 'Add to channel',
      onPick: (userId) async {
        try {
          if (_isGroup) {
            await MessagingService.instance.addGroupMember(widget.id, userId);
          } else {
            await MessagingService.instance.addChannelMember(widget.id, userId);
          }
        } catch (_) {
          showSnack('Member could not be added.', isError: true);
        }
        await _load();
      },
    );
  }

  Future<void> _removeMember(String memberId) async {
    final name = MessagingService.instance.directoryName(_directory, memberId);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove member'),
        content: Text(
          'Remove $name from this ${_isGroup ? 'group' : 'channel'}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      if (_isGroup) {
        await MessagingService.instance.removeGroupMember(widget.id, memberId);
      } else {
        await MessagingService.instance.removeChannelMember(
          widget.id,
          memberId,
        );
      }
      await _load();
    } catch (_) {
      showSnack('Member could not be removed.', isError: true);
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

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).viewPadding.top;
    return Padding(
      padding: EdgeInsets.only(
        top: topPad + 12,
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (_description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  _description,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: OutlinedButton.icon(
                onPressed: _shareInvite,
                icon: const Icon(Icons.mail_outline, size: 18),
                label: const Text('Share invite'),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Members (${_members.length})',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _addMember,
                    icon: const Icon(Icons.person, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: _loading
                  ? const PageLoadingView(label: 'Loading members…')
                  : _error != null
                  ? PageErrorView(message: _error!, onRetry: _load)
                  : _members.isEmpty
                  ? ListView(
                      padding: EdgeInsets.all(32),
                      children: [
                        PageEmptyView(
                          title: 'No members yet',
                          description: 'Add colleagues to start collaborating.',
                        ),
                      ],
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(8),
                      itemCount: _members.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final m = _members[i];
                        final memberId = '${m['member_id']}';
                        final name = MessagingService.instance.directoryName(
                          _directory,
                          memberId,
                        );
                        final mine = memberId == _me;
                        return ListTile(
                          dense: true,
                          leading: AvatarCircle(name: name, size: 34),
                          title: Text(
                            name,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            mine ? 'You' : '${m['role'] ?? 'member'}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: mine
                              ? null
                              : IconButton(
                                  tooltip: 'Remove',
                                  onPressed: () => _removeMember(memberId),
                                  icon: const Icon(
                                    Icons.cancel,
                                    size: 20,
                                    color: AppColors.rose,
                                  ),
                                ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
