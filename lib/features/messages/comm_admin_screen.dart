import 'package:flutter/material.dart';

import '../../core/routing/app_router.dart';
import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../dashboard/home_shell.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import 'announcements_screen.dart';
import 'communication_service.dart';

/// Mobile Communication Administration — the port of the web
/// `CommunicationAdmin` page (overview, channels, moderation, audit,
/// retention/holds and exports).
///
/// Access control is layered:
///  1. the router redirects unauthorized roles away from `/comm-admin`;
///  2. this screen re-checks the same role list before rendering anything;
///  3. and, decisively, the server refuses every read and mutation unless
///     `public.is_communication_admin()` passes. Bypassing the client therefore
///     yields no data.
class CommAdminScreen extends StatelessWidget {
  const CommAdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!canAccessCommAdmin(AuthService.instance.role)) {
      return Scaffold(
        appBar: shellAppBar(context, title: 'Comm Admin'),
        body: const PageEmptyView(
          title: 'Access denied',
          description:
              'Communication Administration is restricted to authorized '
              'administrators and HR.',
        ),
      );
    }

    // Global DM transparency (spec Part 2) is reserved to super_admin only.
    final isSuper = AuthService.instance.role == AppRoles.superAdmin;
    final tabs = <Widget>[
      const Tab(text: 'Overview'),
      const Tab(text: 'Channels'),
      const Tab(text: 'Moderation'),
      const Tab(text: 'Audit'),
      const Tab(text: 'Retention'),
      const Tab(text: 'Exports'),
      if (isSuper) const Tab(text: 'DM Inspection'),
    ];
    final views = <Widget>[
      const _OverviewTab(),
      const _ChannelsTab(),
      const _ModerationTab(),
      const _AuditTab(),
      const _RetentionTab(),
      const _ExportsTab(),
      if (isSuper) const _DmInspectionTab(),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: shellAppBar(context, title: 'Comm Admin'),
        body: Column(
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: AppColors.accent(context),
              indicatorColor: AppColors.accent(context),
              tabs: tabs,
            ),
            Expanded(
              child: TabBarView(children: views),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared async-section scaffold: loading, friendly error, then content.
class _AsyncSection extends StatefulWidget {
  const _AsyncSection({required this.future, required this.builder});

  final Future<dynamic> Function() future;
  final Widget Function(dynamic data) builder;

  @override
  State<_AsyncSection> createState() => _AsyncSectionState();
}

class _AsyncSectionState extends State<_AsyncSection> {
  late Future<dynamic> _future = widget.future();

  void _reload() => setState(() => _future = widget.future());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<dynamic>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const PageLoadingView();
        }
        if (snapshot.hasError) {
          return PageErrorView(
            message: CommunicationService.friendlyError(
              snapshot.error!,
              fallback: 'This section is unavailable right now.',
            ),
            onRetry: _reload,
          );
        }
        return widget.builder(snapshot.data);
      },
    );
  }
}

/// Normalises the `List<Map<...>>` shape a Supabase select returns.
List<Map<String, dynamic>> asRows(dynamic data) => data is List
    ? data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : <Map<String, dynamic>>[];

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontWeight: FontWeight.w800,
      color: AppColors.textPrimary(context),
    ),
  );
}

class _MutedNote extends StatelessWidget {
  const _MutedNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 13, color: AppColors.textTertiary(context)),
  );
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context) {
    return _AsyncSection(
      future: () => CommunicationService.instance.communicationStats(),
      builder: (data) {
        final m = data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};
        if (m.isEmpty) {
          return const PageEmptyView(title: 'No statistics available');
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _StatTile(
                  label: 'Messages',
                  value: '${m['messages_sent'] ?? 0}',
                ),
                _StatTile(
                  label: 'Active groups',
                  value: '${m['active_groups'] ?? 0}',
                ),
                _StatTile(
                  label: 'Active channels',
                  value: '${m['active_channels'] ?? 0}',
                ),
                _StatTile(
                  label: 'Announcements',
                  value: '${m['published_announcements'] ?? 0}',
                ),
                _StatTile(
                  label: 'Ack rate',
                  value: '${m['acknowledgement_rate'] ?? 0}%',
                ),
                _StatTile(
                  label: 'Open reports',
                  value: '${m['open_reports'] ?? 0}',
                ),
                _StatTile(
                  label: 'Official records',
                  value: '${m['official_records'] ?? 0}',
                ),
                _StatTile(
                  label: 'Pending acks',
                  value: '${m['unread_mandatory_announcements'] ?? 0}',
                ),
              ],
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => showAnnouncementComposer(context),
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Publish an announcement'),
            ),
          ],
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w700,
                color: AppColors.textTertiary(context),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------
