// Director Home: a compact executive snapshot.
//
// Progressive disclosure: SUMMARY (this screen) -> DEPARTMENT -> PERSON. Every
// figure is read from get_director_executive_snapshot, the same RPC the web
// dashboard uses, so the two never disagree.
import 'package:flutter/material.dart';

import 'director_service.dart';
import 'director_widgets.dart';
import 'department_detail_screen.dart';
import 'leave_overview_screen.dart';
import 'role_performance_screen.dart';
import 'attendance_overview_screen.dart';
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

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _PeriodSelector(
            period: _period,
            onChanged: (p) {
              setState(() => _period = p);
              _load();
            },
          ),
          const SizedBox(height: 12),
          MetricStrip(
            tiles: [
              MetricTile(
                label: 'Total staff',
                value: fmtInt(s.summary['total_staff']),
                icon: Icons.groups_outlined,
              ),
              MetricTile(
                label: 'On leave',
                value: fmtInt(s.summary['on_leave']),
                icon: Icons.beach_access_outlined,
              ),
              MetricTile(
                label: 'Absent',
                value: fmtInt(s.summary['absent']),
                icon: Icons.person_off_outlined,
              ),
              MetricTile(
                label: 'Attendance',
                value: fmtPct(s.summary['attendance_rate']),
                icon: Icons.schedule_outlined,
              ),
              MetricTile(
                label: 'KPI completion',
                value: fmtPct(s.summary['kpi_completion']),
                icon: Icons.flag_outlined,
              ),
              MetricTile(
                label: 'Target completion',
                value: fmtPct(s.summary['target_completion']),
                icon: Icons.track_changes_outlined,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _BusinessStrip(loans: s.loans, branches: s.branches, areas: s.areas),
          const SizedBox(height: 16),
          const SectionHeader(title: 'DEPARTMENTS'),
          _DepartmentCarousel(
            departments: s.departments,
            onOpen: (d) => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DepartmentDetailScreen(
                  department:
                      text(d['name']) ?? text(d['department']) ?? 'Department',
                  raw: d,
                ),
              ),
            ),
          ),
          const SectionHeader(title: 'PEOPLE'),
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
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.period, required this.onChanged});

  final DirectorPeriod period;
  final ValueChanged<DirectorPeriod> onChanged;

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
        children: choices
            .map(
              (p) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(p.label, style: const TextStyle(fontSize: 11)),
                  selected: period.label == p.label,
                  onSelected: (_) => onChanged(p),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            )
            .toList(),
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
