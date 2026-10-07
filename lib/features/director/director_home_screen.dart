// Director Home: a compact executive snapshot.
//
// Progressive disclosure: SUMMARY (this screen) -> DEPARTMENT -> PERSON. Every
// figure is read from get_director_executive_snapshot, the same RPC the web
// dashboard uses, so the two never disagree.
import 'package:flutter/material.dart';

import 'director_service.dart';
import 'director_widgets.dart';
import 'people_directory_screen.dart';
import 'department_detail_screen.dart';
import 'leave_overview_screen.dart';
import 'role_performance_screen.dart';
import 'attendance_overview_screen.dart';
import 'metric_drilldown_screen.dart';
import '../../core/theme/app_theme.dart';

class DirectorHomeScreen extends StatefulWidget {
  const DirectorHomeScreen({super.key, this.onOpenProfile});

  /// Opens the executive employee profile. Wired by the shell so this screen
  /// stays independent of routing.
  final void Function(Map<String, dynamic> person)? onOpenProfile;

  @override
  State<DirectorHomeScreen> createState() => _DirectorHomeScreenState();
}

class _DirectorHomeScreenState extends State<DirectorHomeScreen> {
  DirectorSnapshot? _snapshot;
  bool _loading = true;
  String? _error;
  DirectorPeriod _period = DirectorPeriod.thisMonth();

