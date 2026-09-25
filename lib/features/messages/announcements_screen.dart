import 'package:flutter/material.dart';

import '../../core/routing/app_router.dart';
import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import '../dashboard/home_shell.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import 'communication_service.dart';

/// Announcements feed — the mobile equivalent of the web announcements panel.
///
/// Reads are RLS-scoped to announcements whose audience contains the viewer;
/// publishing is gated by `can_author_announcement()` inside the RPC itself.
class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key});

  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

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
      final items = await CommunicationService.instance.listAnnouncements();
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = CommunicationService.friendlyError(
            e,
            fallback: 'Announcements are unavailable right now.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPublish = canAuthorAnnouncement(AuthService.instance.role);
    return Scaffold(
      appBar: shellAppBar(context, title: 'Announcements'),
      floatingActionButton: canPublish
          ? FloatingActionButton.extended(
              onPressed: _openComposer,
              backgroundColor: AppColors.accent(context),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('New'),
            )
          : null,
      body: _loading
          ? const PageLoadingView(label: 'Loading announcements…')
          : _error != null
          ? PageErrorView(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? const PageEmptyView(
              title: 'No announcements',
              description: 'Official notices targeted to you will appear here.',
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _AnnouncementCard(
                  data: _items[i],
                  onAcknowledge: () => _acknowledge(_items[i]),
                ),
              ),
            ),
    );
  }

  Future<void> _acknowledge(Map<String, dynamic> item) async {
    final id = '${item['id']}';
    if (id.isEmpty) return;
    if (item['requires_ack'] == true) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Acknowledge notice?'),
          content: const Text(
            'This records that you have read and understood this announcement.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Acknowledge'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await CommunicationService.instance.acknowledgeAnnouncement(id);
      if (!mounted) return;
      showSnack('Acknowledgement recorded.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      showSnack(
        CommunicationService.friendlyError(
          e,
          fallback: 'Could not record your acknowledgement.',
        ),
        isError: true,
      );
    }
  }

  Future<void> _openComposer() async {
    final published = await showAnnouncementComposer(context);
    if (published == true) await _load();
  }
}

class _AnnouncementCard extends StatelessWidget {
  const _AnnouncementCard({required this.data, required this.onAcknowledge});

  final Map<String, dynamic> data;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final message = data['message'];
    final body = message is Map && '${message['body'] ?? ''}'.isNotEmpty
        ? '${message['body']}'
        : '${data['body'] ?? ''}';
    final priority = '${data['priority'] ?? 'normal'}';
    final targetType = '${data['target_type'] ?? 'organization'}';
    final requiresAck = data['requires_ack'] == true;
    final status = '${data['status'] ?? 'published'}';
    final publishedAt = '${data['published_at'] ?? data['created_at'] ?? ''}';
    final accent = switch (priority) {
      'urgent' => AppColors.rose,
      'high' => AppColors.amber,
      'low' => AppColors.blue,
      _ => AppColors.accent(context),
    };

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusBadge(label: priority, color: accent),
              const SizedBox(width: 8),
              StatusBadge(label: status),
              const Spacer(),
              if (publishedAt.isNotEmpty)
                Text(
                  Fmt.dateTimeShort(publishedAt),
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textTertiary(context),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${data['title'] ?? 'Announcement'}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.groups_outlined,
                size: 14,
                color: AppColors.iconMuted(context),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  Fmt.titleCase(targetType),
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textTertiary(context),
                  ),
                ),
              ),
              if (requiresAck)
                TextButton.icon(
                  onPressed: onAcknowledge,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Acknowledge'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Composer for a new announcement. Returns true when a broadcast was
/// published so the caller can refresh the feed.
Future<bool?> showAnnouncementComposer(BuildContext context) async {
  final title = TextEditingController();
  final body = TextEditingController();
  final targetValue = TextEditingController();
  var priority = 'normal';
  var targetType = 'organization';
  var requiresAck = false;
  var saving = false;
  String? error;

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        Future<void> submit() async {
          final t = title.text.trim();
          final b = body.text.trim();
          if (t.isEmpty || b.isEmpty) {
            setSheetState(() => error = 'Title and message are both required.');
            return;
          }
          setSheetState(() {
            saving = true;
            error = null;
          });
          try {
            await CommunicationService.instance.publishAnnouncement(
              title: t,
              body: b,
              priority: priority,
              targetType: targetType,
              targetValue: targetType == 'organization'
                  ? null
                  : targetValue.text.trim(),
              requiresAck: requiresAck,
            );
            if (context.mounted) Navigator.of(context).pop(true);
          } catch (e) {
            setSheetState(() {
              saving = false;
              error = CommunicationService.friendlyError(
                e,
                fallback: 'The announcement could not be published.',
              );
            });
          }
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            20 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'New announcement',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary(context),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: title,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: body,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in ['low', 'normal', 'high', 'urgent'])
                      ChoiceChip(
                        label: Text(Fmt.titleCase(p)),
                        selected: priority == p,
                        onSelected: (_) => setSheetState(() => priority = p),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: targetType,
                  decoration: const InputDecoration(
                    labelText: 'Audience',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'organization',
                      child: Text('Whole organisation'),
                    ),
                    DropdownMenuItem(value: 'branch', child: Text('Branch')),
                    DropdownMenuItem(value: 'area', child: Text('Area')),
                    DropdownMenuItem(
                      value: 'department',
                      child: Text('Department'),
                    ),
                    DropdownMenuItem(value: 'role', child: Text('Role')),
                    DropdownMenuItem(
                      value: 'employees',
                      child: Text('Specific employees'),
                    ),
                    DropdownMenuItem(value: 'channel', child: Text('Channel')),
                  ],
                  onChanged: (v) =>
                      setSheetState(() => targetType = v ?? 'organization'),
                ),
                if (targetType != 'organization') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: targetValue,
                    decoration: InputDecoration(
                      labelText: switch (targetType) {
                        'branch' => 'Branch id',
                        'area' => 'Area id',
                        'department' => 'Department',
                        'role' => 'Role',
                        'channel' => 'Channel id',
                        _ => 'Employee ids (comma separated)',
                      },
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: requiresAck,
                  onChanged: (v) => setSheetState(() => requiresAck = v),
                  title: const Text('Require acknowledgement'),
                  subtitle: const Text(
                    'Recipients must confirm they have read this notice.',
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      error!,
                      style: const TextStyle(
                        color: AppColors.rose,
                        fontSize: 12,
                      ),
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: saving ? null : submit,
                    child: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Publish'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  title.dispose();
  body.dispose();
  targetValue.dispose();
  return result;
}
