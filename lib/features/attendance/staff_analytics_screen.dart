import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import 'attendance_service.dart';
import 'staff_analytics.dart';

/// HR / management staff attendance analytics.
///
/// Answers, for HR OFFICER, HEAD OF HR, SUPER ADMIN and the other roles the
/// server authorises:
///   * pick any single employee and read their full scorecard for a period,
///   * compare two or three employees side by side,
///   * see the top 5 performers overall, by branch, by role and by department,
///   * see the single best employee across the whole board.
///
/// Every figure is derived from the server-authoritative
/// `mobile_attendance_summary` rows for the selected window, so mobile and web
/// cannot disagree. The role gate here is a UI convenience only; the RPC remains
/// the real security boundary.
class StaffAnalyticsScreen extends StatefulWidget {
  const StaffAnalyticsScreen({super.key});

  @override
  State<StaffAnalyticsScreen> createState() => _StaffAnalyticsScreenState();
}

class _StaffAnalyticsScreenState extends State<StaffAnalyticsScreen> {
  final _service = AttendanceService.instance;

  AnalyticsPeriodType _periodType = AnalyticsPeriodType.month;
  DateTime _anchor = DateTime.now();
  DateTime? _customFrom;
  DateTime? _customTo;

  List<AttendanceManagementRow> _rows = const [];
  StaffAnalyticsReport _report = StaffAnalyticsReport(
    period: AnalyticsPeriod.of(
      AnalyticsPeriodType.month,
      DateTime.now(),
    ),
  );

  bool _loading = true;
  String? _error;
  String _query = '';
  String _dimension = LeaderboardDimension.branch.label;
  StaffComparison _comparison = const StaffComparison(employees: []);