  /// Bounds for the custom date-range picker. Kept only for the currently
  /// selected Custom window so the picker can be re-opened without losing the
  /// user's chosen dates.
  DateTime? _customFrom;
  DateTime? _customTo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _openCustomRange() async {
    final now = DateTime.now();
    final lower = DateTime(now.year, now.month, now.day);
    // Custom-mode bounds: an inclusive start on/ after the start of the
    // current day, and an end on/ before 365 days out — the RPC rejects a
    // future end date, so we keep the picker inside a valid window.
    final lastDate = lower.add(const Duration(days: 365));
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _customFrom != null && _customTo != null
          ? DateTimeRange(start: _customFrom!, end: _customTo!)
          : DateTimeRange(start: lower, end: lastDate),
      firstDate: lower,
      lastDate: lastDate,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppColors.blue,
                  onPrimary: AppColors.white,
                  surface: AppColors.surface(context),
                  onSurface: AppColors.textPrimary(context),
                ),
          ),
          child: child!,
        );
      },
      helpText: 'Tap a start date and an end date.',
      cancelText: 'Cancel',
      confirmText: 'Apply',
      errorFormatText: 'Enter a valid date range.',
      fieldStartLabelText: 'From',
      fieldEndLabelText: 'To',
    );
    if (picked == null || !mounted) return;
    final range = DirectorPeriod.custom(picked.start, picked.end);
    setState(() {
      _period = range;
      _customFrom = picked.start;
      _customTo = picked.end;
    });
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await DirectorService.instance.snapshot(
        from: _period.from,
        to: _period.to,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snap;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _load);
    }
    final s = _snapshot;
    if (s == null) return const SizedBox.shrink();

    // Headcounts for the selected period. Computed once here so the Present and
    // Absent tiles below cannot drift apart from each other.
    final attendance = AttendanceTotals.fromStaff(s.staff);
    final presentStaff = fmtInt(attendance.presentStaff);
    final absentStaff = fmtInt(attendance.absentStaff);
    final periodLabel = _period.label.toLowerCase();

    // SafeArea: the period pills sit at the very top of this list with no app
    // bar above them, so without this they were drawn underneath the status
    // bar / notch on a notched device. `top` only — the bottom inset is already
    // handled by the shell's NavigationBar, and adding it here would double the
    // gap.
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _PeriodSelector(
              period: _period,
              onChanged: (p) {
                setState(() => _period = p);
                _load();
              },
              onCustomSelected: _openCustomRange,
            ),
            const SizedBox(height: 12),
            // "Absent" and "Present" are STAFF headcounts for the selected
            // period, not attendance-DAY totals. The server's `summary.absent`
            // is `expected_days - attendance_present` with a flat 20
            // expected_days per employee, which rendered as "Absent 4220"
            // (= 211 staff x 20 days) and read as "4220 people are absent".
            // AttendanceTotals derives the person counts from the same staff
            // rows the web shows, and can never exceed the roster size.
            // See [AttendanceTotals] for the full rationale.
            MetricStrip(
              tiles: [
                MetricTile(
                  label: 'Total staff',
                  value: fmtInt(s.summary['total_staff']),
                  icon: Icons.groups_outlined,
                  onTap: () => _openDrilldown(
                    context,
                    MetricDrilldown.totalStaff,
                    s,
                  ),
                ),
                MetricTile(
                  label: 'On leave',
                  value: fmtInt(s.summary['on_leave']),
                  icon: Icons.beach_access_outlined,
                  onTap: () => _openDrilldown(
                    context,
                    MetricDrilldown.onLeave,
                    s,
                  ),
                ),
                MetricTile(
                  label: 'Present',
                  value: presentStaff,
                  icon: Icons.person_outline,
                  // Names the basis and the window, so a headcount is never
                  // misread as a day count.
                  caption: 'staff · $periodLabel',
                  onTap: () => _openDrilldown(
                    context,
                    MetricDrilldown.present,
                    s,
                  ),
                ),
                MetricTile(
                  label: 'Absent',
                  value: absentStaff,
                  icon: Icons.person_off_outlined,
                  caption: 'staff · $periodLabel',
                  onTap: () => _openDrilldown(
                    context,
                    MetricDrilldown.absent,
                    s,
                  ),
                ),
                MetricTile(
                  label: 'Attendance',
                  value: fmtPct(s.summary['attendance_rate']),
                  icon: Icons.schedule_outlined,
                  onTap: () => _openDrilldown(
                    context,
                    MetricDrilldown.attendance,
                    s,
                  ),
                ),
                MetricTile(
                  label: 'KPI completion',
                  value: fmtPct(s.summary['kpi_completion']),
                  icon: Icons.flag_outlined,
                  onTap: () => _openDrilldown(
                    context,
                    MetricDrilldown.kpi,
                    s,
                  ),
                ),
                MetricTile(
                  label: 'Target completion',
                  value: fmtPct(s.summary['target_completion']),
                  icon: Icons.track_changes_outlined,
                  onTap: () => _openDrilldown(
                    context,
                    MetricDrilldown.target,
                    s,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _BusinessStrip(
              loans: s.loans,
              branches: s.branches,
              areas: s.areas,
            ),
            const SizedBox(height: 16),
            const SectionHeader(title: 'DEPARTMENTS'),
            _DepartmentCarousel(
              departments: s.departments,
              onOpen: (d) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DepartmentDetailScreen(
                    department:
                        text(d['name']) ??
                        text(d['department']) ??
                        'Department',
                    raw: d,
                  ),
                ),
              ),
            ),
            SectionHeader(
              title: 'PEOPLE',
              trailing: TextButton(
                onPressed: () => showPeopleDirectory(
                  context,
                  staff: s.staff,
                  onOpen: widget.onOpenProfile,
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('See all'),
              ),
            ),
            _LeaderList(
              staff: s.staff,
              onOpen: (p) => widget.onOpenProfile?.call(p),
            ),
            const SizedBox(height: 16),
            _DrillRow(
              onLeave: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const LeaveOverviewScreen(),
                ),
              ),
              onRoles: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const RolePerformanceScreen(),
                ),
              ),
              onAttendance: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AttendanceOverviewScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the people behind one metric tile.
  ///
  /// The roster rows are passed straight through rather than re-fetched, so the
  /// drill-down always shows the SAME period and numbers the executive tapped.
  /// Re-querying here is how a dashboard ends up contradicting itself.
  void _openDrilldown(
    BuildContext context,
    MetricDrilldown metric,
    DirectorSnapshot snapshot,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetricDrilldownScreen(
          metric: metric,
          staff: snapshot.staff,
          periodLabel: _period.label.toLowerCase(),
        ),
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({
    required this.period,
    required this.onChanged,
    this.onCustomSelected,
  });

  final DirectorPeriod period;
  final ValueChanged<DirectorPeriod> onChanged;
  final VoidCallback? onCustomSelected;

  @override
  Widget build(BuildContext context) {
    final choices = <DirectorPeriod>[
      DirectorPeriod.today(),
      DirectorPeriod.thisWeek(),
      DirectorPeriod.thisMonth(),
      DirectorPeriod.thisQuarter(),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ...choices.map(
            (p) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(p.label, style: const TextStyle(fontSize: 11)),
                selected: period.label == p.label,
                onSelected: (_) => onChanged(p),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: const Text('Custom', style: TextStyle(fontSize: 11)),
              selected: period.label == 'Custom',
              onSelected: (_) => onCustomSelected?.call(),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

class _BusinessStrip extends StatelessWidget {
  const _BusinessStrip({
    required this.loans,
    required this.branches,
    required this.areas,
  });

  final Map<String, dynamic> loans;
  final List<Map<String, dynamic>> branches;
  final List<Map<String, dynamic>> areas;

  @override
  Widget build(BuildContext context) {
    return MetricStrip(
      tiles: [
        MetricTile(
          label: 'Loan portfolio',
          value: compactMoney(loans['portfolio_value'] ?? loans['outstanding']),
          icon: Icons.account_balance_outlined,
        ),
        MetricTile(
          label: 'Disbursed',
          value: compactMoney(loans['disbursed'] ?? loans['disbursed_value']),
          icon: Icons.payments_outlined,
        ),
        MetricTile(
          label: 'Branches',
          value: branches.isEmpty ? null : '${branches.length}',
          icon: Icons.storefront_outlined,
        ),
        MetricTile(
          label: 'Areas',
          value: areas.isEmpty ? null : '${areas.length}',
          icon: Icons.map_outlined,
        ),
      ],
    );
  }
}

class _DepartmentCarousel extends StatelessWidget {
  const _DepartmentCarousel({required this.departments, required this.onOpen});

  final List<Map<String, dynamic>> departments;
  final void Function(Map<String, dynamic>) onOpen;

  @override
  Widget build(BuildContext context) {
    if (departments.isEmpty) {
      return Text(
        'No departments reported for this period.',
        style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
      );
    }
    return SizedBox(
      height: 116,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: departments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final d = departments[i];
          return InkWell(
            onTap: () => onOpen(d),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 168,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text(d['name']) ?? text(d['department']) ?? 'Unnamed',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${fmtInt(d['staff_count']) ?? '--'} staff',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                  const Spacer(),
                  _MiniStat(
                    label: 'KPI',
                    value: fmtPct(d['kpi_completion']),
                    bar: asDouble(d['kpi_completion']),
                  ),
                  const SizedBox(height: 4),
                  _MiniStat(
                    label: 'ATT',
                    value: fmtPct(d['attendance_rate']),
                    bar: asDouble(d['attendance_rate']),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, this.bar});

  final String label;
  final String? value;
  final double? bar;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 30,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 9,
              color: AppColors.textSecondary(context),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value ?? "--",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary(context),
            ),
          ),
        ),
        Expanded(child: MetricBar(value: bar)),
      ],
    );
  }
}

