import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../imeet_models.dart';
import '../imeet_service.dart';

/// Schedule, edit or cancel a meeting, and create folders.
///
/// This sheet fills the two gaps that made I-Meet unusable from the phone:
/// there was no way to plan a future meeting, and no way to create a folder to
/// organise recordings into (which in turn meant there was nothing to share).
///
/// Everything is written through server-authorized RPCs that take the actor
/// from the session, so this widget never decides who is allowed to do what —
/// it renders what the database accepted and surfaces the database's own
/// refusal message rather than a generic failure.
class IMeetScheduleSheet extends StatefulWidget {
  const IMeetScheduleSheet({
    super.key,
    this.meeting,
    this.defaultFolderId,
    this.folders = const [],
    this.onChanged,
  });

  /// When supplied the sheet EDITS this meeting instead of creating one.
  final IMeetMeeting? meeting;

  /// Pre-selected folder for a new meeting.
  final String? defaultFolderId;

  final List<IMeetFolder> folders;

  /// Called after any successful write so the caller can reload its lists.
  final Future<void> Function()? onChanged;

  /// Present the sheet. Returns true when something was saved.
  static Future<bool?> show(
    BuildContext context, {
    IMeetMeeting? meeting,
    String? defaultFolderId,
    List<IMeetFolder> folders = const [],
    Future<void> Function()? onChanged,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => IMeetScheduleSheet(
        meeting: meeting,
        defaultFolderId: defaultFolderId,
        folders: folders,
        onChanged: onChanged,
      ),
    );
  }

  @override
  State<IMeetScheduleSheet> createState() => _IMeetScheduleSheetState();
}

class _IMeetScheduleSheetState extends State<IMeetScheduleSheet> {
  final _service = IMeetService.instance;

  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _agenda;
  final _newFolder = TextEditingController();

  late DateTime _startsAt;
  int _duration = 60;
  String? _folderId;
  final Set<String> _participantIds = {};
  List<Map<String, dynamic>> _people = const [];

  bool _busy = false;
  bool _folderBusy = false;
  String? _error;
  String? _notice;

  bool get _editing => widget.meeting != null;

  /// Only folders the caller OWNS can receive a meeting. A folder shared with
  /// the user is read-only, and the server refuses the move anyway.
  List<IMeetFolder> get _ownedFolders =>
      widget.folders.where((f) => f.isOwner).toList();

  @override
  void initState() {
    super.initState();
    final m = widget.meeting;
    _title = TextEditingController(text: m?.title ?? '');
    _location = TextEditingController(text: m?.location ?? '');
    _agenda = TextEditingController();
    // Default to tomorrow at 09:00 rather than "now", because scheduling is
    // about the future and defaulting to the present instant is never what the
    // user meant.
    final now = DateTime.now();
    var start = DateTime(now.year, now.month, now.day + 1, 9);
    if (m?.startedAt != null) start = m!.startedAt!.toLocal();
    _startsAt = start;
    _folderId = m?.folderId ?? widget.defaultFolderId;
    _loadPeople();
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _agenda.dispose();
    _newFolder.dispose();
    super.dispose();
  }

