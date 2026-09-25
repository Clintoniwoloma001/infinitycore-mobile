import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import 'communication_service.dart';

/// Compact relative timestamp used across conversation rows and bubbles.
String relativeTime(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  final local = dt.toLocal();
  final now = DateTime.now();
  final diff = now.difference(local);
  if (diff.isNegative) return Fmt.timeShort(iso);
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  if (local.year == now.year) {
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    return '$day/$month';
  }
  return Fmt.dateShort(iso);
}

/// Opens the operating system dialler for a colleague.
///
/// This is a *phone* call (`tel:`), deliberately kept separate from any future
/// in-app internet calling. The action is only rendered when a valid number
/// exists, and the number is never logged or persisted by this app.
Future<bool> placePhoneCall(String? phone) async {
  final raw = (phone ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
  if (raw.isEmpty) return false;
  final uri = Uri(scheme: 'tel', path: raw);
  try {
    return await launchUrl(uri) ||
        await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Bottom sheet showing an employee's details, with a phone action that only
/// appears when the resolved record actually carries a phone number.
Future<void> showEmployeeProfileSheet(
  BuildContext context, {
  required Map<String, dynamic> identity,
  void Function(String userId)? onMessage,
}) async {
  final name = '${identity['full_name'] ?? identity['email'] ?? 'Colleague'}'
      .trim();
  final phone = '${identity['phone'] ?? ''}'.trim();
  final role = '${identity['role'] ?? ''}'.trim();
  final department = '${identity['department'] ?? ''}'.trim();
  final branch = '${identity['branch'] ?? ''}'.trim();
  final position = '${identity['position'] ?? ''}'.trim();
  final userId = '${identity['user_id'] ?? ''}'.trim();
  final hasPhone = phone.isNotEmpty;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AvatarCircle(name: name, size: 56),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary(context),
                        ),
                      ),
                      if (position.isNotEmpty)
                        Text(
                          position,
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary(context),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (role.isNotEmpty)
              InfoRow(label: 'Role', value: Fmt.titleCase(role)),
            if (department.isNotEmpty)
              InfoRow(label: 'Department', value: department),
            if (branch.isNotEmpty)
              InfoRow(label: 'Branch', value: Fmt.titleCase(branch)),
            if ('${identity['email'] ?? ''}'.trim().isNotEmpty)
              InfoRow(label: 'Email', value: '${identity['email']}'),
            const SizedBox(height: 18),
            Row(
              children: [
                if (hasPhone)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await placePhoneCall(phone);
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'This device cannot place phone calls.',
                              ),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.phone_android, size: 18),
                      label: const Text('Call'),
                    ),
                  ),
                if (hasPhone && onMessage != null) const SizedBox(width: 10),
                if (onMessage != null && userId.isNotEmpty)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        onMessage(userId);
                      },
                      icon: const Icon(Icons.inbox_outlined, size: 18),
                      label: const Text('Message'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Attachment tile for a message. Images get an inline preview, everything else
/// gets a tappable file row that opens a short-lived signed URL.
///
/// Access is always authorised by the `chat_attachment_read` storage policy, so
/// possessing a path is not sufficient to read a file.
class MessageAttachmentTile extends StatefulWidget {
  const MessageAttachmentTile({super.key, required this.attachment});

  final Map<String, dynamic> attachment;

  @override
  State<MessageAttachmentTile> createState() => _MessageAttachmentTileState();
}

class _MessageAttachmentTileState extends State<MessageAttachmentTile> {
  bool _busy = false;

  bool get _isImage {
    final type = '${widget.attachment['file_type'] ?? ''}'.toLowerCase();
    final path = '${widget.attachment['file_path'] ?? ''}'.toLowerCase();
    return type.startsWith('image/') ||
        path.endsWith('.png') ||
        path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.webp');
  }

  String get _name {
    final raw = '${widget.attachment['file_name'] ?? 'Attachment'}'.trim();
    if (raw.isEmpty) return 'Attachment';
    return raw.length > 42 ? '${raw.substring(0, 39)}…' : raw;
  }

  String get _size {
    final bytes = int.tryParse('${widget.attachment['file_size'] ?? ''}');
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData get _icon {
    final type = '${widget.attachment['file_type'] ?? ''}'.toLowerCase();
    if (type == 'application/pdf' || _name.toLowerCase().endsWith('.pdf')) {
      return Icons.link;
    }
    if (type.startsWith('image/')) return Icons.camera_alt;
    return Icons.link;
  }

  Future<void> _open() async {
    if (_busy) return;
    final path = '${widget.attachment['file_path'] ?? ''}'.trim();
    if (path.isEmpty) return;
    setState(() => _busy = true);
    try {
      final url = await CommunicationService.instance.signedAttachmentUrl(path);
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        _toast('This attachment could not be opened.');
        return;
      }
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      _toast('This attachment could not be opened.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isImage) {
      return GestureDetector(
        onTap: _open,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _ImagePreview(path: '${widget.attachment['file_path'] ?? ''}'),
        ),
      );
    }
    return InkWell(
      onTap: _open,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.accent(context).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 18, color: AppColors.accent(context)),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary(context),
                    ),
                  ),
                  if (_size.isNotEmpty)
                    Text(
                      _size,
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.textTertiary(context),
                      ),
                    ),
                ],
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              Icon(Icons.link, size: 14, color: AppColors.iconMuted(context)),
          ],
        ),
      ),
    );
  }
}