class _LeaderList extends StatelessWidget {
  const _LeaderList({required this.staff, required this.onOpen});

  final List<Map<String, dynamic>> staff;
  final void Function(Map<String, dynamic>) onOpen;

  @override
  Widget build(BuildContext context) {
    if (staff.isEmpty) {
      return Text(
        'No staff reported for this period.',
        style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
      );
    }
    // The server already ordered these; only the leaders are shown rather than
    // dumping the whole company onto a phone screen.
    return Column(
      children: staff
          .take(5)
          .map(
            (p) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                text(p['full_name']) ?? 'Unnamed',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                [
                  text(p['position']),
                  text(p['branch_name']),
                ].whereType<String>().join(' · '),
                style: const TextStyle(fontSize: 10),
              ),
              trailing: Text(
                fmtPct(p['kpi_completion']) ?? '--',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF009944),
                ),
              ),
              onTap: () => onOpen(p),
            ),
          )
          .toList(),
    );
  }
}

class _DrillRow extends StatelessWidget {
  const _DrillRow({
    required this.onLeave,
    required this.onRoles,
    required this.onAttendance,
  });

  final VoidCallback onLeave;
  final VoidCallback onRoles;
  final VoidCallback onAttendance;

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData icon, String label, VoidCallback onTap) => Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Column(
            children: [
              Icon(icon, size: 18, color: const Color(0xFF009944)),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Row(
      children: [
        tile(Icons.beach_access_outlined, 'Leave', onLeave),
        const SizedBox(width: 8),
        tile(Icons.track_changes_outlined, 'Targets', onRoles),
        const SizedBox(width: 8),
        tile(Icons.schedule_outlined, 'Attendance', onAttendance),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32, color: Color(0xFFB45309)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textTertiary(context),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
