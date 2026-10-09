import 'package:flutter/material.dart';

import 'dart:async';
import '../../core/services/location_heartbeat.dart';

import '../../core/services/auth_service.dart';
import '../../core/security/role_guard.dart';
import '../../core/services/mobile_session_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/attendance_history_card.dart';
import '../../shared/widgets/common.dart';
import 'dashboard_service.dart';

/// Calendar-month selection shared by the staff dashboard's metric cards and
/// its month chips.
///
/// Public and free of Flutter imports so the month maths can be unit-tested
/// directly instead of only through a widget test.
///
/// The bug this exists to prevent: `_effectiveMonth` used to be written as
/// `DateTime(now.year, month?.year ?? now.year, month?.month ?? now.month)`,
/// passing the *year* into `DateTime`'s **month** slot. Dart normalises the
/// overflow instead of throwing, so selecting September 2026 produced
/// 2194-10-09. `DashboardMetrics.fromRecords` then matched no records at all
/// and every card read 0 - which looked like "the data is missing" rather than
/// "the filter is broken". Year and month must therefore always come from the
/// same source.
class DashboardMonthFilter {
  const DashboardMonthFilter._();

  /// The month being reported on; [selected] null means the current month.
  ///
  /// Only the year and month are meaningful; the day is normalised to the 1st.
  static DateTime resolve(DateTime now, DateTime? selected) => DateTime(
    selected?.year ?? now.year,
    selected?.month ?? now.month,
  );

  /// The current month plus the previous [depth] months, newest first.
  ///
  /// Matches the rolling attendance window, so offering older months would show
  /// an empty card for no reason. Negative month offsets roll over the year
  /// boundary natively (`DateTime(2026, 0)` is December 2025).
  static List<DateTime> options(DateTime now, {int depth = 5}) => [
    for (var i = 0; i < depth; i++) DateTime(now.year, now.month - i, 1),
  ];

  /// True when [month] is the month [now] falls in.
  static bool isCurrentMonth(DateTime now, DateTime month) =>
      now.year == month.year && now.month == month.month;
}

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

  /// Which calendar month the metric cards are reporting on.
  ///
  /// Null means "this month". Held as a full [DateTime] (day component ignored)
  /// so the selector can step backwards without carrying year/month arithmetic
  /// through the widget tree.
  DateTime? _month;

  /// The four metric cards and the history below them describe exactly this
  /// month, so the label on the filter is what tells the reader whether "Days
  /// present" means this month or the one they just selected.
  /// The month the four cards are currently reporting on.
  ///
  /// Delegates to [DashboardMonthFilter.resolve] so the selector and the
  /// metrics can never disagree about which month is selected.
  DateTime get _effectiveMonth =>
      DashboardMonthFilter.resolve(DateTime.now(), _month);

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
            _TrackingStatusCard(snapshot: snapshot),
            const SizedBox(height: 12),
            _TodayCard(snapshot: snapshot, onGoToTab: widget.onGoToTab),
            const SizedBox(height: 12),
            // The month the four cards below are reporting on. Placed directly
            // above them so the reader never sees a figure without knowing
            // which month it belongs to.
            _MonthFilter(
              months: DashboardMonthFilter.options(DateTime.now()),
              selected: _effectiveMonth,
              onChanged: (m) => setState(() => _month = m),
            ),
            const SizedBox(height: 12),
            _MetricsGrid(
              metrics: DashboardMetrics.fromRecords(
                snapshot.recentAttendance,
                month: _effectiveMonth,
              ),
              month: _effectiveMonth,
            ),
            if (widget.onGoToManagement != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: widget.onGoToManagement,
                icon: const Icon(Icons.groups_outlined),
                label: const Text('Manage team attendance'),
              ),
            ],
            const SizedBox(height: 12),
            // The Messages card that used to live here was removed when
            // messaging moved onto the bottom navigation bar: it duplicated a
            // destination the user is already one tap from and pushed the
            // attendance history below the fold.
            AttendanceHistoryCard(records: snapshot.recentAttendance),
          ],
          const SizedBox(height: 12),
          _SecurityCard(snapshot: snapshot),
        ],
      ),
    );
  }
}