/// A single message bubble with priority/official header, attachments,
/// reactions and a delivery indicator.
///
/// Long-press opens [onLongPress] (the action sheet). This is shared by the
/// direct-chat and group/channel conversation screens so both render messages
/// identically.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.senderName,
    required this.attachments,
    required this.reactions,
    required this.myUserId,
    required this.onLongPress,
    required this.onToggleReaction,
  });

  final Map<String, dynamic> message;
  final bool isMine;
  final String senderName;
  final List<Map<String, dynamic>> attachments;
  final Map<String, List<String>> reactions;
  final String myUserId;
  final VoidCallback onLongPress;
  final void Function(String emoji, bool mine) onToggleReaction;

  @override
  Widget build(BuildContext context) {
    final body = '${message['body'] ?? ''}';
    final priority = '${message['priority'] ?? 'normal'}';
    final official =
        message['is_official'] == true || message['is_official'] == 'true';
    final createdAt = '${message['created_at'] ?? ''}';
    final queued = '${message['id'] ?? ''}'.startsWith('optimistic_');

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: isMine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (!isMine && senderName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 3),
                child: Text(
                  senderName,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.blue,
                  ),
                ),
              ),
            GestureDetector(
              onLongPress: onLongPress,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: isMine
                      ? AppColors.accent(context)
                      : AppColors.surface(context),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(14),
                    topRight: const Radius.circular(14),
                    bottomLeft: Radius.circular(isMine ? 14 : 4),
                    bottomRight: Radius.circular(isMine ? 4 : 14),
                  ),
                  border: isMine
                      ? null
                      : Border.all(color: AppColors.border(context)),
                ),
                child: Column(
                  crossAxisAlignment: isMine
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (official || priority == 'urgent' || priority == 'high')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              official
                                  ? Icons.verified_outlined
                                  : Icons.warning_amber_rounded,
                              size: 12,
                              color: isMine ? Colors.white70 : AppColors.amber,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              official ? 'OFFICIAL' : priority.toUpperCase(),
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                                color: isMine
                                    ? Colors.white70
                                    : AppColors.amber,
                              ),
                            ),
                          ],
                        ),
                      ),
                    for (final f in attachments)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: MessageAttachmentTile(attachment: f),
                      ),
                    if (body.isNotEmpty)
                      Text(
                        body,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          color: isMine
                              ? Colors.white
                              : AppColors.textPrimary(context),
                        ),
                      ),
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          Fmt.timeShort(createdAt),
                          style: TextStyle(
                            fontSize: 10,
                            color: isMine
                                ? Colors.white60
                                : AppColors.textTertiary(context),
                          ),
                        ),
                        if (isMine) ...[
                          const SizedBox(width: 4),
                          Icon(
                            queued ? Icons.schedule : Icons.check,
                            size: 12,
                            color: Colors.white70,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (reactions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 6, right: 6),
                child: ReactionBar(
                  reactions: {'m': reactions},
                  myUserId: myUserId,
                  onToggle: (_, emoji, mine) => onToggleReaction(emoji, mine),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lazily signed image preview. The URL is minted only when the tile builds,
/// so a long history does not create a signed URL per attachment up front.
class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.path});
  final String path;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  late final Future<String?> _url = CommunicationService.instance
      .signedAttachmentUrl(widget.path);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _url,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Container(
            width: 180,
            height: 120,
            color: AppColors.border(context),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final url = snapshot.data;
        if (url == null || url.isEmpty) {
          return Container(
            width: 180,
            height: 100,
            color: AppColors.border(context),
            child: const Center(child: Icon(Icons.no_photography_outlined)),
          );
        }
        return Image.network(
          url,
          width: 180,
          height: 120,
          fit: BoxFit.cover,
          // Decode at a bounded width so a large photo does not blow up memory.
          cacheWidth: 480,
          errorBuilder: (_, _, _) => Container(
            width: 180,
            height: 100,
            color: AppColors.border(context),
            child: const Center(child: Icon(Icons.no_photography_outlined)),
          ),
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : Container(
                  width: 180,
                  height: 120,
                  color: AppColors.border(context),
                  child: const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// Reaction chips under a message. Tapping toggles the caller's own reaction;
/// server RLS pins `user_id` to `auth.uid()` so this cannot be spoofed.
class ReactionBar extends StatelessWidget {
  const ReactionBar({
    super.key,
    required this.reactions,
    required this.myUserId,
    required this.onToggle,
  });

  /// message_id -> emoji -> user ids
  final Map<String, Map<String, List<String>>> reactions;
  final String myUserId;
  final void Function(String messageId, String emoji, bool mine) onToggle;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final entry in reactions.entries)
          for (final e in entry.value.entries)
            _ReactionChip(
              label:
                  '${e.key}${e.value.length > 1 ? ' ${e.value.length}' : ''}',
              selected: e.value.contains(myUserId),
              onTap: () =>
                  onToggle(entry.key, e.key, e.value.contains(myUserId)),
            ),
      ],
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent(context).withValues(alpha: 0.16)
              : AppColors.surface(context),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? AppColors.accent(context)
                : AppColors.border(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected
                ? AppColors.accent(context)
                : AppColors.textSecondary(context),
          ),
        ),
      ),
    );
  }
}

/// Picks an emoji and returns it, or null when dismissed.
Future<String?> pickReactionEmoji(BuildContext context) {
  const emojis = ['👍', '❤️', '😂', '🎉', '🙏', '👀'];
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
        child: Wrap(
          spacing: 8,
          children: [
            for (final e in emojis)
              InkWell(
                onTap: () => Navigator.of(context).pop(e),
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(e, style: const TextStyle(fontSize: 26)),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Copies text to the clipboard and confirms with a snackbar.
Future<void> copyToClipboard(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Message copied'),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
