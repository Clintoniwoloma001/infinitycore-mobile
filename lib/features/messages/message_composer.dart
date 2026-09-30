import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_theme.dart';
import 'attachment_service.dart';
import 'voice_service.dart';

/// Cap on a single send, matching the web composer's practical limit. Beyond
/// this the upload is likely to time out on a mobile connection, and the
/// recipient gets a better experience with a link than with a stalled bubble.
const maxAttachmentBytes = 25 * 1024 * 1024;

/// Cap on how many files ride along with one message.
const maxAttachmentsPerMessage = 10;

/// Everything a single send consists of, handed to the parent's `onSend`.
///
/// The attachments are [PendingAttachment]s that have already been uploaded to
/// the private bucket, so the parent only has to forward their metadata to
/// `send_rich_message` — no second round trip, and a failure to upload is
/// surfaced before the user ever taps send.
class MessageDraft {
  const MessageDraft({
    required this.body,
    required this.priority,
    required this.requiresAck,
    required this.attachments,
  });

  final String body;

  /// `normal`, `high` or `urgent`.
  final String priority;

  /// When true the server records an unacknowledged obligation for every
  /// recipient and the blocking gate takes over on their device.
  final bool requiresAck;

  final List<PendingAttachment> attachments;

  bool get isRich =>
      priority != 'normal' || requiresAck || attachments.isNotEmpty;

  /// The `p_files` payload for `send_rich_message`.
  List<Map<String, dynamic>> get rpcFiles => [
    for (final a in attachments) a.toRpcFile(),
  ];
}

/// Full composer: text, attachments, voice notes, priority and the
/// mandatory-acknowledgment toggle.
///
/// Kept as a self-contained widget so direct chats, channels and groups all
/// share one implementation — the only difference between them is the
/// `contextType`/`contextId` pair handed to the uploader, which is what the
/// `send_rich_message` RPC and the storage path both key off.
class MessageComposer extends StatefulWidget {
  const MessageComposer({
    super.key,
    required this.contextType,
    this.contextId,
    required this.onSend,
    this.hintText = 'Type a message…',
    this.enabled = true,
    this.allowPriority = true,
  });

  /// `direct`, `channel` or `group` — mirrors the web `sendRichMessage`
  /// `contextType` and the storage path segment.
  final String contextType;
  final String? contextId;

  /// Invoked with the finished payload. The composer clears itself only after
  /// this completes, so a failed send never loses the user's text.
  final Future<void> Function(MessageDraft draft) onSend;

  final String hintText;
  final bool enabled;

  /// Whether to expose the priority / require-ack controls.
  final bool allowPriority;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  final _recorder = VoiceRecorderService();

