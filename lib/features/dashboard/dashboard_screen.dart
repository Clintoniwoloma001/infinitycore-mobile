import 'package:flutter/material.dart';

import '../../core/services/auth_service.dart';
import '../../core/security/role_guard.dart';
import '../../core/services/mobile_session_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/attendance_history_card.dart';
import '../../shared/widgets/common.dart';
import 'dashboard_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.onGoToTab, this.onGoToManagement});

  final void Function(String tab)? onGoToTab;
  final VoidCallback? onGoToManagement;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DashboardSnapshot? _snapshot;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    MobileSessionService.instance.addListener(_onSession);
    _load();
  }

  @override
  void dispose() {
    MobileSessionService.instance.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (mounted) _load(silent: true);
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final snapshot = await DashboardService.instance.getSnapshot();
      if (mounted) setState(() => _snapshot = snapshot);
    } catch (e) {
      if (!silent && mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _snapshot == null) {
      return const PageLoadingView(label: 'Loading your dashboard…');
    }
    if (_error != null && _snapshot == null) {
      return PageErrorView(message: _error!, onRetry: _load);
    }
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const PageEmptyView(
        title: 'Dashboard unavailable',
        description: 'There is no dashboard context for this account yet.',
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        padding: const EdgeInsets.all(16),
        children: [
          _Greeting(snapshot: snapshot, onGoToTab: widget.onGoToTab),
          const SizedBox(height: 12),
          if (snapshot.employee == null)
            const _NoEmployeeCard()
          else ...[
            _EmployeeCard(
              employee: snapshot.employee!,
              photoUrl: snapshot.photoUrl,
            ),
            const SizedBox(height: 12),
            _TodayCard(snapshot: snapshot, onGoToTab: widget.onGoToTab),
            const SizedBox(height: 12),
            _MetricsGrid(metrics: snapshot.metrics),
            if (widget.onGoToManagement != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: widget.onGoToManagement,
                icon: const Icon(Icons.groups_outlined),
                label: const Text('Manage team attendance'),
              ),
            ],
            const SizedBox(height: 12),
            AttendanceHistoryCard(records: snapshot.recentAttendance),
          ],
          const SizedBox(height: 12),
          _SecurityCard(snapshot: snapshot),
        ],
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.snapshot, this.onGoToTab});

  final DashboardSnapshot snapshot;
  final void Function(String tab)? onGoToTab;

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final hour = DateTime.now().hour;
    final period = hour < 12
        ? 'Good morning'
        : hour < 17
        ? 'Good afternoon'
        : 'Good evening';
    final name = snapshot.employee?.fullName ?? auth.displayName;
    final firstName = name.trim().split(RegExp(r'\s+')).first;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$period, $firstName',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary(context),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                AppRoles.label(auth.profile?.role ?? ''),
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary(context),
                ),
              ),
              if (snapshot.employee == null && onGoToTab != null)
                TextButton(
                  onPressed: () => onGoToTab?.call('attendance'),
                  child: const Text('Link your employee record'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NoEmployeeCard extends StatelessWidget {
  const _NoEmployeeCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No employee record is linked to this account yet. Contact HR to '
          'link your profile before clocking in.',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary(context),
          ),
        ),
      ),
    );
  }
}

class _EmployeeCard extends StatelessWidget {
  const _EmployeeCard({required this.employee, this.photoUrl});

