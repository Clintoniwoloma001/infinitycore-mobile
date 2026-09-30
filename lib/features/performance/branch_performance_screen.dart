// ============================================================================
// Branch Performance — mobile view
// ============================================================================
// WHERE THE NUMBERS COME FROM
// There is no standalone "Branch Performance Dashboard" module on the web
// platform to port. The real, server-aggregated branch figures already exist
// inside the executive snapshot (`get_director_executive_snapshot` -> the
// `branches` array), where the web Director dashboard renders them as a
// "Branch performance" table.
//
// So this screen reads that SAME RPC through the SAME [DirectorService] the
// Director experience already uses. It adds no new RPC, no new table and no
// new business formula: every figure below - staff, attendance rate, KPI
// completion, target completion, on leave - is computed once by the database,
// so this screen cannot disagree with the web Director dashboard for the same
// period.
//
// NOTHING HERE IS INVENTED. A metric the server did not measure renders as a
// dash and an empty bar, never as zero.
// ============================================================================
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../director/director_service.dart';
import '../director/director_widgets.dart';
import 'branch_sort.dart';

/// One branch's row, as computed by the server.
class BranchPerformance {
  const BranchPerformance(this.raw);

  final Map<String, dynamic> raw;

  String get id => raw['id']?.toString() ?? '';
  String get name => raw['name']?.toString() ?? '';

  int get totalStaff => asInt(raw['total_staff']) ?? 0;
  int get activeStaff => asInt(raw['active_staff']) ?? 0;
  int get onLeave => asInt(raw['on_leave']) ?? 0;

  double? get attendanceRate => _rate('attendance_rate');
  double? get kpiCompletion => _rate('kpi_completion');
  double? get targetCompletion => _rate('target_completion');

  /// These come from the server already rounded. They are not recomputed, and
  /// they are not derived from a client-side join date or a local count.
  double? _rate(String key) {
    final v = raw[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

class BranchPerformanceScreen extends StatefulWidget {
  const BranchPerformanceScreen({super.key});

  @override
  State<BranchPerformanceScreen> createState() =>
      _BranchPerformanceScreenState();
}

class _BranchPerformanceScreenState extends State<BranchPerformanceScreen> {
  DirectorSnapshot? _snapshot;
  DirectorPeriod _period = DirectorPeriod.thisMonth();
  bool _loading = true;
  String? _error;
  BranchSort _sort = BranchSort.byStaff;

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
      final s = await DirectorService.instance.snapshot(
        from: _period.from,
        to: _period.to,
      );
      if (!mounted) return;
      setState(() => _snapshot = s);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickPeriod() async {
    final options = <(String, DirectorPeriod)>[
      ('Today', DirectorPeriod.today()),
      ('This week', DirectorPeriod.thisWeek()),
      ('This month', DirectorPeriod.thisMonth()),
      ('This quarter', DirectorPeriod.thisQuarter()),
    ];
    final picked = await showModalBottomSheet<DirectorPeriod>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.surface(context),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (label, period) in options)
              ListTile(
                title: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary(sheetContext),
                  ),
                ),
                selected: period.label == _period.label,
                onTap: () => Navigator.of(sheetContext).pop(period),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _period = picked);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Branch Performance'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today_outlined),
            tooltip: 'Period',
            onPressed: _loading ? null : _pickPeriod,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const PageLoadingView();
    if (_error != null) {
      return PageErrorView(
        message: 'Unable to load branch performance.',
        detail: _error,
        onRetry: _load,
      );
    }

    final branches = (_snapshot?.branches ?? const [])
        .map(BranchPerformance.new)
        .toList(growable: false);
    if (branches.isEmpty) {
      return const PageEmptyView(
        title: 'No branch data for this period',
        description:
            'Try a wider period, or ask HR to confirm branch assignments.',
      );
    }

    final sorted = _sort.apply(branches);
    final totalStaff = branches.fold<int>(0, (a, b) => a + b.totalStaff);
    final totalOnLeave = branches.fold<int>(0, (a, b) => a + b.onLeave);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_period.label} · ${DirectorPeriod.toIso(_period.from)} to '
                  '${DirectorPeriod.toIso(_period.to)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _pickPeriod,
                icon: const Icon(Icons.tune, size: 15),
                label: const Text('Period'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          MetricStrip(
            tiles: [
              MetricTile(
                label: 'Branches',
                value: '${branches.length}',
                icon: Icons.account_balance_outlined,
              ),
              MetricTile(
                label: 'Total staff',
                value: '$totalStaff',
                icon: Icons.groups_outlined,
              ),
              MetricTile(
                label: 'On leave',
                value: '$totalOnLeave',
                icon: Icons.beach_access_outlined,
              ),
            ],
          ),
          const SizedBox(height: 18),
          SectionHeader(
            title: 'BY BRANCH',
            trailing: _SortButton(
              sort: _sort,
              onChanged: (s) => setState(() => _sort = s),
            ),
          ),
          for (final b in sorted) ...[
            _BranchCard(branch: b),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 4),
          Text(
            'Figures are aggregated by the server for the selected period, the '
            'same figures the web Director dashboard shows.',
            style: TextStyle(
              fontSize: 10.5,
              fontStyle: FontStyle.italic,
              color: AppColors.textTertiary(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchCard extends StatelessWidget {
  const _BranchCard({required this.branch});

  final BranchPerformance branch;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  branch.name,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary(context),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${branch.activeStaff}/${branch.totalStaff} active',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Rate(label: 'Attendance', value: branch.attendanceRate),
          const SizedBox(height: 7),
          _Rate(label: 'KPI', value: branch.kpiCompletion),
          const SizedBox(height: 7),
          _Rate(label: 'Targets', value: branch.targetCompletion),
          if (branch.onLeave > 0) ...[
            const SizedBox(height: 9),
            Row(
              children: [
                Icon(
                  Icons.beach_access_outlined,
                  size: 13,
                  color: AppColors.amber,
                ),
                const SizedBox(width: 5),
                Text(
                  '${branch.onLeave} on leave',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One labelled bar. A null [value] draws an empty track, so "not measured" is
/// visibly different from 0%.
class _Rate extends StatelessWidget {
  const _Rate({required this.label, required this.value});

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 68,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: AppColors.textSecondary(context),
            ),
          ),
        ),
        Expanded(child: MetricBar(value: value)),
        const SizedBox(width: 8),
        SizedBox(
          width: 42,
          child: Text(
            value == null ? '--' : '${value!.toStringAsFixed(0)}%',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: value == null
                  ? AppColors.textTertiary(context)
                  : AppColors.textPrimary(context),
            ),
          ),
        ),
      ],
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.sort, required this.onChanged});

  final BranchSort sort;
  final ValueChanged<BranchSort> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<BranchSort>(
      tooltip: 'Sort branches',
      icon: const Icon(Icons.swap_vert, size: 18),
      initialValue: sort,
      onSelected: onChanged,
      itemBuilder: (_) => const [
        PopupMenuItem(value: BranchSort.byStaff, child: Text('Most staff')),
        PopupMenuItem(
          value: BranchSort.attendanceDesc,
          child: Text('Best attendance'),
        ),
        PopupMenuItem(
          value: BranchSort.attendanceAsc,
          child: Text('Lowest attendance'),
        ),
        PopupMenuItem(value: BranchSort.nameAsc, child: Text('Name (A-Z)')),
      ],
    );
  }
}