  final List<PendingAttachment> _attachments = [];
  String _priority = 'normal';
  bool _requireAck = false;
  bool _sending = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _recorder.addListener(_onRecorderChanged);
  }

  @override
  void dispose() {
    _recorder.removeListener(_onRecorderChanged);
    _controller.dispose();
    _focus.dispose();
    // Release the microphone even if the screen is popped mid-recording.
    _recorder.dispose();
    super.dispose();
  }

  void _onRecorderChanged() {
    if (mounted) setState(() {});
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// Send is enabled as soon as there is something to say, and never while a
  /// send is already in flight. An attachment alone is enough — a voice note or
  /// a photo is a complete message.
  bool get _canSend {
    if (!widget.enabled || _sending) return false;
    if (_recorder.isRecording) return false;
    return _controller.text.trim().isNotEmpty || _attachments.isNotEmpty;
  }

  Future<void> _send() async {
    if (_sending) return;
    final body = _controller.text.trim();
    if (body.isEmpty && _attachments.isEmpty) return;

    // Anything that failed to upload is a hard stop: silently dropping a file
    // the user believed they attached is worse than refusing to send.
    if (_attachments.any((a) => a.stage == AttachmentStage.failed)) {
      _snack('Fix or remove the failed upload before sending.');
      return;
    }
    if (_uploading) {
      _snack('Still uploading — one moment.');
      return;
    }

    setState(() => _sending = true);
    final draft = MessageDraft(
      body: body,
      priority: _priority,
      requiresAck: _requireAck,
      attachments: List.of(_attachments),
    );
    try {
      await widget.onSend(draft);
      if (!mounted) return;
      setState(() {
        _attachments.clear();
        _priority = 'normal';
        _requireAck = false;
      });
      _controller.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ------------------------------------------------------------------
  // Attachments
  // ------------------------------------------------------------------

  Future<void> _pickImages(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 2400,
      );
      if (picked == null) return;
      await _addFiles([(picked.path, picked.name)]);
    } catch (e) {
      debugPrint('[MessageComposer] image pick failed: $e');
      if (mounted) _snack('The photo could not be attached.');
    }
  }

  Future<void> _pickDocuments() async {
    try {
      // file_picker 13 returns the selected `PlatformFile`s directly; a null
      // path means the provider handed back a name only (iOS without a cached
      // copy), which cannot be uploaded and is skipped.
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Attach a document',
      );
      if (files.isEmpty) return;
      final picked = <(String, String)>[];
      for (final f in files) {
        final path = f.path;
        if (path == null || path.isEmpty) continue;
        picked.add((path, f.name));
      }
      await _addFiles(picked);
    } catch (e) {
      debugPrint('[MessageComposer] file pick failed: $e');
      if (mounted) _snack('That file could not be attached.');
    }
  }

  Future<void> _addFiles(List<(String, String)> files) async {
    if (files.isEmpty) return;
    final room = maxAttachmentsPerMessage - _attachments.length;
    if (room <= 0) {
      _snack(
        'You can attach up to $maxAttachmentsPerMessage files per message.',
      );
      return;
    }
    final accepted = <PendingAttachment>[];
    for (final (path, name) in files.take(room)) {
      var size = 0;
      try {
        size = await File(path).length();
      } catch (_) {
        // A path that vanished between picking and reading is reported below.
      }
      if (size > maxAttachmentBytes) {
        _snack('${_shortName(name)} is larger than 25 MB.');
        continue;
      }
      accepted.add(
        PendingAttachment(
          path: path,
          fileName: name,
          mimeType: mimeTypeForPath(path),
          sizeBytes: size,
        ),
      );
    }
    if (accepted.isEmpty) return;
    setState(() => _attachments.addAll(accepted));
    await _uploadAll();
  }

  String _shortName(String name) =>
      name.length <= 28 ? name : '${name.substring(0, 25)}…';

  /// Uploads every queued attachment, keeping the rows visible throughout so
  /// the user can watch progress and retry an individual failure.
  Future<void> _uploadAll() async {
    final queued = _attachments
        .where((a) => a.stage == AttachmentStage.queued)
        .toList();
    if (queued.isEmpty) return;
    setState(() => _uploading = true);
    for (final a in queued) {
      if (!mounted) return;
      setState(() {});
      await AttachmentUploadService.instance.upload(
        attachment: a,
        contextType: widget.contextType,
        contextId: widget.contextId,
        onProgress: (p) {
          if (mounted) setState(() => a.progress = p);
        },
      );
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _uploading = false);
  }

  void _remove(PendingAttachment a) => setState(() => _attachments.remove(a));

  void _retry(PendingAttachment a) {
    a
      ..stage = AttachmentStage.queued
      ..error = null;
    setState(() {});
    _uploadAll();
  }

  // ------------------------------------------------------------------
  // Voice
  // ------------------------------------------------------------------

  Future<void> _toggleRecording() async {
    if (_recorder.isRecording) {
      final note = await _recorder.stop();
      if (!mounted) return;
      if (note == null) {
        final err = _recorder.error?.message;
        if (err != null) _snack(err);
        return;
      }
      setState(() => _attachments.add(note));
      await _uploadAll();
      return;
    }
    final started = await _recorder.start();
    if (!mounted) return;
    if (!started && _recorder.error != null) {
      _snack(_recorder.error!.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        border: Border(top: BorderSide(color: AppColors.border(context))),
      ),
      padding: EdgeInsets.fromLTRB(10, 8, 10, 8 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_attachments.isNotEmpty)
            _AttachmentStrip(
              attachments: _attachments,
              onRemove: _remove,
              onRetry: _retry,
            ),
          if (_recorder.isRecording)
            _RecordingBar(
              elapsed: _recorder.elapsed,
              onStop: _toggleRecording,
              onCancel: () {
                _recorder.cancel().then((_) {
                  if (mounted) setState(() {});
                });
              },
            ),
          if (widget.allowPriority && (_priority != 'normal' || _requireAck))
            _PriorityStrip(
              priority: _priority,
              requireAck: _requireAck,
              onPriority: (p) => setState(() {
                // Demoting back to normal also drops the acknowledgment flag:
                // demanding a receipt on an unremarkable message is noise.
                _priority = p;
                if (p == 'normal') _requireAck = false;
              }),
              onRequireAck: (v) => setState(() => _requireAck = v),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _CircleButton(
                icon: Icons.attach_file,
                tooltip: 'Attach',
                onPressed: widget.enabled ? _openAttachSheet : null,
              ),
              _CircleButton(
                icon: _recorder.isRecording
                    ? Icons.stop_rounded
                    : Icons.mic_none_rounded,
                tooltip: _recorder.isRecording
                    ? 'Stop recording'
                    : 'Record a voice note',
                active: _recorder.isRecording,
                onPressed: widget.enabled ? _toggleRecording : null,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    enabled: widget.enabled,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.allowPriority)
                _CircleButton(
                  icon: Icons.priority_high_rounded,
                  tooltip: 'Priority and acknowledgment',
                  active: _priority != 'normal' || _requireAck,
                  onPressed: widget.enabled
                      ? () => _openPrioritySheet(context)
                      : null,
                ),
              const SizedBox(width: 6),
              // `ListenableBuilder` rather than `ValueListenableBuilder`: the
              // recorder is a `ChangeNotifier`, and rebuilding on every tick is
              // what keeps the clock and the button state in sync.
              ListenableBuilder(
                listenable: _recorder,
                builder: (context, _) => IconButton.filled(
                  onPressed: _canSend ? _send : null,
                  style: IconButton.styleFrom(
                    backgroundColor: _priority == 'urgent'
                        ? AppColors.rose
                        : AppColors.accent(context),
                    disabledBackgroundColor: AppColors.accent(context)
                        .withValues(alpha: 0.35),
                    minimumSize: const Size(44, 44),
                  ),
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.arrow_right,
                          color: Colors.white,
                          size: 20,
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openAttachSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickImages(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickImages(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Document or file'),
              subtitle: const Text('PDF, Word, Excel, ZIP — up to 25 MB'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickDocuments();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openPrioritySheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _PrioritySheet(
        priority: _priority,
        requireAck: _requireAck,
        onChanged: (p, ack) => setState(() {
          _priority = p;
          _requireAck = ack;
        }),
      ),
    );
  }
}

/// Small icon button used for attach / mic / priority in the composer row.
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Renders the button in the alert colour — used while recording, or while a
  /// priority/ack flag is set, so the state is visible without opening a sheet.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.rose : AppColors.textSecondary(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 22),
        color: color,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// Horizontal strip of queued attachments with live upload state.
///
/// Each row is a tappable target: a failed upload retries, any row can be
/// removed. Progress is a determinate bar where the platform reports bytes and
/// an indeterminate one otherwise.
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
  });

  final List<PendingAttachment> attachments;
  final ValueChanged<PendingAttachment> onRemove;
  final ValueChanged<PendingAttachment> onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 62,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: attachments.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) => _AttachmentChip(
            attachment: attachments[i],
            onRemove: () => onRemove(attachments[i]),
            onRetry: () => onRetry(attachments[i]),
          ),
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
  });

  final PendingAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = attachment.stage == AttachmentStage.failed;
    final uploading = attachment.stage == AttachmentStage.uploading;
    final type = attachmentTypeFor(attachment.fileName, attachment.mimeType);
    final accent = failed
        ? AppColors.rose
        : type == 'voice_note' || type == 'audio'
        ? AppColors.orange
        : AppColors.accent(context);
    final icon = switch (type) {
      'image' => Icons.image_outlined,
      'voice_note' || 'audio' => Icons.graphic_eq_rounded,
      'video' => Icons.movie_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'spreadsheet' => Icons.table_chart_outlined,
      'archive' => Icons.folder_zip_outlined,
      _ => Icons.insert_drive_file_outlined,
    };

    return Container(
      width: 190,
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: failed || uploading
              ? accent.withValues(alpha: 0.5)
              : AppColors.border(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  attachment.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary(context),
                  ),
                ),
              ),
              InkWell(
                onTap: onRemove,
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.close,
                    size: 15,
                    color: AppColors.iconMuted(context),
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: Text(
                  _statusLine(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: failed
                        ? AppColors.rose
                        : AppColors.textTertiary(context),
                  ),
                ),
              ),
              if (failed)
                GestureDetector(
                  onTap: onRetry,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'Retry',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: AppColors.rose,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (uploading)
            LinearProgressIndicator(
              value: attachment.progress < 0 ? null : attachment.progress,
              minHeight: 3,
              backgroundColor: AppColors.border(context),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            )
          else
            Container(
              height: 3,
              decoration: BoxDecoration(
                color: failed
                    ? AppColors.rose
                    : AppColors.accent(context).withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
        ],
      ),
    );
  }

  String _statusLine() {
    switch (attachment.stage) {
      case AttachmentStage.queued:
        return 'Waiting to upload…';
      case AttachmentStage.uploading:
        final pct = (attachment.progress * 100).round();
        return pct <= 0 ? 'Uploading…' : 'Uploading $pct%';
      case AttachmentStage.uploaded:
        return _sizeLabel();
      case AttachmentStage.failed:
        return attachment.error ?? 'Upload failed';
    }
  }

  String _sizeLabel() {
    final bytes = attachment.sizeBytes;
    if (bytes <= 0) return 'Ready';
    final kb = bytes ~/ 1024;
    if (kb < 1024) return '$kb KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}

/// Live recording bar: elapsed time, a discard and an attach control.
class _RecordingBar extends StatelessWidget {
  const _RecordingBar({
    required this.elapsed,
    required this.onStop,
    required this.onCancel,
  });

  final Duration elapsed;
  final VoidCallback onStop;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final remaining = VoiceRecorderService.maxDuration - elapsed;
    final nearLimit = remaining.inSeconds <= 30;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.brandTint(context, AppColors.rose),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.rose.withValues(alpha: nearLimit ? 0.7 : 0.35),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.fiber_manual_record,
              size: 16,
              color: AppColors.rose,
            ),
            const SizedBox(width: 8),
            Text(
              formatVoiceDuration(elapsed),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: AppColors.rose,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                nearLimit
                    ? '${remaining.inSeconds}s left'
                    : 'Recording a voice note',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ),
            TextButton(onPressed: onCancel, child: const Text('Discard')),
            FilledButton.icon(
              onPressed: onStop,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.rose,
                foregroundColor: Colors.white,
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('Attach'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact reminder of the priority / acknowledgment flags currently set.
class _PriorityStrip extends StatelessWidget {
  const _PriorityStrip({
    required this.priority,
    required this.requireAck,
    required this.onPriority,
    required this.onRequireAck,
  });

  final String priority;
  final bool requireAck;
  final ValueChanged<String> onPriority;
  final ValueChanged<bool> onRequireAck;

  @override
  Widget build(BuildContext context) {
    final accent = priority == 'urgent'
        ? AppColors.rose
        : AppColors.warn(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ChoiceChip(
            label: Text(priority == 'urgent' ? 'Urgent' : 'Important'),
            avatar: Icon(
              priority == 'urgent'
                  ? Icons.priority_high_rounded
                  : Icons.keyboard_double_arrow_up_rounded,
              size: 16,
              color: Colors.white,
            ),
            selected: true,
            // Tapping the chip escalates between important and urgent; the
            // sheet is the only way back to normal, which keeps the escalation
            // a deliberate two-step action.
            onSelected: (_) =>
                onPriority(priority == 'urgent' ? 'high' : 'urgent'),
            selectedColor: accent,
            labelStyle: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
            backgroundColor: AppColors.surface(context),
            side: BorderSide(color: accent),
          ),
          FilterChip(
            label: const Text('Require acknowledgement'),
            avatar: Icon(
              requireAck ? Icons.done_all_rounded : Icons.done_all_outlined,
              size: 16,
              color: requireAck
                  ? Colors.white
                  : AppColors.textSecondary(context),
            ),
            selected: requireAck,
            onSelected: onRequireAck,
            selectedColor: accent,
            labelStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: requireAck
                  ? Colors.white
                  : AppColors.textSecondary(context),
            ),
            backgroundColor: AppColors.surface(context),
            side: BorderSide(
              color: requireAck ? accent : AppColors.border(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet for the full priority / acknowledgment choice, including the
/// way back to a normal message.
class _PrioritySheet extends StatelessWidget {
  const _PrioritySheet({
    required this.priority,
    required this.requireAck,
    required this.onChanged,
  });

  final String priority;
  final bool requireAck;
  final void Function(String priority, bool requireAck) onChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Message priority',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'An important or urgent message is highlighted for everyone. '
                'Requiring an acknowledgement means each recipient must confirm '
                'they have read it before the app unlocks.',
                style: TextStyle(fontSize: 12, height: 1.35),
              ),
            ),
            RadioGroup<String>(
              groupValue: priority,
              onChanged: (v) {
                if (v == null) return;
                // Demoting to normal clears the acknowledgment flag: demanding a
                // receipt on an unremarkable message is noise.
                onChanged(v, v == 'normal' ? false : requireAck);
              },
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile(
                    value: 'normal',
                    title: Text('Normal'),
                    subtitle: Text('Standard delivery, no highlighting'),
                  ),
                  RadioListTile(
                    value: 'high',
                    title: Text('Important'),
                    subtitle: Text('Highlighted, shown first in the thread'),
                  ),
                  RadioListTile(
                    value: 'urgent',
                    title: Text('Urgent'),
                    subtitle: Text(
                      'Red alert styling and a heads-up alert on every device',
                    ),
                  ),
                ],
              ),
            ),
            if (priority != 'normal') ...[
              const Divider(height: 1),
              SwitchListTile(
                value: requireAck,
                onChanged: (v) => onChanged(priority, v),
                title: const Text('Require acknowledgement'),
                subtitle: const Text(
                  'Recipients must confirm before continuing. A reminder '
                  'repeats every 5 minutes until they do.',
                ),
                isThreeLine: true,
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