  final EmployeeRef employee;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AvatarCircle(
                  name: employee.fullName,
                  size: 46,
                  photoUrl: photoUrl,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        employee.fullName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${employee.position.isEmpty ? 'Designation not recorded' : employee.position}'
                        ' · ${employee.department.isEmpty ? 'Department not recorded' : employee.department}',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary(context),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                StatusBadge(label: employee.employmentStatus),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: InfoRow(
                    label: 'Employee ID',
                    value: employee.displayId,
                  ),
                ),
                Expanded(
                  child: InfoRow(
                    label: 'Branch',
                    value: employee.branchName.isNotEmpty
                        ? employee.branchName
                        : (employee.branch.isEmpty ? '—' : employee.branch),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: InfoRow(
                    label: 'Manager',
                    value: employee.managerName.isEmpty
                        ? '—'
                        : employee.managerName,
                  ),
                ),
                Expanded(
                  child: InfoRow(
                    label: 'Joined',
                    value: employee.joinedYear == null
                        ? '—'
                        : '${employee.joinedYear}',
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

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.snapshot, this.onGoToTab});

  final DashboardSnapshot snapshot;
  final void Function(String tab)? onGoToTab;

  @override
  Widget build(BuildContext context) {
    final today = snapshot.today;
    final clockedIn = snapshot.clockedIn;
    final accent = clockedIn ? AppColors.green : AppColors.amber;
    final lateMinutes = today?.lateMinutes ?? 0;

    final locationLines = <String>[];
    if (today != null) {
      if (today.actualLocationName.isNotEmpty) {
        locationLines.add('Location: ${today.actualLocationName}');
      }
      if (today.geofenceStatus.isNotEmpty) {
        locationLines.add('Geofence: ${Fmt.titleCase(today.geofenceStatus)}');
      }
      if (today.locationStatus.isNotEmpty) {
        locationLines.add(
          today.locationStatus == 'inside'
              ? 'Position: Inside approved area'
              : 'Position: ${Fmt.titleCase(today.locationStatus)}',
        );
      }
      if (today.clockInDistance != null) {
        locationLines.add(
          'Distance: ${today.clockInDistance!.toStringAsFixed(0)} m',
        );
      }
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.schedule, size: 20, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        snapshot.todayLabel,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary(context),
                        ),
                      ),
                      Text(
                        today?.clockIn == null
                            ? 'Your attendance for today'
                            : 'In at ${Fmt.clock(today!.clockIn)}'
                                  '${today.clockOut != null ? ' · Out at ${Fmt.clock(today.clockOut)}' : ''}'
                                  '${lateMinutes > 0 ? ' · ${Fmt.lateDuration(lateMinutes)} late' : ''}',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                StatusBadge(
                  label: clockedIn ? 'Clocked in' : 'Not clocked in',
                  color: accent,
                ),
              ],
            ),
            if (locationLines.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final l in locationLines)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.gps_fixed,
                        size: 14,
                        color: AppColors.iconMuted(context),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          l,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (onGoToTab != null) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () => onGoToTab?.call('attendance'),
                icon: Icon(clockedIn ? Icons.logout : Icons.login),
                label: Text(
                  clockedIn
                      ? 'Go to Attendance to clock out'
                      : 'Go to Attendance to clock in',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: clockedIn ? AppColors.rose : AppColors.green,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.metrics});

  final DashboardMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.1,
      children: [
        StatCard(
          label: 'Days present',
          value: '${metrics.daysPresent}',
          icon: Icons.event_available,
        ),
        StatCard(
          label: 'Hours this month',
          value: '${metrics.totalHours.toStringAsFixed(1)}h',
          icon: Icons.timelapse,
        ),
        StatCard(
          label: 'Late days',
          value: '${metrics.lateDays}',
          icon: Icons.warning_amber_rounded,
          accent: AppColors.amber,
          detail: metrics.onTimeRate == 0 && metrics.daysPresent == 0
              ? null
              : '${metrics.onTimeRate.toStringAsFixed(0)}% on time',
        ),
        StatCard(
          label: 'On-time rate',
          value: metrics.daysPresent == 0
              ? '—'
              : '${metrics.onTimeRate.toStringAsFixed(0)}%',
          icon: Icons.check_circle,
        ),
      ],
    );
  }
}

class _SecurityCard extends StatelessWidget {
  const _SecurityCard({required this.snapshot});

  final DashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final session = MobileSessionService.instance;
    final device = snapshot.device;
    final sessionLabel = switch (session.enforced) {
      true => 'Device session active',
      false => 'Server session management unavailable',
      null => 'Checking mobile session…',
    };

    return SectionCard(
      title: 'Security & session',
      children: [
        _row(
          context,
          Icons.phone_android,
          'Device',
          '${device['deviceName']}'
              '${device['platform']?.isNotEmpty == true ? ' (${device['platform']})' : ''}'
              '${device['appVersion']?.isNotEmpty == true ? ' · v${device['appVersion']}' : ''}',
        ),
        _row(context, Icons.shield_outlined, 'Mobile session', sessionLabel),
        if (session.sessionId != null)
          _row(
            context,
            Icons.key_outlined,
            'Session',
            session.sessionId!.substring(0, 8),
            monospace: true,
          ),
        _row(
          context,
          snapshot.biometricEnabled ? Icons.face_outlined : Icons.lock_outline,
          'Quick unlock',
          snapshot.biometricEnabled ? 'Biometrics enabled' : 'Biometrics off',
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String label,
    String value, {
    bool monospace = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.textTertiary(context)),
          const SizedBox(width: 10),
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: monospace ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
