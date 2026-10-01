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
  List<Map<String, dynamic>> _attendance = const [];
  Map<String, dynamic> _summary = const {};
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
      final detail = await DirectorService.instance.employeeDetail(
        widget.employeeId,
      );
      if (!mounted) return;
      setState(() {
        // The server returns the person under 'profile' and now also aliases it
        // as 'employee' and 'person'. Reading the top-level payload as a
        // fallback was what produced a screen full of "--": that object has no
        // full_name, department or rates, so every tile had nothing to show.
        _person = asMap(
          detail['employee'] ?? detail['person'] ?? detail['profile'] ?? {},
        );
        _summary = asMap(detail['summary']);
        _leave = asList(detail['leave']);
        _kpis = asList(detail['kpis'] ?? detail['kpi']);
        _targets = asList(detail['targets']);
        _attendance = asList(detail['attendance']);
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
                  _OverviewTab(person: _person, summary: _summary),
                  _AttendanceTab(attendance: _attendance, summary: _summary),
                  _LeaveTab(leave: _leave),
                  _PerformanceTab(kpis: _kpis, targets: _targets),
                ],
              ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.person, required this.summary});

  final Map<String, dynamic> person;
  final Map<String, dynamic> summary;

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
              // A surface, not ink. This was `AppColors.textPrimary(context)`,
              // which is near-black in light mode and near-white in dark mode,
              // so the panel inverted itself between modes and the white
              // tenure text vanished on the dark one.
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'IN THE BUSINESS',
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1,
                    color: AppColors.textTertiary(context),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  tenure,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary(context),
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
        // Read the rates from the server-computed summary. Before the fix these
        // keys lived in neither object, so all three tiles rendered "--" for
        // somebody the list had just shown as 25%.
        MetricStrip(
          tiles: [
            MetricTile(
              label: 'Attendance',
              value: fmtPct(summary['attendance_rate']),
            ),
            MetricTile(label: 'KPI', value: fmtPct(summary['kpi_completion'])),
            MetricTile(
              label: 'Targets',
              value: fmtPct(summary['target_completion']),
            ),
          ],
        ),
      ],
    );
  }
}

/// Attendance tab: summary cards plus the real log history.
///
/// This tab used to take the person row and read four keys that were never
/// there, so it rendered four placeholders and no list at all. It now renders
/// the `attendance` records the server already returns, filtered by month or
/// quarter, with the rollup recomputed for the selected period so the header
/// can never contradict the list beneath it.
class _AttendanceTab extends StatefulWidget {
  const _AttendanceTab({required this.attendance, required this.summary});

  final List<Map<String, dynamic>> attendance;
  final Map<String, dynamic> summary;

