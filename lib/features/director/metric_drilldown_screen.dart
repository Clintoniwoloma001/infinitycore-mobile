// ============================================================================
// Executive card drill-down — "who is behind this number?"
//
// Every figure on the director home is a COUNT of people, and a count alone
// cannot be acted on: "34 absent" says nothing about WHICH 34. This screen
// opens the named list behind a tile, so a metric is never a dead end.
//
// It reads from the SAME snapshot the tile was drawn from. That is deliberate:
// a drill-down that re-queried could show a different number to the one the
// executive tapped, which is the fastest way to lose trust in a dashboard.
//
// The classification uses the SAME rule the tile's caption states
// (AttendanceTotals.fromStaff): present means at least one attended day in the
// window, so a partly-attending person is never listed as absent.
// ============================================================================
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import 'attendance_overview_screen.dart';
import 'employee_profile_screen.dart';
import 'leave_overview_screen.dart';
import 'role_performance_screen.dart';

/// Which list a tile opens.
enum MetricDrilldown {
  totalStaff,
  onLeave,
  present,
  absent,
  attendance,
  kpi,
  target,
}

/// The people behind one executive metric.
class MetricDrilldownScreen extends StatelessWidget {
  const MetricDrilldownScreen({
    super.key,
    required this.metric,
    required this.staff,
    required this.periodLabel,
  });

  final MetricDrilldown metric;

  /// The roster rows the tiles were drawn from, passed straight through. Never
  /// re-fetched, so the drill-down cannot show a different figure to the one
  /// the executive tapped.
  final List<Map<String, dynamic>> staff;
  final String periodLabel;

  String get _title => switch (metric) {
    MetricDrilldown.totalStaff => 'Total staff',
    MetricDrilldown.onLeave => 'On leave',
    MetricDrilldown.present => 'Present',
    MetricDrilldown.absent => 'Absent',
    MetricDrilldown.attendance => 'Attendance detail',
    MetricDrilldown.kpi => 'KPI completion',
    MetricDrilldown.target => 'Target completion',
  };

  String get _explainer => switch (metric) {
    MetricDrilldown.present =>
      'Staff with at least one attended day in $periodLabel.',
    MetricDrilldown.absent =>
      'Staff who registered no attendance at all in $periodLabel. '
      'Nobody is listed here for a single missed day.',
    MetricDrilldown.onLeave => 'Staff with leave in $periodLabel.',
    MetricDrilldown.attendance =>
      'Who registered attendance in $periodLabel, with their own rates.',
    _ => 'Everyone in the roster for $periodLabel.',
  };

  /// True when the metric is a whole-board aggregate with no per-person list.
  bool get _isAggregate =>
      metric == MetricDrilldown.attendance ||
      metric == MetricDrilldown.kpi ||
      metric == MetricDrilldown.target;

  List<Map<String, dynamic>> get _staffList => staff;

  /// The SAME predicate AttendanceTotals.fromStaff uses, so the list and the
  /// tile's number can never disagree.
  static bool _attended(Map<String, dynamic> p) =>
      ((p['attendance_present'] as num?)?.toInt() ?? 0) > 0;

  static bool _onLeave(Map<String, dynamic> p) =>
      ((p['on_leave'] as num?)?.toInt() ?? 0) > 0 ||
      ((p['leave_days'] as num?)?.toInt() ?? 0) > 0;

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    final staff = _staffList;
    final people = switch (metric) {
      MetricDrilldown.present => staff.where(_attended).toList(),
      MetricDrilldown.absent => staff.where((p) => !_attended(p)).toList(),
      MetricDrilldown.onLeave => staff.where(_onLeave).toList(),
      _ => staff,
    };

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isAggregate ? '--' : '${people.length}',
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _explainer,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // An aggregate has no per-person list. Rather than an empty screen,
          // send the reader to the screen that does carry the detail.
          if (_isAggregate)
            _GoToTile(
              icon: Icons.insights_outlined,
              label: metric == MetricDrilldown.attendance
                  ? 'Open attendance overview'
                  : 'Open role performance',
              onTap: () => _push(
                context,
                metric == MetricDrilldown.attendance
                    ? const AttendanceOverviewScreen()
                    : const RolePerformanceScreen(),
              ),
            )
          else if (people.isEmpty)
            const PageEmptyView(
              title: 'Nobody to list',
              description:
                  'No one falls into this group for the selected period.',
            )
          else ...[
            for (final p in people) ...[
              _PersonRow(person: p),
              const SizedBox(height: 8),
            ],
            if (metric == MetricDrilldown.onLeave) ...[
              const SizedBox(height: 6),
              _GoToTile(
                icon: Icons.beach_access_outlined,
                label: 'Open leave overview',
                onTap: () => _push(context, const LeaveOverviewScreen()),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// One person in the drill-down, opening their executive profile.
class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person});

  final Map<String, dynamic> person;

  @override
  Widget build(BuildContext context) {
    final name = (person['full_name'] ?? '—').toString();
    final role = (person['position'] ?? '').toString();
    final dept = (person['department'] ?? '').toString();
    final expected = (person['expected_days'] as num?)?.toInt() ?? 0;
    final present = (person['attendance_present'] as num?)?.toInt() ?? 0;
    // Null, not 0, when nothing was expected: no expected days is not a 0%
    // attendance rate, it is no measurement.
    final rate = expected > 0 ? (present / expected) * 100 : null;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EmployeeProfileScreen(
            employeeId: (person['employee_id'] ?? '').toString(),
            fallbackName: name,
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [if (role.isNotEmpty) role, if (dept.isNotEmpty) dept]
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  rate == null ? '—' : '${rate.toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '$present of $expected days',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ],
            ),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: Color(0xFF94A3B8),
            ),
          ],
        ),
      ),
    );
  }
}

/// A "go deeper" affordance used where the detail lives on another screen.
class _GoToTile extends StatelessWidget {
  const _GoToTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: const Color(0xFF009944)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: Color(0xFF94A3B8),
            ),
          ],
        ),
      ),
    );
  }
}