// Channels
// ------------------------------------------------------------------

class _ChannelsTab extends StatelessWidget {
  const _ChannelsTab();

  @override
  Widget build(BuildContext context) {
    return _AsyncSection(
      future: () => CommunicationService.instance.channelAdminList(),
      builder: (data) {
        final rows = asRows(data);
        if (rows.isEmpty) {
          return const PageEmptyView(title: 'No channels configured');
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final c = rows[i];
            final isAuto = c['is_auto'] == true;
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${c['display_name'] ?? c['name'] ?? 'Channel'}',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary(context),
                          ),
                        ),
                        Text(
                          '${c['channel_type'] ?? 'manual'} · '
                          '${isAuto ? 'automatic' : 'manual'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textTertiary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  StatusBadge(label: '${c['status'] ?? 'active'}'),
                  if (isAuto)
                    IconButton(
                      tooltip: 'Sync automatic members',
                      icon: const Icon(Icons.refresh, size: 18),
                      onPressed: () async {
                        try {
                          await CommunicationService.instance
                              .syncAutoChannelMembers('${c['id']}');
                          if (context.mounted) {
                            showSnack('Members synchronised.');
                          }
                        } catch (e) {
                          if (context.mounted) {
                            showSnack(
                              CommunicationService.friendlyError(e),
                              isError: true,
                            );
                          }
                        }
                      },
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ------------------------------------------------------------------
// Moderation
// ------------------------------------------------------------------

class _ModerationTab extends StatefulWidget {
  const _ModerationTab();

  @override
  State<_ModerationTab> createState() => _ModerationTabState();
}

class _ModerationTabState extends State<_ModerationTab> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = CommunicationService.instance.reports();
  }

  void _reload() =>
      setState(() => _future = CommunicationService.instance.reports());

  Future<void> _act(Map<String, dynamic> report, String status) async {
    try {
      await CommunicationService.instance.resolveReport(
        '${report['id']}',
        status,
      );
      if (!mounted) return;
      showSnack('Report ${status.replaceAll('_', ' ')}.');
      _reload();
    } catch (e) {
      if (!mounted) return;
      showSnack(CommunicationService.friendlyError(e), isError: true);
    }
  }

  Future<void> _restrict(Map<String, dynamic> report) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restrict this message?'),
        content: const Text(
          'The message will be hidden for all members. The original record is '
          'preserved for audit.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restrict'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CommunicationService.instance.restrictMessage(
        '${report['message_id']}',
        'removed by moderation',
      );
      await CommunicationService.instance.resolveReport(
        '${report['id']}',
        'resolved',
        note: 'message restricted by moderation',
      );
      if (!mounted) return;
      showSnack('Message restricted and report resolved.');
      _reload();
    } catch (e) {
      if (!mounted) return;
      showSnack(CommunicationService.friendlyError(e), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const PageLoadingView();
        }
        if (snapshot.hasError) {
          return PageErrorView(
            message: CommunicationService.friendlyError(snapshot.error!),
            onRetry: _reload,
          );
        }
        final rows = snapshot.data ?? const [];
        if (rows.isEmpty) return const PageEmptyView(title: 'No reports');
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) =>
              _ReportCard(report: rows[i], onAct: _act, onRestrict: _restrict),
        );
      },
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.report,
    required this.onAct,
    required this.onRestrict,
  });

  final Map<String, dynamic> report;
  final void Function(Map<String, dynamic>, String) onAct;
  final void Function(Map<String, dynamic>) onRestrict;

  @override
  Widget build(BuildContext context) {
    final status = '${report['status'] ?? 'open'}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusBadge(label: status),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${report['reason'] ?? ''}'.replaceAll('_', ' '),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${report['details'] ?? 'No details provided'}',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              if (status == 'open')
                OutlinedButton(
                  onPressed: () => onAct(report, 'investigating'),
                  child: const Text('Investigate'),
                ),
              OutlinedButton(
                onPressed: () => onRestrict(report),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.rose,
                ),
                child: const Text('Restrict message'),
              ),
              OutlinedButton(
                onPressed: () => onAct(report, 'dismissed'),
                child: const Text('Dismiss'),
              ),
              FilledButton(
                onPressed: () => onAct(report, 'resolved'),
                child: const Text('Resolve'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------
// Audit log
// ------------------------------------------------------------------

class _AuditTab extends StatelessWidget {
  const _AuditTab();

  @override
  Widget build(BuildContext context) {
    return _AsyncSection(
      future: () => CommunicationService.instance.auditLog(limit: 200),
      builder: (data) {
        final rows = asRows(data);
        if (rows.isEmpty) return const PageEmptyView(title: 'No audit entries');
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, i) {
            final r = rows[i];
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.event,
                size: 18,
                color: AppColors.iconMuted(context),
              ),
              title: Text(
                '${r['action'] ?? r['event'] ?? 'action'}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '${r['details'] ?? r['target'] ?? ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary(context),
                ),
              ),
              trailing: Text(
                Fmt.dateTimeShort('${r['timestamp'] ?? r['created_at'] ?? ''}'),
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textTertiary(context),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ------------------------------------------------------------------
// Retention & holds
// ------------------------------------------------------------------

class _RetentionTab extends StatelessWidget {
  const _RetentionTab();

  @override
  Widget build(BuildContext context) {
    return _AsyncSection(
      future: () async => {
        'policies': await CommunicationService.instance.retentionPolicies(),
        'holds': await CommunicationService.instance.holds(),
      },
      builder: (data) {
        final m = data is Map ? Map<String, dynamic>.from(data) : {};
        final policies = asRows(m['policies']);
        final holds = asRows(m['holds']);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SectionHeading('Retention policies'),
            const SizedBox(height: 8),
            if (policies.isEmpty)
              const _MutedNote('No retention policies configured.')
            else
              for (final p in policies)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${p['label'] ?? p['policy_key'] ?? ''}'),
                  subtitle: Text(
                    p['is_forever'] == true
                        ? 'Retained indefinitely'
                        : '${p['retention_days'] ?? 0} days',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary(context),
                    ),
                  ),
                ),
            const SizedBox(height: 18),
            const _SectionHeading('Legal / moderation holds'),
            const SizedBox(height: 8),
            if (holds.isEmpty)
              const _MutedNote('No active holds.')
            else
              for (final h in holds)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${h['scope'] ?? 'scope'} · ${h['reason'] ?? ''}',
                  ),
                  subtitle: Text(
                    Fmt.dateTimeShort('${h['created_at'] ?? ''}'),
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary(context),
                    ),
                  ),
                  trailing: TextButton(
                    onPressed: () => _releaseHold(context, '${h['id']}'),
                    child: const Text('Release'),
                  ),
                ),
          ],
        );
      },
    );
  }

  Future<void> _releaseHold(BuildContext context, String holdId) async {
    try {
      await CommunicationService.instance.releaseHold(
        holdId,
        reason: 'released by admin',
      );
      if (!context.mounted) return;
      showSnack('Hold released.');
      // Re-enter this tab so the list re-fetches from the server.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const _RetentionTab()),
      );
    } catch (e) {
      if (!context.mounted) return;
      showSnack(CommunicationService.friendlyError(e), isError: true);
    }
  }
}

