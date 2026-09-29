import 'package:flutter/material.dart';

import '../imeet_models.dart';
import '../imeet_service.dart';

/// Owner-only management of who has access to an I-Meet folder.
///
/// Mirrors the web FolderShareDialog so the two clients behave identically:
/// the owner adds or removes people, and anyone they removed loses access
/// immediately (the server re-checks on every read, so there is no cached
/// permission to wait for).
class IMeetFolderShareSheet extends StatefulWidget {
  const IMeetFolderShareSheet({super.key, required this.folder});

  final IMeetFolder folder;

  /// Present the sheet. Returns true when something changed, so the caller can
  /// refresh the folder list rather than guessing.
  static Future<bool?> show(BuildContext context, IMeetFolder folder) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => IMeetFolderShareSheet(folder: folder),
    );
  }

  @override
  State<IMeetFolderShareSheet> createState() =>
      _IMeetFolderShareSheetState();
}

class _IMeetFolderShareSheetState extends State<IMeetFolderShareSheet> {
  final _service = IMeetService.instance;

  List<IMeetFolderMember> _members = const [];
  List<Map<String, dynamic>> _people = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _notice;
  String? _selectedUserId;
  bool _allowDownload = true;
  String _query = '';

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
      // The member list is owner-only; a member must not even attempt it.
      final members = widget.folder.isOwner
          ? await _service.listFolderMembers(widget.folder.id)
          : const <IMeetFolderMember>[];
      final people = widget.folder.isOwner
          ? await _service.shareablePeople(widget.folder.id)
          : const <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _members = members;
        _people = people;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load sharing: $e';
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    final id = _selectedUserId;
    if (id == null) {
      setState(() => _error = 'Choose a person to add.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _service.shareFolder(
        widget.folder.id,
        id,
        canDownload: _allowDownload,
      );
      // Re-read from the server: it is the authority on who has access, so the
      // list is never patched optimistically.
      await _load();
      if (!mounted) return;
      final name = _people
          .firstWhere(
            (p) => p['id'] == id,
            orElse: () => const {'full_name': 'the user'},
          )['full_name'];
      setState(() {
        _notice = 'Access granted to $name.';
        _selectedUserId = null;
        _query = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not share: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Removal is confirmed first, because it is immediate and there is no undo:
  /// the server re-checks membership on every read.
  Future<void> _remove(IMeetFolderMember m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove access?'),
        content: Text(
          '${m.fullName} will immediately lose access to "${widget.folder.name}", '
          'including its summaries, transcripts and recordings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _service.unshareFolder(widget.folder.id, m.userId);
      await _load();
      if (!mounted) return;
      setState(() => _notice = '${m.fullName} no longer has access.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not remove access: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existing = _members.map((m) => m.userId).toSet();
    final query = _query.trim().toLowerCase();
    final filtered = _people.where((p) {
      if (query.isEmpty) return true;
      final name = '${p['full_name'] ?? ''}'.toLowerCase();
      final email = '${p['email'] ?? ''}'.toLowerCase();
      return name.contains(query) || email.contains(query);
    }).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Share "${widget.folder.name}"',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.folder.isOwner
                            ? 'People you add can read this folder. '
                                  'You can remove them at any time.'
                            : 'This folder is shared with you. Only the owner '
                                  'can change who has access.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context, true),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _Banner(
                      text: _error!,
                      background: theme.colorScheme.errorContainer,
                      foreground: theme.colorScheme.onErrorContainer,
                      icon: Icons.error_outline,
                    ),
                  ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _Banner(
                      text: _notice!,
                      background: theme.colorScheme.secondaryContainer,
                      foreground: theme.colorScheme.onSecondaryContainer,
                      icon: Icons.check_circle_outline,
                    ),
                  ),
                _buildAddPerson(filtered, existing),
                Text(
                  widget.folder.isOwner
                      ? 'People with access (${_members.length})'
                      : 'Shared by the folder owner',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                if (_loading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (widget.folder.isOwner && _members.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'This folder is private to you. Add someone above to share it.',
                    ),
                  )
                else
                  for (final m in _members)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        child: Text(
                          m.fullName.isEmpty
                              ? '?'
                              : m.fullName.characters.first.toUpperCase(),
                        ),
                      ),
                      title: Text(m.fullName),
                      subtitle: Text(
                        m.isViewOnly
                            ? '${m.email ?? ''}  ·  view only'
                            : m.email ?? '',
                      ),
                      trailing: widget.folder.isOwner
                          ? IconButton(
                              tooltip: 'Remove access',
                              icon: const Icon(Icons.person_remove_outlined),
                              onPressed: _busy ? null : () => _remove(m),
                            )
                          : null,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The add-person controls. Members never see them: the server would refuse
  /// the call, and offering a control that cannot work is worse than hiding it.
  Widget _buildAddPerson(
    List<Map<String, dynamic>> filtered,
    Set<String> existing,
  ) {
    if (!widget.folder.isOwner) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search by name or email',
            prefixIcon: Icon(Icons.search),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _selectedUserId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Choose a person',
            isDense: true,
          ),
          items: [
            for (final p in filtered)
              DropdownMenuItem(
                value: p['id'] as String,
                child: Text(
                  '${p['full_name'] ?? p['email']}'
                  '${existing.contains(p['id']) ? '  (already has access)' : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _selectedUserId = v),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _allowDownload,
          onChanged: (v) => setState(() => _allowDownload = v),
          title: const Text('Allow downloading recordings'),
          subtitle: const Text(
            'Turn off to let them read summaries and transcripts only',
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: (_busy || _selectedUserId == null) ? null : _add,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.person_add_alt),
            label: const Text('Grant access'),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

/// A small inline status/error strip. Theme-driven, never a hard-coded colour.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.background,
    required this.foreground,
    required this.icon,
  });

  final String text;
  final Color background;
  final Color foreground;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: foreground, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
