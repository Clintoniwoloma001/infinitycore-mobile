// ============================================================================
// Automation Command Centre — read-only mobile view
// ============================================================================
// The mobile counterpart of the web Automation Command Centre. It shows the
// same departments, the same counts and the same derived percentages, because
// all of it comes from the one `get_automation_portfolio()` RPC.
//
// A TRACKER, not a report. There is no percentage typed in anywhere on this
// screen: each bar is the server's own figure for a department's real tracked
// items.
//
// READ-ONLY. Status changes are a web capability; see automation_service.dart
// for why, and for the fact that the server refuses them without
// `automation.portfolio.manage`.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../director/director_widgets.dart';
import 'automation_service.dart';

/// Red -> amber -> green, so a bar reads as a health signal at a glance.
///
/// Mirrors the web `barColour()` exactly, so a department does not change
/// colour between the two platforms. A null [pct] (the server measured nothing)
/// gets the same neutral grey web uses for a zero bar, because there is no
/// value to colour by.
Color automationBarColour(double? pct) {
  final p = pct ?? 0;
  if (p >= 75) return const Color(0xFF10B981);
  if (p >= 50) return const Color(0xFFF59E0B);
  if (p > 0) return const Color(0xFFF97316);
  return const Color(0xFFCBD5E1);
}

class AutomationCommandCentreScreen extends StatefulWidget {
  const AutomationCommandCentreScreen({super.key});

  @override
  State<AutomationCommandCentreScreen> createState() =>
      _AutomationCommandCentreScreenState();
}

class _AutomationCommandCentreScreenState
    extends State<AutomationCommandCentreScreen> {
  AutomationPortfolio? _portfolio;
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
      final p = await AutomationService.instance.portfolio();
      if (!mounted) return;
      setState(() => _portfolio = p);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Automation Command Centre'),
        actions: [
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
        message: 'Unable to load the automation portfolio.',
        detail: _error,
        onRetry: _load,
      );
    }
    final portfolio = _portfolio;
    if (portfolio == null || portfolio.departments.isEmpty) {
      return const PageEmptyView(
        title: 'No departments tracked yet',
        description: 'Automation items appear here once they are seeded.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Text(
            'Progress across every department\'s automation workstreams. '
            'Percentages are calculated from tracked items, not entered by '
            'hand.',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 14),
          _Totals(portfolio: portfolio),
          const SizedBox(height: 18),
          const SectionHeader(title: 'AUTOMATION PORTFOLIO'),
          for (final d in portfolio.departments) ...[
            _DepartmentCard(department: d, portfolio: portfolio),
            const SizedBox(height: 12),
          ],
          if (portfolio.activeWorkflows.isNotEmpty) ...[
            const SectionHeader(title: 'ACTIVE WORKFLOWS'),
            for (final w in portfolio.activeWorkflows) ...[
              _WorkflowRow(item: w),
              const SizedBox(height: 8),
            ],
          ],
          const SizedBox(height: 6),
          Text(
            'View only on mobile. Status changes are made on the web platform.',
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

/// Tracked items / live / departments in scope — the web's three stat tiles.
class _Totals extends StatelessWidget {
  const _Totals({required this.portfolio});

  final AutomationPortfolio portfolio;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Tile(
            label: 'Tracked items',
            value: '${portfolio.totalItems}',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Tile(
            label: 'Live',
            value: '${portfolio.totalLive}',
            color: const Color(0xFF059669),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Tile(
            label: 'Departments',
            value: '${portfolio.departments.length}',
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
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
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: color ?? AppColors.textPrimary(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// One department's completion bar and its expandable item list.
class _DepartmentCard extends StatefulWidget {
  const _DepartmentCard({required this.department, required this.portfolio});

  final AutomationDepartment department;
  final AutomationPortfolio portfolio;

  @override
  State<_DepartmentCard> createState() => _DepartmentCardState();
}

class _DepartmentCardState extends State<_DepartmentCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.department;
    final items = widget.portfolio.itemsForDepartment(d);
    final pct = d.completionPct;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: items.isEmpty ? null : () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          d.label,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary(context),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        pct == null ? '--' : '${pct.toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: automationBarColour(pct),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  MetricBar(
                    value: pct,
                    color: automationBarColour(pct),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '${d.live} live · ${d.inProgress} in progress · '
                    '${d.notStarted} not started',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                  if (items.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      _expanded
                          ? 'Hide ${items.length} tracked ${items.length == 1 ? 'item' : 'items'}'
                          : 'Show ${items.length} tracked ${items.length == 1 ? 'item' : 'items'}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_expanded && items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Divider(height: 1, color: AppColors.border(context)),
                  const SizedBox(height: 8),
                  for (final item in items) _ItemRow(item: item),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final AutomationItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              _statusIcon(item.status),
              size: 14,
              color: _statusColour(context, item.status),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary(context),
                  ),
                ),
                if (item.description.isNotEmpty)
                  Text(
                    item.description,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.3,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          StatusBadge(label: item.status.label),
        ],
      ),
    );
  }
}

class _WorkflowRow extends StatelessWidget {
  const _WorkflowRow({required this.item});

  final AutomationItem item;

  @override
  Widget build(BuildContext context) {
    final label = item.department.isEmpty ? '' : _prettyDept(item.department);
    final when = item.liveAt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.play_circle_outline,
            size: 16,
            color: AppColors.amber,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary(context),
                  ),
                ),
                Text(
                  [
                    if (label.isNotEmpty) label,
                    if (when != null) DateFormat('d MMM yyyy').format(when),
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData _statusIcon(AutomationStatus s) => switch (s) {
  AutomationStatus.live => Icons.check_circle_outline,
  AutomationStatus.inProgress => Icons.timelapse,
  AutomationStatus.notStarted => Icons.radio_button_unchecked,
};

Color _statusColour(BuildContext context, AutomationStatus s) => switch (s) {
  AutomationStatus.live => AppColors.green,
  AutomationStatus.inProgress => AppColors.amber,
  AutomationStatus.notStarted => AppColors.textTertiary(context),
};

String _prettyDept(String key) => key
    .split('_')
    .where((w) => w.isNotEmpty)
    .map((w) => w[0].toUpperCase() + w.substring(1))
    .join(' ');