// ------------------------------------------------------------------
// Exports
// ------------------------------------------------------------------

class _ExportsTab extends StatefulWidget {
  const _ExportsTab();

  @override
  State<_ExportsTab> createState() => _ExportsTabState();
}

class _ExportsTabState extends State<_ExportsTab> {
  String _scope = 'all';
  bool _busy = false;
  int _rows = 0;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await CommunicationService.instance.exportRecords(
        format: 'csv',
        scope: _scope,
        reason: 'mobile comm admin export',
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _rows = rows.length;
      });
      showSnack('Export generated and logged (${rows.length} records).');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = CommunicationService.friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeading('Generate a communication export'),
        const SizedBox(height: 6),
        const _MutedNote(
          'Every export is written to the server audit log. Exported content '
          'contains private communications — handle it according to policy.',
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: _scope,
          decoration: const InputDecoration(
            labelText: 'Scope',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All communications')),
            DropdownMenuItem(value: 'messages', child: Text('Messages')),
            DropdownMenuItem(
              value: 'announcements',
              child: Text('Announcements'),
            ),
          ],
          onChanged: (v) => setState(() => _scope = v ?? 'all'),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _busy ? null : _run,
          icon: const Icon(Icons.mail_outline, size: 18),
          label: const Text('Generate export'),
        ),
        if (_busy) ...[
          const SizedBox(height: 14),
          const Center(child: CircularProgressIndicator()),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: AppColors.rose, fontSize: 12),
          ),
        ],
        if (_rows > 0) ...[
          const SizedBox(height: 12),
          _MutedNote(
            'Last export returned $_rows record${_rows == 1 ? '' : 's'}.',
          ),
        ],
      ],
    );
  }
}

