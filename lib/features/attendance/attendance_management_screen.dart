import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services/reminder_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import 'attendance_service.dart';

/// HR/attendance-management view. Backed by the server-authoritative
/// `mobile_attendance_summary` RPC; the backend enforces which roles may use
/// it (super_admin, admin, head_of_human_resources, hr_officer,
/// branch_manager).
class AttendanceManagementScreen extends StatefulWidget {
  const AttendanceManagementScreen({super.key});

  @override
  State<AttendanceManagementScreen> createState() =>
      _AttendanceManagementScreenState();
}

class _AttendanceManagementScreenState
    extends State<AttendanceManagementScreen> {
  final _service = AttendanceService.instance;

  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();
  String? _status;
  String? _branchId;
  String _query = '';

  List<AttendanceManagementRow> _rows = [];
  bool _loading = true;
  String? _error;
  ReminderSettings? _reminders;

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
      final rows = await _service.managementSummary(
        from: _from,
        to: _to,
        branchId: _branchId,
        status: _status,
      );
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    _loadReminders();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadReminders() async {
    try {
      final reminders = await _service.getReminderSettings();
      if (mounted) setState(() => _reminders = reminders);
    } catch (_) {
      // Reminder settings are optional; the grid still renders without them.
    }
  }

  List<String> get _branchOptions {
    final seen = <String>{};
    final out = <String>[];
    for (final r in _rows) {
      final key = r.branchId.isEmpty ? '_' : r.branchId;
      if (seen.add(key)) {
        out.add(r.branchName.isEmpty ? 'Unassigned' : r.branchName);
      }
    }
    return out;
  }

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _from,
      firstDate: DateTime(2020),
      lastDate: _to,
    );
    if (picked != null) {
      setState(() => _from = picked);
      _load();
    }
  }

  Future<void> _pickTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _to,
      firstDate: _from,
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) {
      setState(() => _to = picked);
      _load();
    }
  }

  List<AttendanceManagementRow> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows
        .where(
          (r) =>
              r.employeeName.toLowerCase().contains(q) ||
              r.employeeNumber.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _rows.isEmpty && _error == null) {
      return const PageLoadingView(label: 'Loading attendance summary…');
    }
    if (_error != null && _rows.isEmpty) {
      return PageErrorView(message: _error!, onRetry: _load);
    }
    final rows = _filtered;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        padding: const EdgeInsets.all(16),
        children: [
          _filterCard(),
          _reminderCard(),
          const SizedBox(height: 12),
          for (final r in rows) ...[_rowCard(r), const SizedBox(height: 8)],
          if (rows.isEmpty)
            SectionCard(
              title: 'Attendance summary',
              children: [
                Text(
                  'No attendance records match the selected filters.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _filterCard() {
    return Card(
      margin: EdgeInsets.zero,
      color: AppColors.surface(context),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickFrom,
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(DateFormat('d MMM yyyy').format(_from)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '→',
                    style: TextStyle(color: AppColors.iconMuted(context)),
                  ),
                ),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTo,
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(DateFormat('d MMM yyyy').format(_to)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _status ?? 'all',
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Status',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'all',
                        child: Text('All statuses'),
                      ),
                      DropdownMenuItem(
                        value: 'present',
                        child: Text('Present'),
                      ),
                      DropdownMenuItem(value: 'late', child: Text('Late')),
                      DropdownMenuItem(value: 'absent', child: Text('Absent')),
                      DropdownMenuItem(
                        value: 'pending',
                        child: Text('Pending'),
                      ),
                    ],
                    onChanged: (v) {
                      setState(
                        () => _status = v == null || v == 'all' ? null : v,
                      );
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                if (_branchOptions.isNotEmpty)
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _branchId ?? '',
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Branch',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('All branches'),
                        ),
                        for (final b in _branchOptions)
                          DropdownMenuItem(value: b, child: Text(b)),
                      ],
                      onChanged: (v) => setState(() => _branchId = v),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              decoration: const InputDecoration(
                labelText: 'Search employee',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reminderCard() {
    final reminders = _reminders;
    return SectionCard(
      title: 'Clock reminders',
      children: [
        Row(
          children: [
            const Icon(Icons.notifications_active_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                reminders == null
                    ? 'Reminder schedule not available'
                    : 'Reminders ${reminders.enabled ? 'are enabled' : 'are paused'} for '
                          '${reminders.clockInTime} (in) and ${reminders.clockOutTime} (out) · '
                          '${reminders.graceMinutes} min grace',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _reminders == null ? null : _editReminders,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _editReminders() async {
    final current = _reminders;
    if (current == null) return;
    final fromTime = await showTimePicker(
      context: context,
      initialTime: _timeOfDay(current.clockInTime),
      helpText: 'Clock-in reminder time',
    );
    if (fromTime == null || !mounted) return;
    final theTime = await showTimePicker(
      context: context,
      initialTime: _timeOfDay(current.clockOutTime),
      helpText: 'Clock-out reminder time',
    );
    if (theTime == null || !mounted) return;
    final enabled = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable reminders?'),
        content: Text(
          'Clock-in reminder at $fromTime and clock-out reminder at $theTime '
          'on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Disable'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Enable'),
          ),
        ],
      ),
    );
    if (enabled == null || !mounted) return;
    try {
      final updated = await _service.setReminderSettings(
        clockInTime: _two(fromTime),
        clockOutTime: _two(theTime),
        graceMinutes: current.graceMinutes,
        enabled: enabled,
      );
      await ReminderService.instance.sync();
      if (mounted) setState(() => _reminders = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save reminder settings: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  TimeOfDay _timeOfDay(String hhmm) {
    final m = RegExp(r'^([01][0-9]|2[0-3]):([0-5][0-9])$').firstMatch(hhmm);
    if (m == null) return const TimeOfDay(hour: 8, minute: 0);
    return TimeOfDay(hour: int.parse(m[1]!), minute: int.parse(m[2]!));
  }

  String _two(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _rowCard(AttendanceManagementRow r) {
    final isOpen = r.isCurrentlyOpen;
    final statusColor = switch (r.status) {
      'present' || 'on_time' => AppColors.green,
      'late' => AppColors.amber,
      'absent' => AppColors.rose,
      _ => AppColors.blue,
    };

    final details = <String>[
      if (r.clockIn != null)
        'In ${Fmt.clock(r.clockIn)}'
            '${r.clockOut != null ? ' · Out ${Fmt.clock(r.clockOut)}' : ''}',
      if (r.workHours > 0) '${workedHoursFor(r).format()} worked',
      if (r.lateMinutes > 0) '${Fmt.lateDuration(r.lateMinutes)} late',
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AvatarCircle(name: r.employeeName, size: 38),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.employeeName,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [
                          if (r.employeeNumber.isNotEmpty) r.employeeNumber,
                          if (r.department.isNotEmpty) r.department,
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textTertiary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isOpen)
                  const StatusBadge(label: 'Open', color: AppColors.violet)
                else
                  StatusBadge(label: r.status, color: statusColor),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${Fmt.dateShort(r.attendanceDate)}'
              '${r.branchName.isNotEmpty ? ' · ${r.branchName}' : ''}',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
            if (details.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  details.join(' · '),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary(context),
                  ),
                ),
              ),
            if (r.actualLocationName.isNotEmpty ||
                r.locationStatus.isNotEmpty ||
                r.geofenceStatus.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.gps_fixed,
                      size: 13,
                      color: AppColors.iconMuted(context),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        [
                          if (r.actualLocationName.isNotEmpty)
                            r.actualLocationName,
                          if (r.locationStatus.isNotEmpty &&
                              r.locationStatus != 'inside')
                            r.locationStatus,
                          if (r.geofenceStatus.isNotEmpty) r.geofenceStatus,
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textTertiary(context),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Worked-hours for a management row (open sessions fall back to the
/// server-reported value).
WorkedHours workedHoursFor(AttendanceManagementRow r) {
  final end = DateTime.tryParse(r.clockOut ?? '');
  final start = DateTime.tryParse(r.clockIn ?? '');
  final worked = end != null && start != null
      ? end.difference(start).inMinutes / 60.0
      : r.workHours;
  return WorkedHours(worked: worked, overtime: 0, allowed: worked);
}