  @override
  State<_AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends State<_AttendanceTab> {
  /// null = the whole window; otherwise a yyyy-mm-01 month or quarter start.
  String? _periodKey;

  /// 'month' | 'quarter' | 'all' — how _periodKey is interpreted.
  String _mode = 'all';

  DateTime? _asDate(dynamic v) => DateTime.tryParse(v?.toString() ?? '');

  String _keyFor(Map<String, dynamic> a) {
    final d = _asDate(a['attendance_date']);
    if (d == null) return '';
    if (_mode == 'month') {
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-01';
    }
    if (_mode == 'quarter') {
      final q = ((d.month - 1) ~/ 3) * 3 + 1;
      return '${d.year}-${q.toString().padLeft(2, '0')}-01';
    }
    return 'all';
  }

  List<Map<String, dynamic>> get _rows {
    final out = widget.attendance
        .where((a) => _keyFor(a) == (_periodKey ?? 'all'))
        .toList();
    // Newest first: the most recent day is the one an executive looks for.
    out.sort(
      (a, b) => (_asDate(b['attendance_date']) ?? DateTime(0)).compareTo(
        _asDate(a['attendance_date']) ?? DateTime(0),
      ),
    );
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final filtered = _periodKey != null;

    final present = rows.where((a) => text(a['clock_in']) != null).length;
    final late = rows.where((a) => (asInt(a['late_minutes']) ?? 0) > 0).length;
    final hours = rows
        .map((a) => asDouble(a['work_hours']) ?? 0)
        .fold<double>(0, (a, b) => a + b);
    final rate = rows.isEmpty ? 0 : (present * 100 / rows.length).round();
    final now = DateTime.now();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Horizontally scrolling Row: a month/quarter label is long enough that
        // a plain Row would overflow on a narrow phone.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _Sel(
                label: 'All',
                selected: _mode == 'all',
                onTap: () => setState(() {
                  _mode = 'all';
                  _periodKey = null;
                }),
              ),
              _Sel(
                label: 'This month',
                selected: _mode == 'month' && _periodKey != null,
                onTap: () => setState(() {
                  _mode = 'month';
                  _periodKey =
                      '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
                }),
              ),
              _Sel(
                label: 'This quarter',
                selected: _mode == 'quarter' && _periodKey != null,
                onTap: () => setState(() {
                  _mode = 'quarter';
                  final q = ((now.month - 1) ~/ 3) * 3 + 1;
                  _periodKey = '${now.year}-${q.toString().padLeft(2, '0')}-01';
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        MetricStrip(
          tiles: [
            MetricTile(label: 'Rate', value: '$rate%'),
            MetricTile(label: 'Present', value: fmtInt(present)),
            MetricTile(label: 'Absent', value: fmtInt(rows.length - present)),
            MetricTile(label: 'Late', value: fmtInt(late)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _Mini(
                label: 'Late ratio',
                value: present == 0 ? '0%' : '${((late * 100) ~/ present)}%',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Mini(
                label: 'Work hours',
                value: hours.toStringAsFixed(1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                filtered
                    ? 'No attendance recorded for this period.'
                    : 'No attendance recorded yet.',
                style: TextStyle(color: AppColors.textSecondary(context)),
              ),
            ),
          )
        else
          for (final a in rows) _AttendanceRow(record: a),
      ],
    );
  }
}

class _Sel extends StatelessWidget {
  const _Sel({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // A surface, never a text-ink helper: an ink colour here inverts
        // between light and dark mode.
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: AppColors.textTertiary(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// One attendance day: clock in, clock out, hours and the recorded location.
class _AttendanceRow extends StatelessWidget {
  const _AttendanceRow({required this.record});

  final Map<String, dynamic> record;

  String _time(dynamic v) {
    final s = text(v);
    if (s == null) return '--';
    final d = DateTime.tryParse(s);
    if (d == null) return s;
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final hours = asDouble(record['work_hours']);
    final late = (asInt(record['late_minutes']) ?? 0) > 0;
    final place =
        text(record['actual_location_name']) ??
        text(record['location_status']) ??
        text(record['verification_method']);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    text(record['attendance_date']) ?? '',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hours != null)
                  Text(
                    '${hours.toStringAsFixed(1)}h',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                if (late)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.schedule, size: 14, color: Colors.orange),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // Wrap, not a Row: a long location name must not overflow.
            Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                Text(
                  'In  ${_time(record['clock_in'])}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary(context),
                  ),
                ),
                Text(
                  'Out  ${_time(record['clock_out'])}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary(context),
                  ),
                ),
                if (place != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: Text(
                      'Where  $place',
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
        ),
      ),
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
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary(context),
          ),
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
              color: approved
                  ? const Color(0xFF047857)
                  : const Color(0xFFB45309),
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
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary(context),
          ),
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
    final remaining = (assigned != null && actual != null)
        ? assigned - actual
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
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
            text(t['name']) ?? text(t['title']) ?? 'Target',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                compactMoney(assigned) ?? '--',
                style: const TextStyle(fontSize: 11),
              ),
              const Text('  /  ', style: TextStyle(fontSize: 11)),
              Text(
                compactMoney(actual) ?? '--',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
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
              style: TextStyle(
                fontSize: 9,
                color: AppColors.textSecondary(context),
              ),
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
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary(context),
              ),
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
