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
      child: InkWell(
        // Every row opens the full record: the summary line cannot show the
        // geofence verdict, the verification method or the coordinates, and
        // those are exactly what a user needs when a clock-in looks wrong.
        onTap: () => showAttendanceRecordSheet(context, r),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Fmt.dateShort(r.attendanceDate),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary(context),
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
              Icon(
                Icons.chevron_right,
                size: 16,
                color: AppColors.iconMuted(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full detail for one attendance record.
///
/// Everything shown here comes from the stored record, never recomputed: a
/// client-side recalculation of lateness would disagree with the server's shift
/// and grace-period configuration, which is the whole reason the value is
/// persisted alongside the record.
Future<void> showAttendanceRecordSheet(
  BuildContext context,
  AttendanceRecord r,
) {
  final worked = WorkedHours.fromRecord(r);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                Fmt.dateShort(r.attendanceDate),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                Fmt.titleCase(r.status.isEmpty ? 'unknown' : r.status),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: attendanceStatusColor(context, r),
                ),
              ),
            ),
            _DetailGroup(
              children: [
                _DetailRow(
                  label: 'Clock in',
                  value: r.clockIn == null ? '—' : Fmt.clock(r.clockIn),
                ),
                _DetailRow(
                  label: 'Clock out',
                  value: r.clockOut == null ? '—' : Fmt.clock(r.clockOut),
                ),
                _DetailRow(label: 'Hours worked', value: worked.format()),
                _DetailRow(
                  label: 'Late',
                  value: r.lateMinutes > 0
                      ? Fmt.lateDuration(r.lateMinutes)
                      : 'On time',
                  accent: r.lateMinutes > 0 ? AppColors.amber : null,
                ),
                _DetailRow(
                  label: 'Early departure',
                  value: r.earlyDepartureMinutes > 0
                      ? Fmt.lateDuration(r.earlyDepartureMinutes)
                      : 'None',
                  accent: r.earlyDepartureMinutes > 0 ? AppColors.amber : null,
                ),
                _DetailRow(
                  label: 'Overtime',
                  value: r.overtimeMinutes > 0
                      ? Fmt.lateDuration(r.overtimeMinutes)
                      : 'None',
                ),
              ],
            ),
            if (r.source.isNotEmpty ||
                r.verificationMethod.isNotEmpty ||
                r.geofenceStatus.isNotEmpty ||
                r.locationStatus.isNotEmpty) ...[
              const _DetailHeading('VERIFICATION'),
              _DetailGroup(
                children: [
                  if (r.source.isNotEmpty)
                    _DetailRow(
                      label: 'Recorded via',
                      value: Fmt.titleCase(r.source),
                    ),
                  if (r.verificationMethod.isNotEmpty)
                    _DetailRow(
                      label: 'Method',
                      value: Fmt.titleCase(r.verificationMethod),
                    ),
                  if (r.geofenceStatus.isNotEmpty)
                    _DetailRow(
                      label: 'Geofence',
                      value: Fmt.titleCase(r.geofenceStatus),
                      accent: r.geofenceStatus.toLowerCase() == 'inside'
                          ? null
                          : AppColors.rose,
                    ),
                  if (r.locationStatus.isNotEmpty)
                    _DetailRow(
                      label: 'Location',
                      value: Fmt.titleCase(r.locationStatus),
                    ),
                ],
              ),
            ],
            if (r.actualLocationName.isNotEmpty ||
                r.assignedBranchName.isNotEmpty ||
                r.clockInDistance != null) ...[
              const _DetailHeading('LOCATION'),
              _DetailGroup(
                children: [
                  if (r.assignedBranchName.isNotEmpty)
                    _DetailRow(label: 'Branch', value: r.assignedBranchName),
                  if (r.actualLocationName.isNotEmpty)
                    _DetailRow(
                      label: 'Recorded at',
                      value: r.actualLocationName,
                    ),
                  if (r.clockInDistance != null)
                    _DetailRow(
                      label: 'Distance from site',
                      value: '${r.clockInDistance!.toStringAsFixed(0)} m',
                      accent: r.clockInDistance! > 100 ? AppColors.amber : null,
                    ),
                  if (r.clockInLat != null && r.clockInLng != null)
                    _DetailRow(
                      label: 'Coordinates',
                      value:
                          '${r.clockInLat!.toStringAsFixed(5)}, '
                          '${r.clockInLng!.toStringAsFixed(5)}',
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
          ],
        ),
      ),
    ),
  );
}

