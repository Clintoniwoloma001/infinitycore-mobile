import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../../core/services/auth_service.dart';
import '../dashboard/home_shell.dart';
import 'imeet_models.dart';
import 'imeet_service.dart';
import 'widgets/imeet_widgets.dart';

/// I-Meet home — InfinityCore's meeting intelligence dashboard.
///
/// Shows today's meetings, upcoming ones, recent recordings and folders. The
/// Quick Record action is the module's front door: a user who has no meetings at
/// all can still record one and have it processed.
class IMeetHomeScreen extends StatefulWidget {
  const IMeetHomeScreen({super.key});

  @override
  State<IMeetHomeScreen> createState() => _IMeetHomeScreenState();
}

class _IMeetHomeScreenState extends State<IMeetHomeScreen> {
  final IMeetService _service = IMeetService.instance;

  List<IMeetMeeting> _meetings = const [];
  List<IMeetFolder> _folders = const [];
  bool _loading = true;
  String? _error;
  String? _folderFilter;

  @override
  void initState() {
    super.initState();
    _load();
    // Realtime so a finished recording appears without a manual refresh.
    _service.subscribe(onChange: _load);
  }

  @override
  void dispose() {
    _service.unsubscribe();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _service.listMeetings(folderId: _folderFilter, limit: 60),
        _service.listFolders(),
      ]);
      if (!mounted) return;
      setState(() {
        _meetings = results[0] as List<IMeetMeeting>;
        _folders = results[1] as List<IMeetFolder>;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Sectioning
  // ---------------------------------------------------------------------------

  bool _isToday(DateTime? d) {
    if (d == null) return false;
    final n = DateTime.now();
    final l = d.toLocal();
    return l.year == n.year && l.month == n.month && l.day == n.day;
  }

  List<IMeetMeeting> get _today =>
      _meetings.where((m) => _isToday(m.startedAt)).toList();

  List<IMeetMeeting> get _upcoming {
    final now = DateTime.now();
    return _meetings.where((m) {
      final s = m.startedAt;
      return s != null && s.toLocal().isAfter(now) && !_isToday(s);
    }).toList()..sort((a, b) => a.startedAt!.compareTo(b.startedAt!));
  }

  List<IMeetMeeting> get _recent {
    final now = DateTime.now();
    return _meetings.where((m) {
      final s = m.startedAt;
      return s != null && s.toLocal().isBefore(now);
    }).toList();
  }

  List<IMeetMeeting> get _processing =>
      _meetings.where((m) => m.isProcessing).toList();

  int _recordingCount(IMeetMeeting m) {
    // Cheap: the list is metadata only, so count is inferred from status rather
    // than issuing a query per row (section 30).
    return m.status == IMeetStatus.draft ? 0 : 1;
  }

  void _openMeeting(IMeetMeeting m) {
    context.push('/imeet/${m.id}');
  }

  Future<void> _quickRecord() async {
    final opened = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (_) => _NewMeetingSheet(onStart: _startRecording),
    );
    if (opened == true && mounted) _load();
  }

  Future<void> _startRecording({
    String? title,
    String? location,
    String? folderId,
  }) async {
    final ok = await context.push<bool>(
      '/imeet/record',
      extra: {'title': title, 'location': location, 'folderId': folderId},
    );
    if (ok == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    // Only the first name is used, and only for the greeting — the full name
    // belongs on the meeting record, not shouted across a dashboard.
    final full = AuthService.instance.profile?.fullName ?? '';
    final firstName = full.trim().isEmpty ? '' : full.trim().split(' ').first;

    return Scaffold(
      appBar: shellAppBar(
        context,
        title: 'I-Meet',
        // The tagline lives in the greeting block directly below rather than in
        // the app bar, which is shared across the app and stays one line tall.
      ),
      body: _loading
          ? const PageLoadingView(label: 'Loading your meetings…')
          : _error != null && _meetings.isEmpty
          ? PageErrorView(message: _error!, onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                children: [
                  _Greeting(name: firstName),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _quickRecord,
                    icon: const Icon(Icons.mic, size: 20),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        'Record Meeting',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (_processing.isNotEmpty) ...[
                    _SectionHeader(
                      label: 'Processing',
                      icon: Icons.hourglass_top,
                    ),
                    for (final m in _processing)
                      IMeetMeetingTile(
                        meeting: m,
                        onTap: () => _openMeeting(m),
                      ),
                    const SizedBox(height: 12),
                  ],
                  _SectionHeader(label: 'Today', icon: Icons.today),
                  if (_today.isEmpty)
                    const _EmptyHint(text: 'No meetings recorded for today.')
                  else
                    for (final m in _today)
                      IMeetMeetingTile(
                        meeting: m,
                        onTap: () => _openMeeting(m),
                        recordingCount: _recordingCount(m),
                        hasSummary: m.status == IMeetStatus.ready,
                      ),
                  const SizedBox(height: 16),
                  _SectionHeader(label: 'Upcoming', icon: Icons.upcoming),
                  if (_upcoming.isEmpty)
                    const _EmptyHint(text: 'No upcoming meetings yet.')
                  else
                    for (final m in _upcoming.take(5))
                      IMeetMeetingTile(
                        meeting: m,
                        onTap: () => _openMeeting(m),
                      ),
                  const SizedBox(height: 16),
                  _SectionHeader(label: 'Recent', icon: Icons.history),
                  if (_recent.isEmpty)
                    const _EmptyHint(
                      text: 'Your recorded meetings will appear here.',
                    )
                  else
                    for (final m in _recent.take(20))
                      IMeetMeetingTile(
                        meeting: m,
                        onTap: () => _openMeeting(m),
                        recordingCount: _recordingCount(m),
                        hasSummary: m.status == IMeetStatus.ready,
                      ),
                  const SizedBox(height: 16),
                  _SectionHeader(label: 'Folders', icon: Icons.folder_outlined),
                  if (_folders.isEmpty)
                    const _EmptyHint(
                      text: 'Create folders to organize your meetings.',
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final f in _folders)
                          _FolderChip(
                            folder: f,
                            selected: _folderFilter == f.id,
                            onTap: () => setState(() {
                              _folderFilter = _folderFilter == f.id
                                  ? null
                                  : f.id;
                            }),
                          ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final h = DateTime.now().hour;
    final part = h < 12
        ? 'Good morning'
        : h < 17
        ? 'Good afternoon'
        : 'Good evening';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name.isEmpty ? part : '$part, $name',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          'Capture, transcribe and summarise your meetings.',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary(context),
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppColors.accent(context)),
          const SizedBox(width: 6),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: AppColors.textSecondary(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// An empty-state line. Used inline rather than as a full-page state because
/// I-Meet's sections are individually empty, not the whole screen.
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: AppColors.textTertiary(context)),
      ),
    );
  }
}

class _FolderChip extends StatelessWidget {
  const _FolderChip({
    required this.folder,
    required this.selected,
    required this.onTap,
  });

  final IMeetFolder folder;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent(context)
              : AppColors.surface(context),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? AppColors.accent(context)
                : AppColors.border(context),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_outlined,
              size: 13,
              color: selected ? Colors.white : AppColors.textSecondary(context),
            ),
            const SizedBox(width: 5),
            Text(
              folder.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.textPrimary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Collects the minimum needed to start a recording.
///
/// Deliberately short: a title, an optional location and an optional folder is
/// all that stands between the user and a recorded meeting. More than that
/// would be friction on the path that matters most.
class _NewMeetingSheet extends StatefulWidget {
  const _NewMeetingSheet({required this.onStart});

  final Future<void> Function({
    String? title,
    String? location,
    String? folderId,
  })
  onStart;

  @override
  State<_NewMeetingSheet> createState() => _NewMeetingSheetState();
}

class _NewMeetingSheetState extends State<_NewMeetingSheet> {
  final _title = TextEditingController();
  final _location = TextEditingController();
  String? _folderId;
  List<IMeetFolder> _folders = const [];

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    try {
      final f = await IMeetService.instance.listFolders();
      if (mounted) setState(() => _folders = f);
    } catch (_) {
      // Folders are optional; a failure here must not block recording.
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New meeting', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Give it a name so it is easy to find later. '
            'You can change this any time.',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Meeting title',
              hintText: 'e.g. Weekly Operations Review',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _location,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Location (optional)',
              hintText: 'e.g. Board Room',
              border: OutlineInputBorder(),
            ),
          ),
          if (_folders.isNotEmpty) ...[
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _folderId,
              decoration: const InputDecoration(
                labelText: 'Folder (optional)',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('No folder'),
                ),
                for (final f in _folders)
                  DropdownMenuItem<String>(value: f.id, child: Text(f.name)),
              ],
              onChanged: (v) => setState(() => _folderId = v),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () async {
              Navigator.of(context).pop(true);
              final t = _title.text.trim();
              final l = _location.text.trim();
              await widget.onStart(
                title: t.isEmpty ? null : t,
                location: l.isEmpty ? null : l,
                folderId: _folderId,
              );
            },
            icon: const Icon(Icons.mic, size: 20),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 13),
              child: Text('Start recording'),
            ),
          ),
        ],
      ),
    );
  }
}