/// Small status line: how many locations are waiting to upload, and when the
/// last one was recorded. Drives the honest "is this device actually
/// reporting" signal without claiming a live position that does not exist.
class _TrackingStatusCard extends StatefulWidget {
  const _TrackingStatusCard({required this.snapshot});

  final dynamic snapshot;

  @override
  State<_TrackingStatusCard> createState() => _TrackingStatusCardState();
}

class _TrackingStatusCardState extends State<_TrackingStatusCard> {
  int _pending = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // Every heartbeat emission (capture, 4-minute auto-drain, GPS-miss)
    // repaints the card the moment it happens — no 30 s poll needed.
    LocationHeartbeat.instance.status.addListener(_onStatus);
  }

  @override
  void dispose() {
    LocationHeartbeat.instance.status.removeListener(_onStatus);
    super.dispose();
  }

  void _onStatus() {
    if (!mounted) return;
    // The emission already carries the fresh queue count — prefer it over a
    // second async read so the card can never disagree with the heartbeat.
    setState(() {
      _pending = LocationHeartbeat.instance.status.value.pending;
    });
  }

  Future<void> _refresh() async {
    final pending = await LocationHeartbeat.instance.pendingCount();
    if (mounted) setState(() => _pending = pending);
  }

  @override
  Widget build(BuildContext context) {
    final status = LocationHeartbeat.instance.status.value;
    final fresh = status.hasFreshFix;
    final tone = fresh ? Colors.green : Colors.amber;
    return Card(
      elevation: 0,
      shape: const StadiumBorder(),
      child: ListTile(
        leading: Icon(fresh ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
            color: tone),
        title: Text(
          _pending > 0
              ? '$_pending location${_pending == 1 ? '' : 's'} waiting to upload'
              : 'All locations uploaded',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        subtitle: Text(
          status.note ?? status.summary,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        // Auto-sync is always on: LocationHeartbeat drains the offline queue
        // every 4 minutes with no user tap, so this card never needs a manual
        // sync trigger any more. [pending] is the single source of truth.
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

/// Horizontal month picker for the staff dashboard.
///
/// The four metric cards are calendar-month figures, so without this a reader
/// could not tell whether "Late days" meant today, this month, or the month
/// before last. Only months that can actually have data are offered - the list
/// comes from the caller, which bounds it to the fetched attendance window.
class _MonthFilter extends StatelessWidget {
  const _MonthFilter({
    required this.months,
    required this.selected,
    required this.onChanged,
  });

  /// Offerable months, newest first.
  final List<DateTime> months;

  /// The month currently being reported on.
  final DateTime selected;

  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    if (months.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: months.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final m = months[i];
          final isSelected = m.year == selected.year && m.month == selected.month;
          final isCurrent =
              DashboardMonthFilter.isCurrentMonth(DateTime.now(), m);
          final label = isCurrent
              ? 'This month'
              : Fmt.monthYear(m);

          return ChoiceChip(
            label: Text(label),
            selected: isSelected,
            onSelected: (_) => onChanged(m),
            visualDensity: VisualDensity.compact,
            labelStyle: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              color: isSelected
                  ? AppColors.accent(context)
                  : AppColors.textSecondary(context),
            ),
          );
        },
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.metrics, required this.month});

  final DashboardMetrics metrics;

  /// The calendar month these figures describe. Named on the cards so a figure
  /// is never read as "this month" when a past month is selected.
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final monthLabel = Fmt.monthYear(month);
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.1,
      children: [
        StatCard(
          label: 'Days present · $monthLabel',
          value: '${metrics.daysPresent}',
          icon: Icons.event_available,
        ),
        StatCard(
          label: 'Hours · $monthLabel',
          value: '${metrics.totalHours.toStringAsFixed(1)}h',
          icon: Icons.timelapse,
        ),
        StatCard(
          label: 'Late days · $monthLabel',
          value: '${metrics.lateDays}',
          icon: Icons.warning_amber_rounded,
          accent: AppColors.amber,
          detail: metrics.onTimeRate == 0 && metrics.daysPresent == 0
              ? null
              : '${metrics.onTimeRate.toStringAsFixed(0)}% on time',
        ),
        StatCard(
          label: 'On-time rate · $monthLabel',
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