  Future<void> _loadPeople() async {
    try {
      final rows = await _service.shareablePeople('');
      if (!mounted) return;
      setState(() => _people = rows);
    } catch (_) {
      // A picker that cannot load must never block saving the meeting itself,
      // so this is deliberately swallowed rather than surfaced as an error.
    }
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startsAt,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (date == null || !mounted) return;
    setState(() {
      _startsAt = DateTime(
        date.year,
        date.month,
        date.day,
        _startsAt.hour,
        _startsAt.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startsAt),
    );
    if (time == null || !mounted) return;
    setState(() {
      _startsAt = DateTime(
        _startsAt.year,
        _startsAt.month,
        _startsAt.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Give the meeting a title.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final ids = _participantIds.toList();
      if (_editing) {
        await _service.updateMeetingDetails(
          widget.meeting!.id,
          title: _title.text.trim(),
          startsAt: _startsAt,
          location: _location.text.trim(),
          description: _agenda.text.trim(),
          folderId: _folderId,
          // Always explicit, or clearing the folder is silently ignored.
          moveToFolder: true,
          durationMinutes: _duration,
          participantIds: ids,
        );
      } else {
        await _service.scheduleMeeting(
          title: _title.text.trim(),
          startsAt: _startsAt,
          location: _location.text.trim(),
          description: _agenda.text.trim(),
          folderId: _folderId,
          durationMinutes: _duration,
          participantIds: ids,
        );
      }
      await widget.onChanged?.call();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelMeeting() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this meeting?'),
        content: const Text(
          'It stays in your history, marked as cancelled. Nothing is deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel meeting'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.cancelMeeting(widget.meeting!.id);
      await widget.onChanged?.call();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Create a folder from inside this sheet, so a user can organise a meeting
  /// and create its folder without leaving the flow.
  Future<void> _createFolder() async {
    final name = _newFolder.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _folderBusy = true;
      _error = null;
    });
    try {
      final folder = await _service.createFolder(name);
      _newFolder.clear();
      await widget.onChanged?.call();
      if (!mounted) return;
      setState(() {
        _notice = 'Folder "$name" created.';
        if (folder.id.isNotEmpty) _folderId = folder.id;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not create the folder: $e');
    } finally {
      if (mounted) setState(() => _folderBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  // A container background must never come from a text-ink
                  // helper: textTertiary is tuned for glyphs on a surface, so
                  // using it here produced a handle that vanished in light mode
                  // and glared in dark mode. `border` is the neutral fill used
                  // for decorative chrome.
                  color: AppColors.border(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _editing ? 'Edit meeting' : 'Schedule a meeting',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              _editing
                  ? 'Reschedule it, rename it, or move it to another folder.'
                  : 'Plan it now and record it when the time comes.',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 20),

            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(
                      '${_startsAt.day}/${_startsAt.month}/${_startsAt.year}',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule, size: 16),
                    label: Text(
                      '${_startsAt.hour.toString().padLeft(2, '0')}:'
                      '${_startsAt.minute.toString().padLeft(2, '0')}',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            DropdownButtonFormField<int>(
              initialValue: _duration,
              decoration: const InputDecoration(
                labelText: 'Duration',
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 15, child: Text('15 minutes')),
                DropdownMenuItem(value: 30, child: Text('30 minutes')),
                DropdownMenuItem(value: 60, child: Text('1 hour')),
                DropdownMenuItem(value: 90, child: Text('1 hour 30 minutes')),
                DropdownMenuItem(value: 120, child: Text('2 hours')),
              ],
              onChanged: (v) => setState(() => _duration = v ?? 60),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: _location,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Location or link (optional)',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: _agenda,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Agenda or notes (optional)',
                isDense: true,
              ),
            ),
            const SizedBox(height: 20),

            // ---- Folder -------------------------------------------------------
            Text(
              'Folder',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: _folderId,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('No folder'),
                ),
                for (final f in _ownedFolders)
                  DropdownMenuItem<String?>(
                    value: f.id,
                    child: Text(
                      '${f.name}  (${f.meetingCount})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _folderId = v),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newFolder,
                    decoration: const InputDecoration(
                      labelText: 'New folder name',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _folderBusy ? null : _createFolder,
                  child: _folderBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create'),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ---- Participants ------------------------------------------------
            Text(
              'Participants (${_participantIds.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 8),
            if (_people.isEmpty)
              Text(
                'No one else could be loaded. You can still save the meeting.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary(context),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in _people)
                    FilterChip(
                      label: Text('${p['full_name'] ?? p['email']}'),
                      selected: _participantIds.contains(p['id']),
                      onSelected: (on) => setState(() {
                        final id = '${p['id']}';
                        if (on) {
                          _participantIds.add(id);
                        } else {
                          _participantIds.remove(id);
                        }
                      }),
                    ),
                ],
              ),

            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: AppColors.rose),
              ),
            ],
            if (_notice != null) ...[
              const SizedBox(height: 16),
              Text(
                _notice!,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.accent(context),
                ),
              ),
            ],

            const SizedBox(height: 24),
            Row(
              children: [
                if (_editing) ...[
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _cancelMeeting,
                    icon: const Icon(Icons.event_busy, size: 16),
                    label: const Text('Cancel meeting'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.rose,
                      side: BorderSide(
                        color: AppColors.rose.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check, size: 18),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        _editing ? 'Save changes' : 'Schedule',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
