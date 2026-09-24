import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../models/models.dart';
import '../utils/formatters.dart';
import 'common.dart';

enum HistoryRange { day, week, month }

/// Reusable attendance history list with DAY / WEEK / MONTH filtering.
///
/// Used on both the Home dashboard and the Attendance tab. The client only
/// renders records already fetched from the server; the server stays the
/// authoritative source.
class AttendanceHistoryCard extends StatefulWidget {
  const AttendanceHistoryCard({
    super.key,
    required this.records,
    this.title = 'Attendance history',
    this.emptyText = 'Clock in to create your first attendance record.',
    this.maxRows = 12,
  });

  final List<AttendanceRecord> records;
  final String title;
  final String emptyText;
  final int maxRows;

  @override
  State<AttendanceHistoryCard> createState() => _AttendanceHistoryCardState();
}

class _AttendanceHistoryCardState extends State<AttendanceHistoryCard> {
  HistoryRange _range = HistoryRange.month;

  List<AttendanceRecord> get _filtered {
    final now = DateTime.now();
    return widget.records.where((r) {
      final date = DateTime.tryParse(r.attendanceDate);
      if (date == null) return false;
      final local = date.toLocal();
      switch (_range) {
        case HistoryRange.day:
          return local.year == now.year &&
              local.month == now.month &&
              local.day == now.day;
        case HistoryRange.week:
          final delta = now.difference(local).inDays;
          return local.isBefore(now.add(const Duration(days: 1))) && delta < 7;
        case HistoryRange.month:
          return local.year == now.year && local.month == now.month;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;

    return SectionCard(
      title: widget.title,
      trailing: _rangeSelector(secondary),
      children: rows.isEmpty
          ? [
              Text(
                widget.emptyText,
                style: TextStyle(fontSize: 12, color: secondary),
              ),
            ]
          : rows.take(widget.maxRows).map((r) => _row(r, secondary)).toList(),
    );
  }

  Widget _rangeSelector(Color secondary) {
    return SegmentedButton<HistoryRange>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        selectedBackgroundColor: AppColors.accent(context)
            .withValues(alpha: 0.16),
        selectedForegroundColor: AppColors.accent(context),
      ),
      segments: const [
        ButtonSegment(
          value: HistoryRange.day,
          label: Text('DAY'),
          icon: Icon(Icons.today_outlined, size: 14),
        ),
        ButtonSegment(
          value: HistoryRange.week,
          label: Text('WEEK'),
          icon: Icon(Icons.date_range_outlined, size: 14),
        ),
        ButtonSegment(
          value: HistoryRange.month,
          label: Text('MONTH'),
          icon: Icon(Icons.calendar_month_outlined, size: 14),
        ),
      ],
      selected: {_range},
      onSelectionChanged: (sel) => setState(() => _range = sel.first),
    );
  }

  Widget _row(AttendanceRecord r, Color secondary) {
    final present = r.clockIn != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Fmt.dateShort(r.attendanceDate),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (present)
                  Text(
                    '${Fmt.clock(r.clockIn)} — ${Fmt.clock(r.clockOut)}',
                    style: TextStyle(fontSize: 12, color: secondary),
                  )
                else
                  Text(
                    Fmt.titleCase(r.status.isEmpty ? 'absent' : r.status),
                    style: TextStyle(fontSize: 12, color: secondary),
                  ),
              ],
            ),
          ),
          if (present) ...[
            Text(
              '${WorkedHours.fromRecord(r).format()}'
              '${r.lateMinutes > 0 ? ' · ${Fmt.lateDuration(r.lateMinutes)} late' : ''}',
              style: TextStyle(
                fontSize: 12,
                color: r.lateMinutes > 0 ? AppColors.amber : secondary,
              ),
            ),
            if (r.lateMinutes > 0) ...[
              const SizedBox(width: 4),
              const Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: AppColors.amber,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