/// Full detail for one row of the HR/attendance-management feed.
///
/// This is a separate sheet from [showAttendanceRecordSheet] because it is fed
/// by `mobile_attendance_summary`, whose `returns table` exposes a narrower
/// column set than the employee's own history feed — there is no
/// `verification_method`, `source`, `overtime_minutes`, `early_departure_minutes`
/// or `clock_in_distance` on that RPC. Only fields the RPC actually returns are
/// rendered; nothing here is inferred, and no absent column is shown as a
/// misleading "—" that implies the data was recorded and lost.
Future<void> showAttendanceManagementSheet(
  BuildContext context,
  AttendanceManagementRow r,
) {
  final worked = workedHoursFor(r);
  final lat = r.clockInLat;
  final lng = r.clockInLng;

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final colorScheme = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  r.employeeName.isEmpty ? 'Attendance record' : r.employeeName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '${Fmt.dateShort(r.attendanceDate)}'
                  '${r.employeeNumber.isNotEmpty ? ' · ${r.employeeNumber}' : ''}',
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (r.isCurrentlyOpen)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: StatusBadge(
                    label: 'Still clocked in',
                    color: AppColors.violet,
                  ),
                ),
              const _DetailHeading('TIMES'),
              _DetailGroup(
                children: [
                  _DetailRow(
                    label: 'Status',
                    value: Fmt.titleCase(
                      r.status.isEmpty ? 'unknown' : r.status,
                    ),
                  ),
                  _DetailRow(
                    label: 'Clock in',
                    value: r.clockIn == null ? '—' : Fmt.clock(r.clockIn),
                  ),
                  _DetailRow(
                    label: 'Clock out',
                    value: r.clockOut == null ? '—' : Fmt.clock(r.clockOut),
                  ),
                  _DetailRow(label: 'Hours worked', value: worked.format()),
                  _DetailRow(
                    label: 'Late',
                    value: r.lateMinutes > 0
                        ? Fmt.lateDuration(r.lateMinutes)
                        : (r.lateStatus.isEmpty
                              ? 'On time'
                              : Fmt.titleCase(r.lateStatus)),
                    accent: r.lateMinutes > 0 ? AppColors.amber : null,
                  ),
                ],
              ),
              if (r.locationStatus.isNotEmpty ||
                  r.geofenceStatus.isNotEmpty) ...[
                const _DetailHeading('VERIFICATION'),
                _DetailGroup(
                  children: [
                    if (r.geofenceStatus.isNotEmpty)
                      _DetailRow(
                        label: 'Geofence',
                        value: Fmt.titleCase(r.geofenceStatus),
                        accent: r.geofenceStatus.toLowerCase() == 'inside'
                            ? null
                            : AppColors.rose,
                      ),
                    if (r.locationStatus.isNotEmpty)
                      _DetailRow(
                        label: 'Location',
                        value: Fmt.titleCase(r.locationStatus),
                      ),
                  ],
                ),
              ],
              if (r.branchName.isNotEmpty ||
                  r.actualLocationName.isNotEmpty ||
                  r.department.isNotEmpty ||
                  lat != null ||
                  lng != null) ...[
                const _DetailHeading('LOCATION'),
                _DetailGroup(
                  children: [
                    if (r.department.isNotEmpty)
                      _DetailRow(label: 'Department', value: r.department),
                    if (r.branchName.isNotEmpty)
                      _DetailRow(label: 'Branch', value: r.branchName),
                    if (r.actualLocationName.isNotEmpty)
                      _DetailRow(
                        label: 'Recorded at',
                        value: r.actualLocationName,
                      ),
                    if (r.clockInAccuracy != null)
                      _DetailRow(
                        label: 'GPS accuracy',
                        value: '±${r.clockInAccuracy!.toStringAsFixed(0)} m',
                      ),
                    if (lat != null && lng != null)
                      _DetailRow(
                        label: 'Coordinates',
                        value:
                            '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    },
  );
}

/// Colour for a record's status, shared by the summary row and the detail sheet
/// so a day never changes colour between the two views.
Color attendanceStatusColor(BuildContext context, AttendanceRecord r) {
  return switch (r.status.toLowerCase()) {
    'present' || 'on_time' => AppColors.accent(context),
    'late' => AppColors.amber,
    'absent' || 'missing' => AppColors.rose,
    _ => AppColors.textSecondary(context),
  };
}

/// Small caps heading used between the sheet's sections.
class _DetailHeading extends StatelessWidget {
  const _DetailHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: AppColors.textTertiary(context),
        ),
      ),
    );
  }
}

/// Grouped container for the detail rows so the sheet reads as sections rather
/// than one long undifferentiated list.
class _DetailGroup extends StatelessWidget {
  const _DetailGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.brandTint(context, AppColors.accent(context)),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(children: children),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.accent});

  final String label;
  final String value;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: accent ?? AppColors.textPrimary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
