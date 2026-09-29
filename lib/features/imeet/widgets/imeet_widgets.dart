import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../imeet_models.dart';

/// Shared presentational pieces for I-Meet.
///
/// Every widget is theme-driven through [AppColors], so I-Meet inherits the
/// platform's light/dark language instead of introducing a second palette
/// (section 10). No hard-coded surface colour appears below.

/// A meeting's pipeline state, as a pill.
///
/// Colour is never the ONLY signal: each state also carries an icon and a word,
/// which is what section 33 requires.
class IMeetStatusPill extends StatelessWidget {
  const IMeetStatusPill({
    super.key,
    required this.status,
    this.compact = false,
  });

  final IMeetStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      IMeetStatus.ready => (Icons.check_circle_outline, AppColors.green),
      IMeetStatus.processing => (Icons.hourglass_top, AppColors.amber),
      IMeetStatus.recording => (Icons.mic, AppColors.rose),
      IMeetStatus.failed => (Icons.error_outline, AppColors.rose),
      IMeetStatus.archived => (
        Icons.archive_outlined,
        AppColors.textTertiary(context),
      ),
      IMeetStatus.draft => (Icons.edit_note, AppColors.textTertiary(context)),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 11 : 12, color: color),
          SizedBox(width: compact ? 3 : 4),
          Text(
            status.label,
            style: TextStyle(
              fontSize: compact ? 9 : 10,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// One row in the meeting list.
///
/// Carries exactly what the list needs and nothing heavy: no transcript and no
/// audio, so a long history stays fast (section 30).
class IMeetMeetingTile extends StatelessWidget {
  const IMeetMeetingTile({
    super.key,
    required this.meeting,
    required this.onTap,
    this.recordingCount = 0,
    this.hasSummary = false,
    this.folderName,
  });

  final IMeetMeeting meeting;
  final VoidCallback onTap;
  final int recordingCount;
  final bool hasSummary;
  final String? folderName;

  @override
  Widget build(BuildContext context) {
    final when = meeting.startedAt?.toLocal();
    final dd = when?.day.toString().padLeft(2, '0') ?? '';
    final mm = when?.month.toString().padLeft(2, '0') ?? '';
    final date = when == null ? '' : '$dd/$mm/${when.year}';
    final time = when == null
        ? ''
        : '${when.hour.toString().padLeft(2, '0')}:'
              '${when.minute.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      meeting.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IMeetStatusPill(status: meeting.status, compact: true),
                ],
              ),
              if (date.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '$date · $time',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ],
              if (meeting.location?.isNotEmpty == true) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      Icons.place_outlined,
                      size: 12,
                      color: AppColors.textTertiary(context),
                    ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        meeting.location!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (recordingCount > 0)
                    _MetaChip(
                      icon: Icons.graphic_eq,
                      label: recordingCount == 1
                          ? '1 recording'
                          : '$recordingCount recordings',
                    ),
                  if (hasSummary)
                    const _MetaChip(
                      icon: Icons.auto_awesome,
                      label: 'AI summary',
                      accent: AppColors.green,
                    ),
                  if (folderName != null)
                    _MetaChip(icon: Icons.folder_outlined, label: folderName!),
                  if (meeting.isFromCalendar)
                    const _MetaChip(
                      icon: Icons.event_available,
                      label: 'From calendar',
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, this.accent});

  final IconData icon;
  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? AppColors.textTertiary(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