  AnalyticsPeriod get _period => AnalyticsPeriod.of(
    _periodType,
    _anchor,
    customStart: _customFrom,
    customEnd: _customTo,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final period = _period;
    try {
      final rows = await _service.managementSummary(
        from: period.start,
        to: period.end,
      );
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _report = StaffAnalyticsReport.fromRows(rows, period);
        // Employees selected before a period change may have no rows in the new
        // window. Re-resolving keeps the comparison honest instead of showing
        // stale figures under a fresh date range.
        final stillPresent = <StaffAttendanceMetrics>[
          for (final m in _comparison.employees) ?_report.byId(m.employeeId),
        ];
        _comparison = StaffComparison(employees: stillPresent);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Employees matching the typed query, best score first.
  List<StaffAttendanceMetrics> get _matches {
    final q = _query.trim().toLowerCase();
    final people = _report.all;
    if (q.isEmpty) return people;
    return people.where((m) {
      return m.employeeName.toLowerCase().contains(q) ||
          m.employeeNumber.toLowerCase().contains(q) ||
          m.department.toLowerCase().contains(q) ||
          m.position.toLowerCase().contains(q) ||
          m.branchName.toLowerCase().contains(q);
    }).toList();
  }

  bool _isSelected(StaffAttendanceMetrics m) =>
      _comparison.employees.any((e) => e.employeeId == m.employeeId);

  @override
  Widget build(BuildContext context) {
    final role = AuthService.instance.profile?.role ?? '';
    if (!canManageAttendance(role)) {
      return const PageEmptyView(
        title: 'Not available for your role',
        description: 'Staff analytics are limited to HR and management roles.',
      );
    }
    if (_loading && _rows.isEmpty && _error == null) {
      return const PageLoadingView(label: 'Loading staff analytics…');
    }
    if (_error != null && _rows.isEmpty) {
      return PageErrorView(message: _error!, onRetry: _load);
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        padding: const EdgeInsets.all(16),
        children: [
          _periodCard(),
          const SizedBox(height: 12),
          if (_report.scored.isEmpty)
            const SectionCard(
              title: 'No attendance in this period',
              children: [
                Text(
                  'No attendance records fall inside the selected period. '
                  'Try a wider range such as a quarter or a year.',
                ),
              ],
            )
          else ...[
            _bestEmployeeCard(),
            const SizedBox(height: 12),
            _leaderboardCard(),
            const SizedBox(height: 12),
            _comparisonCard(),
            const SizedBox(height: 12),
            _searchCard(),
          ],
        ],
      ),
    );
  }

  Widget _periodCard() {
    final period = _period;
    return SectionCard(
      title: 'Reporting period',
      trailing: Text(
        period.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.accent(context),
        ),
      ),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final type in AnalyticsPeriodType.values) ...[
                ChoiceChip(
                  label: Text(_periodLabel(type)),
                  selected: _periodType == type,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) {
                    setState(() => _periodType = type);
                    _load();
                  },
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (_periodType == AnalyticsPeriodType.custom)
          _customRangeRow()
        else
          _stepperRow(),
        const SizedBox(height: 8),
        Text(
          '${period.dayCount} day${period.dayCount == 1 ? '' : 's'} · '
          '${DateFormat('d MMM yyyy').format(period.start)} – '
          '${DateFormat('d MMM yyyy').format(period.end)}',
          style: TextStyle(
            fontSize: 11,
            color: AppColors.textSecondary(context),
          ),
        ),
      ],
    );
  }

  Widget _customRangeRow() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _pickCustomFrom,
            icon: const Icon(Icons.event, size: 18),
            label: Text(
              _customFrom == null
                  ? 'From'
                  : DateFormat('d MMM yyyy').format(_customFrom!),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('→'),
        ),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _pickCustomTo,
            icon: const Icon(Icons.event, size: 18),
            label: Text(
              _customTo == null
                  ? 'To'
                  : DateFormat('d MMM yyyy').format(_customTo!),
            ),
          ),
        ),
      ],
    );
  }

  Widget _stepperRow() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _stepAnchor(-1),
            icon: const Icon(Icons.chevron_left, size: 20),
            label: Text(_stepLabel(-1)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _stepAnchor(1),
            icon: const Icon(Icons.chevron_right, size: 20),
            label: Text(_stepLabel(1)),
          ),
        ),
      ],
    );
  }

  String _periodLabel(AnalyticsPeriodType type) => switch (type) {
    AnalyticsPeriodType.day => 'Day',
    AnalyticsPeriodType.week => 'Week',
    AnalyticsPeriodType.month => 'Month',
    AnalyticsPeriodType.quarter => 'Quarter',
    AnalyticsPeriodType.year => 'Year',
    AnalyticsPeriodType.custom => 'Range',
  };

  /// Steps the anchor by one whole period, so "previous month" from September
  /// lands on August rather than drifting by 30 days.
  void _stepAnchor(int direction) {
    final next = switch (_periodType) {
      AnalyticsPeriodType.day => _anchor.add(Duration(days: direction)),
      AnalyticsPeriodType.week => _anchor.add(Duration(days: 7 * direction)),
      AnalyticsPeriodType.month =>
        DateTime(_anchor.year, _anchor.month + direction, 1),
      AnalyticsPeriodType.quarter =>
        DateTime(_anchor.year, _anchor.month + 3 * direction, 1),
      AnalyticsPeriodType.year => DateTime(_anchor.year + direction, 1, 1),
      AnalyticsPeriodType.custom => _anchor,
    };
    // Never step past today: there is no future attendance to report.
    if (next.isAfter(DateTime.now())) return;
    setState(() => _anchor = next);
    _load();
  }

  String _stepLabel(int direction) {
    final word = direction < 0 ? 'Previous' : 'Next';
    return switch (_periodType) {
      AnalyticsPeriodType.day => '$word day',
      AnalyticsPeriodType.week => '$word week',
      AnalyticsPeriodType.month => '$word month',
      AnalyticsPeriodType.quarter => '$word quarter',
      AnalyticsPeriodType.year => '$word year',
      AnalyticsPeriodType.custom => word,
    };
  }

  Future<void> _pickCustomFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _customFrom ?? _anchor,
      firstDate: DateTime(2020),
      lastDate: _customTo ?? DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() => _customFrom = picked);
    _load();
  }

  Future<void> _pickCustomTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _customTo ?? DateTime.now(),
      firstDate: _customFrom ?? DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() => _customTo = picked);
    _load();
  }

  /// The single best employee, pinned as HR asked for.
  Widget _bestEmployeeCard() {
    final best = Leaderboards.overallBest(_report.all);
    if (best == null) return const SizedBox.shrink();

    return SectionCard(
      title: 'Best employee overall',
      children: [
        InkWell(
          onTap: () => _showScorecard(best),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  child: Text(
                    Fmt.initials(best.employeeName),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        best.employeeName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subtitle(best),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${best.score.toStringAsFixed(1)}%',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      '${best.daysPresent} days',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary(context),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _leaderboardTile(LeaderboardEntry entry, bool highlighted) {
    final m = entry.metrics;
    final medal = switch (entry.rank) {
      1 => Icons.emoji_events,
      2 => Icons.workspace_premium_outlined,
      3 => Icons.military_tech_outlined,
      _ => Icons.circle,
    };
    return InkWell(
      onTap: () => _showScorecard(m),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(
              medal,
              size: entry.rank <= 3 ? 18 : 12,
              color: entry.rank == 1
                  ? AppColors.amber
                  : AppColors.textTertiary(context),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.employeeName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: highlighted
                          ? FontWeight.w700
                          : FontWeight.w600,
                    ),
                  ),
                  Text(
                    _subtitle(m),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '${m.score.toStringAsFixed(1)}%',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Top performers, switchable between the whole board and each grouping.
  Widget _leaderboardCard() {
    final selected = LeaderboardDimension.values.firstWhere(
      (d) => d.label == _dimension,
      orElse: () => LeaderboardDimension.branch,
    );
    final groups = selected == LeaderboardDimension.overall
        ? {'Overall': Leaderboards.top(_report.all, limit: 5)}
        : Leaderboards.byGroup(_report.all, selected, limit: 5);

    return SectionCard(
      title: 'Top 5 attendance',
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final d in LeaderboardDimension.values) ...[
                ChoiceChip(
                  label: Text(d.label),
                  selected: _dimension == d.label,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _dimension = d.label),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (groups.isEmpty)
          Text(
            'No attendance recorded for this grouping in the selected period.',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary(context),
            ),
          )
        else
          for (final group in groups.entries) ...[
            if (groups.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text(
                  group.key,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            for (final entry in group.value)
              _leaderboardTile(entry, groups.length == 1),
          ],
      ],
    );
  }

  /// Highlights the employee leading a metric, so a tie reads as a tie.
  Color _leaderColor(
    StaffComparison c,
    AttendanceMetricKind kind,
    StaffAttendanceMetrics m,
  ) {
    if (!m.hasData || c.isTiedOn(kind)) {
      return AppColors.textSecondary(context);
    }
    return c.leaderFor(kind)?.employeeId == m.employeeId
        ? AppColors.green
        : AppColors.textSecondary(context);
  }

  /// The 2-3 way comparison tray.
  Widget _comparisonCard() {
    final c = _comparison;
    if (c.isEmpty) return const SizedBox.shrink();

    return SectionCard(
      title: 'Comparing ${c.employees.length}'
          '${c.employees.length < StaffComparison.maxEmployees ? ' of up to ${StaffComparison.maxEmployees}' : ''}',
      trailing: TextButton(
        onPressed: () => setState(
          () => _comparison = const StaffComparison(employees: []),
        ),
        child: const Text('Clear'),
      ),
      children: [
        for (final m in c.employees)
          Row(
            children: [
              Expanded(
                child: Text(
                  m.employeeName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(
                  () => _comparison = c.removeAt(c.employees.indexOf(m)),
                ),
              ),
            ],
          ),
        const Divider(height: 20),
        Row(
          children: [
            const SizedBox(width: 92),
            for (final m in c.employees)
              Expanded(
                child: Text(
                  Fmt.initials(m.employeeName),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        // A metric-per-row layout: three columns of side-by-side cards would be
        // unreadable at 320 px.
        for (final kind in c.visibleMetrics) ...[
          Row(
            children: [
              SizedBox(
                width: 92,
                child: Text(
                  kind.label,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
              for (final m in c.employees)
                Expanded(
                  child: Text(
                    '${m.scoreFor(kind).toStringAsFixed(0)}%',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _leaderColor(c, kind, m),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }

  String _subtitle(StaffAttendanceMetrics m) {
    final parts = <String>[
      if (m.position.isNotEmpty) m.position,
      if (m.department.isNotEmpty) m.department,
      if (m.branchName.isNotEmpty) m.branchName,
    ];
    return parts.isEmpty ? 'No role recorded' : parts.join(' · ');
  }

  /// Green / amber / rose banding so a score reads at a glance.
  Color _scoreColor(double score) {
    if (score >= 85) return AppColors.green;
    if (score >= 60) return AppColors.amber;
    return AppColors.rose;
  }

  Widget _searchCard() {
    final matches = _matches;
    return SectionCard(
      title: 'Find an employee',
      children: [
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search by name, number, role or branch',
            prefixIcon: Icon(Icons.search, size: 20),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 10),
        if (matches.isEmpty)
          Text(
            'No employee matches "$_query" in this period.',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary(context),
            ),
          )
        else
          for (final m in matches) _employeeTile(m),
      ],
    );
  }

  Widget _employeeTile(StaffAttendanceMetrics m) {
    final selected = _isSelected(m);
    final canAdd = !selected && !_comparison.isFull;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        m.employeeName,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${_subtitle(m)}\n${m.records} day${m.records == 1 ? '' : 's'} · '
        '${m.score.toStringAsFixed(1)}%',
        style: TextStyle(
          fontSize: 11,
          color: AppColors.textSecondary(context),
        ),
      ),
      isThreeLine: true,
      onTap: () => _showScorecard(m),
      trailing: IconButton(
        icon: Icon(
          selected ? Icons.check_circle : Icons.add_circle_outline,
          size: 20,
          color: selected || canAdd
              ? AppColors.accent(context)
              : AppColors.iconMuted(context),
        ),
        tooltip: _comparison.isFull && !selected
            ? 'Comparison is full'
            : selected
            ? 'Remove from comparison'
            : 'Add to comparison',
        onPressed: selected || canAdd
            ? () => setState(() {
                _comparison = selected
                    ? _comparison.removeAt(_comparison.employees.indexOf(m))
                    : _comparison.add(m);
              })
            : null,
      ),
    );
  }

  /// Full scorecard for one employee.
  Future<void> _showScorecard(StaffAttendanceMetrics m) async {
    final period = _period;
    // Rank among everyone WITH data. Someone with no rows is unranked rather
    // than shown as last, because "no data" is not a poor score.
    final rank = Leaderboards.top(
      _report.all,
      limit: _report.all.length,
    ).indexWhere((e) => e.metrics.employeeId == m.employeeId);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              m.employeeName,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _subtitle(m),
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${period.label} · ${m.employeeNumber}',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textTertiary(context),
              ),
            ),
            const SizedBox(height: 16),
            if (!m.hasData)
              const PageEmptyView(
                title: 'No attendance in this period',
                description:
                    'This employee has no attendance records in the selected '
                    'window. They are not ranked as 0% - there is simply '
                    'nothing to score.',
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: StatCard(
                      label: 'Score',
                      value: '${m.score.toStringAsFixed(1)}%',
                      icon: Icons.star_rounded,
                      accent: _scoreColor(m.score),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatCard(
                      label: 'Rank',
                      value: rank < 0 ? '—' : '#${rank + 1}',
                      icon: Icons.leaderboard_outlined,
                      detail: 'of ${_report.scored.length}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _sectionLabel('Scorecard'),
              for (final kind in AttendanceMetricKind.values)
                _metricBar(kind, m.scoreFor(kind)),
              const SizedBox(height: 16),
              _sectionLabel('Attendance detail'),
              _detailRow('Days present', '${m.daysPresent}'),
              _detailRow('Days absent', '${m.daysAbsent}'),
              _detailRow('On-time days', '${m.onTimeDays}'),
              _detailRow('Late days', '${m.lateDays}'),
              if (m.totalLateMinutes > 0)
                _detailRow(
                  'Total lateness',
                  Fmt.lateDuration(m.totalLateMinutes),
                ),
              _detailRow('Total hours', '${m.totalHours.toStringAsFixed(1)}h'),
              _detailRow(
                'Average per present day',
                '${m.averageHoursPerPresentDay.toStringAsFixed(1)}h',
              ),
              _detailRow('Outside geofence', '${m.geofenceViolations}'),
              if (m.incompleteDays > 0)
                _detailRow('Open sessions', '${m.incompleteDays}'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: AppColors.textSecondary(context),
      ),
    ),
  );

  Widget _metricBar(AttendanceMetricKind kind, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${kind.label} (${kind.weight.toStringAsFixed(0)}%)',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
              Text(
                '${value.toStringAsFixed(0)}%',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (value / 100).clamp(0.0, 1.0),
              minHeight: 6,
              color: _scoreColor(value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}