/// Super Admin DM Inspection (spec Part 2 — global transparency).
/// Pick a staff member -> list their DM threads -> open a transcript ->
/// export (logged). "Return to My Direct Messages" resets the panel.
/// Enforcement is server-side: the widened `chat_threads read own` RLS and
/// `can_read_message` is_super_admin bypass decide what is ever returned.
class _DmInspectionTab extends StatefulWidget {
  const _DmInspectionTab();

  @override
  State<_DmInspectionTab> createState() => _DmInspectionTabState();
}

class _DmInspectionTabState extends State<_DmInspectionTab> {
  final _svc = CommunicationService.instance;
  List<Map<String, dynamic>> _people = [];
  String? _selectedUserId;
  List<Map<String, dynamic>> _threads = [];
  List<Map<String, dynamic>> _messages = [];
  Map<String, Map<String, dynamic>> _identity = {};
  bool _loadingPeople = true;
  bool _loadingThreads = false;
  bool _loadingMessages = false;
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPeople();
  }

  Future<void> _loadPeople() async {
    setState(() { _loadingPeople = true; _error = null; });
    try {
      final me = SupabaseService.client.auth.currentUser?.id ?? '';
      final rows = await _svc.messagingDirectory();
      if (!mounted) return;
      setState(() {
        _people = rows.where((r) => '${r['id'] ?? ''}' != me).toList();
        _loadingPeople = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPeople = false;
        _error = CommunicationService.friendlyError(
          e, fallback: 'Could not load the staff directory.',
        );
      });
    }
  }

  String _nameOf(String id) {
    final ident = _identity[id];
    final identName = '${ident?['full_name'] ?? ident?['email'] ?? ''}';
    if (identName.isNotEmpty) return identName;
    for (final p in _people) {
      if ('${p['id'] ?? ''}' == id) {
        final n = '${p['full_name'] ?? p['email'] ?? ''}';
        if (n.isNotEmpty) return n;
      }
    }
    return 'Unknown User';
  }

  Future<void> _pickUser(String userId) async {
    setState(() {
      _selectedUserId = userId;
      _loadingThreads = true;
      _error = null;
      _threads = [];
      _messages = [];
    });
    try {
      final list = await _svc.threadsForUser(userId);
      final ids = <String>{userId};
      for (final t in list) {
        ids.add('${t['member_a'] ?? ''}');
        ids.add('${t['member_b'] ?? ''}');
      }
      final dir = await _svc.resolveDirectory(ids.toList());
      if (!mounted) return;
      setState(() {
        _threads = list;
        _identity = dir;
        _loadingThreads = false;
        if (list.isEmpty) _error = 'No direct-message threads found for this user.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingThreads = false;
        _error = CommunicationService.friendlyError(
          e, fallback: 'Could not load threads.',
        );
      });
    }
  }


  Future<void> _openThread(String threadId) async {
    setState(() { _loadingMessages = true; _error = null; _messages = []; });
    try {
      final rows = await SupabaseService.client
          .from('chat_messages')
          .select()
          .eq('thread_id', threadId)
          .eq('message_type', 'direct')
          .order('created_at')
          .limit(500);
      final list = asRows(rows);
      final ids = list.map((m) => '${m['sender_id'] ?? ''}').toSet().toList();
      final dir = await _svc.resolveDirectory(ids);
      if (!mounted) return;
      setState(() {
        _messages = list;
        _identity = {..._identity, ...dir};
        _loadingMessages = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMessages = false;
        _error = CommunicationService.friendlyError(
          e, fallback: 'Could not load this transcript.',
        );
      });
    }
  }

  Future<void> _export(String format) async {
    if (_messages.isEmpty || _selectedUserId == null) return;
    setState(() { _exporting = true; _error = null; });
    try {
      await _svc.exportRecords(
        format: format,
        scope: 'search',
        reason: 'Super Admin DM inspection',
        query: 'dm_inspection',
        filters: {'kind': 'dm_inspection', 'inspected_user': _selectedUserId},
      );
      if (!mounted) return;
      setState(() => _exporting = false);
      showSnack('Inspection export generated and logged '
          '(${_messages.length} messages).');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _error = CommunicationService.friendlyError(e, fallback: 'Export failed.');
      });
    }
  }

  void _returnToMine() {
    setState(() {
      _selectedUserId = null;
      _threads = [];
      _messages = [];
      _error = null;
    });
  }


  @override
  Widget build(BuildContext context) {
    final selected = _selectedUserId;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeading('Direct-message inspection (Super Admin)'),
        const SizedBox(height: 6),
        const _MutedNote(
          'Global DM transparency is reserved to the Super Admin role. '
          'Every inspection export is recorded in the audit trail.',
        ),
        const SizedBox(height: 14),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: AppColors.rose, fontSize: 12)),
          const SizedBox(height: 10),
        ],
        DropdownButtonFormField<String>(
          initialValue: selected,
          decoration: const InputDecoration(
            labelText: 'Inspect a staff member',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<String>(value: null, child: Text('Select a user…')),
            ..._people.map(
              (p) => DropdownMenuItem<String>(
                value: '${p['id'] ?? ''}',
                child: Text('${p['full_name'] ?? p['email'] ?? p['id']}'),
              ),
            ),
          ],
          onChanged: (v) { if (v != null) _pickUser(v); },
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: selected == null ? null : _returnToMine,
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('Return to My Direct Messages'),
        ),
        if (_loadingPeople || _loadingThreads) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ],
        if (!_loadingThreads && selected != null && _threads.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _SectionHeading('Threads'),
          ..._threads.map((t) {
            final other = '${t['member_a'] ?? ''}' == selected
                ? '${t['member_b'] ?? ''}'
                : '${t['member_a'] ?? ''}';
            return ListTile(
              dense: true,
              leading: const Icon(Icons.mail_outline, size: 18),
              title: Text(_nameOf(other)),
              subtitle: Text('${t['last_message'] ?? 'No messages yet'}'),
              trailing: Text(
                _shortDate('${t['last_message_at'] ?? ''}'),
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => _openThread('${t['id']}'),
            );
          }),
        ],

        if (_loadingMessages) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ],
        if (!_loadingMessages && _messages.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: _SectionHeading('Transcript')),
              TextButton.icon(
                onPressed: _exporting ? null : () => _export('csv'),
                icon: const Icon(Icons.download, size: 16),
                label: const Text('CSV'),
              ),
              TextButton.icon(
                onPressed: _exporting ? null : () => _export('pdf'),
                icon: const Icon(Icons.picture_as_pdf, size: 16),
                label: const Text('PDF'),
              ),
            ],
          ),
          if (_exporting) const Center(child: CircularProgressIndicator()),
          ..._messages.map(
            (m) => Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _nameOf('${m['sender_id'] ?? ''}'),
                            style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Text(
                          _shortDate('${m['created_at'] ?? ''}'),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('${m['body'] ?? ''}'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _shortDate(String iso) {
    if (iso.isEmpty) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}

