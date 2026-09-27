// Executive employee profile.
//
// Sections are tabs rather than one long scroll, so the screen stays readable
// on a phone. Every figure is server-computed by
// get_director_employee_detail - the same function the web employee detail
// uses - including tenure.
import 'package:flutter/material.dart';

import 'director_service.dart';
import 'director_widgets.dart';
import '../../core/theme/app_theme.dart';

class EmployeeProfileScreen extends StatefulWidget {
  const EmployeeProfileScreen({
    super.key,
    required this.employeeId,
    this.fallbackName,
  });

  final String employeeId;
  final String? fallbackName;

  @override
  State<EmployeeProfileScreen> createState() => _EmployeeProfileScreenState();
}

class _EmployeeProfileScreenState extends State<EmployeeProfileScreen> {
  Map<String, dynamic> _person = const {};
  List<Map<String, dynamic>> _leave = const [];
  List<Map<String, dynamic>> _kpis = const [];
  List<Map<String, dynamic>> _targets = const [];
  bool _loading = true;
  String? _error;

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
      final detail =
          await DirectorService.instance.employeeDetail(widget.employeeId);
      if (!mounted) return;
      setState(() {
        _person = asMap(detail['employee'] ?? detail['person'] ?? detail);
        _leave = asList(detail['leave']);
        _kpis = asList(detail['kpis'] ?? detail['kpi']);
        _targets = asList(detail['targets']);
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
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            text(_person['full_name']) ?? widget.fallbackName ?? 'Employee',
            style: const TextStyle(fontSize: 15),
          ),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Attendance'),
              Tab(text: 'Leave'),
              Tab(text: 'Performance'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  )
                : TabBarView(
                    children: [
                      _OverviewTab(person: _person),
                      _AttendanceTab(person: _person),
                      _LeaveTab(leave: _leave),
                      _PerformanceTab(
                        kpis: _kpis,
                        targets: _targets,
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.person});

  final Map<String, dynamic> person;

  @override
  Widget build(BuildContext context) {
    final tenure = tenureLabel(person);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (tenure != null)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.textPrimary(context),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'IN THE BUSINESS',
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1,
                    color: AppColors.textSecondary(context),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  tenure,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        _Row('Position', text(person['position'])),
        _Row('Department', text(person['department'])),
        _Row('Branch', text(person['branch_name'])),
        _Row('Area', text(person['area'])),
        _Row('Employee ID', text(person['employee_number'])),
        _Row('Joined', text(person['join_date']) ?? text(person['hire_date'])),
        const SizedBox(height: 16),
        MetricStrip(
          tiles: [
            MetricTile(
              label: 'Attendance',
              value: fmtPct(person['attendance_rate']),
            ),
            MetricTile(label: 'KPI', value: fmtPct(person['kpi_completion'])),
            MetricTile(
              label: 'Targets',
              value: fmtPct(person['target_completion']),
            ),
          ],
        ),
      ],
    );
  }
}

class _AttendanceTab extends StatelessWidget {
  const _AttendanceTab({required this.person});

  final Map<String, dynamic> person;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MetricStrip(
          tiles: [
            MetricTile(label: 'Rate', value: fmtPct(person['attendance_rate'])),
            MetricTile(label: 'Present', value: fmtInt(person['present_days'])),
            MetricTile(label: 'Absent', value: fmtInt(person['absent_days'])),
            MetricTile(label: 'Late', value: fmtInt(person['late_days'])),
          ],
        ),
      ],
    );
  }
}

class _LeaveTab extends StatelessWidget {
  const _LeaveTab({required this.leave});

  final List<Map<String, dynamic>> leave;

  @override
  Widget build(BuildContext context) {
    if (leave.isEmpty) {
      return Center(
        child: Text(
          'No leave recorded.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: leave.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final l = leave[i];
        final approved = text(l['status']) == 'approved';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            text(l['leave_type']) ?? 'Leave',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${text(l['start_date']) ?? '--'} to ${text(l['end_date']) ?? '--'}',
            style: const TextStyle(fontSize: 10),
          ),
          trailing: Text(
            (text(l['status']) ?? '--').toUpperCase(),
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: approved ? const Color(0xFF047857) : const Color(0xFFB45309),
            ),
          ),
        );
      },
    );
  }
}

class _PerformanceTab extends StatelessWidget {
  const _PerformanceTab({required this.kpis, required this.targets});

  final List<Map<String, dynamic>> kpis;
  final List<Map<String, dynamic>> targets;

  @override
  Widget build(BuildContext context) {
    if (kpis.isEmpty && targets.isEmpty) {
      return Center(
        child: Text(
          'No KPI or target data recorded.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (targets.isNotEmpty) const SectionHeader(title: 'TARGETS'),
        ...targets.map((t) => _targetCard(context, t)),
        if (kpis.isNotEmpty) const SectionHeader(title: 'KPIs'),
        ...kpis.map(
          (k) => ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              text(k['name']) ?? text(k['title']) ?? 'KPI',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Text(
              fmtPct(k['completion'] ?? k['progress']) ?? '--',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  /// Target / actual / completion / remaining, all read from the server. The
  /// remaining figure appears only when BOTH target and actual were supplied,
  /// so it is never derived from a partial record.
  Widget _targetCard(BuildContext context, Map<String, dynamic> t) {
    final assigned = asDouble(t['target'] ?? t['assigned']);
    final actual = asDouble(t['actual'] ?? t['achieved']);
    final remaining =
        (assigned != null && actual != null) ? assigned - actual : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text(t['name']) ?? text(t['title']) ?? 'Target',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(compactMoney(assigned) ?? '--', style: const TextStyle(fontSize: 11)),
              const Text('  /  ', style: TextStyle(fontSize: 11)),
              Text(
                compactMoney(actual) ?? '--',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                fmtPct(t['completion']) ?? '--',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF009944),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          MetricBar(value: asDouble(t['completion'])),
          if (remaining != null) ...[
            const SizedBox(height: 4),
            Text(
              'Remaining ${compactMoney(remaining)}',
              style: TextStyle(fontSize: 9, color: AppColors.textSecondary(context)),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    if (value == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary(context)),
            ),
          ),
          Expanded(
            child: Text(
              value!,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

