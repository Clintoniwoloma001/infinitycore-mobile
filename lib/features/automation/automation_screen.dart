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
    extends State<AutomationCommandCentreScreen>
    with SingleTickerProviderStateMixin {
  AutomationPortfolio? _portfolio;
  List<AutomationTask> _myWork = const [];
  bool _canAssign = false;
  bool _loading = true;
  bool _myWorkLoading = true;
  String? _error;
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _load();
    _loadMyWork();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// The signed-in person's automation queue.
  ///
  /// Deliberately fails soft: this tab is an addition to the Command Centre,
  /// not its purpose, so a failure here must never blank the portfolio the
  /// executive came to see.
  Future<void> _loadMyWork() async {
    setState(() => _myWorkLoading = true);
    try {
      final tasks = await AutomationService.instance.myWork();
      if (!mounted) return;
      setState(() => _myWork = tasks);
    } catch (_) {
      if (mounted) setState(() => _myWork = const []);
    } finally {
      if (mounted) setState(() => _myWorkLoading = false);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        AutomationService.instance.portfolio(),
        AutomationService.instance.canAssign(),
      ]);
      if (!mounted) return;
      setState(() {
        _portfolio = results[0] as AutomationPortfolio;
        _canAssign = results[1] as bool;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_load(), _loadMyWork()]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Automation Command Centre'),
        actions: [
          if (_canAssign)
            IconButton(
              icon: const Icon(Icons.add_task),
              tooltip: 'Assign automation work',
              onPressed: _openAssignSheet,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refreshAll,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            const Tab(text: 'Portfolio'),
            Tab(
              text: _myWork.isEmpty
                  ? 'My Work'
                  : 'My Work (${_myWork.length})',
            ),
          ],
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading && _portfolio == null && _error == null) {
      return const PageLoadingView();
    }
    if (_error != null && _portfolio == null) {
      return PageErrorView(
        message: 'Unable to load the automation portfolio.',
        detail: _error,
        onRetry: _load,
      );
    }
    return TabBarView(
      controller: _tabs,
      children: [_portfolioTab(), _myWorkTab()],
    );
  }

  Future<void> _openAssignSheet() async {
    final portfolio = _portfolio;
    if (portfolio == null) return;
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AssignSheet(departments: portfolio.departments),
    );
    if (created == true) {
      await _refreshAll();
      if (mounted) _tabs.animateTo(1);
    }
  }

  Widget _portfolioTab() {
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
            'Portfolio status changes are made on the web platform. Your own '
            'assigned work is on the My Work tab.',
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

  Widget _myWorkTab() {
    if (_myWorkLoading && _myWork.isEmpty) {
      return const PageLoadingView(label: 'Loading your work…');
    }
    if (_myWork.isEmpty) {
      return PageEmptyView(
        title: 'No automation work assigned to you',
        description: _canAssign
            ? 'Use the + button to raise an automation task.'
            : 'Work raised against you on the automation register will appear '
                  'here.',
      );
    }

    final overdue = _myWork.where((t) => t.isOverdue).length;
    final open = _myWork.where((t) => t.isOpen).length;

    return RefreshIndicator(
      onRefresh: _loadMyWork,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Text(
            'Automation work assigned to you. Progress is what was last '
            'reported, never an estimate.',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  label: 'Open',
                  value: '$open',
                  tone: AppColors.accent(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MiniStat(
                  label: 'Overdue',
                  value: '$overdue',
                  tone: overdue > 0
                      ? AppColors.rose
                      : AppColors.textTertiary(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MiniStat(
                  label: 'All',
                  value: '${_myWork.length}',
                  tone: AppColors.textSecondary(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final t in _myWork) ...[
            _MyWorkCard(task: t),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

/// Compact stat used by the My Work header.
class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    required this.tone,
  });

  final String label;
  final String value;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: tone,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// Status rendered as a coloured pill rather than raw enum text.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (status.toLowerCase()) {
      'completed' => (AppColors.green, Colors.white),
      'in_progress' => (AppColors.accent(context), Colors.white),
      'submitted' || 'under_review' => (AppColors.amber, Colors.white),
      'overdue' || 'needs_revision' => (AppColors.rose, Colors.white),
      _ => (AppColors.border(context), AppColors.textSecondary(context)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

/// One assigned automation task.
class _MyWorkCard extends StatelessWidget {
  const _MyWorkCard({required this.task});

  final AutomationTask task;

  @override
  Widget build(BuildContext context) {
    final pct = task.progressPct;
    final due = task.dueDate;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: task.isOverdue
              ? AppColors.rose.withValues(alpha: 0.5)
              : AppColors.border(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  task.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StatusPill(status: task.status),
            ],
          ),
          if (task.department.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              task.department,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
          if (task.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              task.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
          const SizedBox(height: 10),
          // "Not reported" is stated as such. A 0% bar would imply the work was
          // assessed and found to have nothing done, a different claim.
          if (pct == null)
            Row(
              children: [
                Icon(
                  Icons.remove_circle_outline,
                  size: 14,
                  color: AppColors.textTertiary(context),
                ),
                const SizedBox(width: 6),
                Text(
                  'No progress reported yet',
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: AppColors.textTertiary(context),
                  ),
                ),
              ],
            )
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (pct / 100).clamp(0.0, 1.0),
                minHeight: 6,
                color: automationBarColour(pct),
                backgroundColor: AppColors.border(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${pct.toStringAsFixed(0)}% reported',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
          if (due != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  task.isOverdue
                      ? Icons.warning_amber_rounded
                      : Icons.event_outlined,
                  size: 14,
                  color: task.isOverdue
                      ? AppColors.rose
                      : AppColors.textSecondary(context),
                ),
                const SizedBox(width: 6),
                Text(
                  task.isOverdue
                      ? 'Overdue — due ${DateFormat('d MMM').format(due)}'
                      : 'Due ${DateFormat('d MMM yyyy').format(due)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: task.isOverdue
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: task.isOverdue
                        ? AppColors.rose
                        : AppColors.textSecondary(context),
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

/// Raise automation work against a department.
class _AssignSheet extends StatefulWidget {
  const _AssignSheet({required this.departments});

  final List<AutomationDepartment> departments;

  @override
  State<_AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends State<_AssignSheet> {
  final _formKey = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _description = TextEditingController();
  String? _department;
  DateTime? _due;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _due ?? DateTime.now().add(const Duration(days: 7)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _due = picked);
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // No assignee is sent: the server defaults it to the caller, which is
      // how a specialist raises their OWN work. Choosing another person needs
      // the commissioning role plus a real user directory, and is not guessed.
      await AutomationService.instance.assignWorkTask(
        department: _department ?? '',
        label: _label.text,
        description: _description.text,
        dueDate: _due,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Assign automation work',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary(context),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Raised against the automation register and assigned to you.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textSecondary(context),
                ),
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<String>(
                initialValue: _department,
                decoration: const InputDecoration(labelText: 'Department'),
                items: [
                  for (final d in widget.departments)
                    DropdownMenuItem(
                      value: d.key.isNotEmpty ? d.key : d.label,
                      child: Text(d.label),
                    ),
                ],
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Choose a department.' : null,
                onChanged: (v) => setState(() => _department = v),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _label,
                decoration: const InputDecoration(labelText: 'Task title'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter a title.' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _description,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickDue,
                icon: const Icon(Icons.event, size: 18),
                label: Text(
                  _due == null
                      ? 'Set a due date'
                      : 'Due ${DateFormat('d MMM yyyy').format(_due!)}',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.rose.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppColors.rose.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(fontSize: 12, color: AppColors.rose),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Assign'),
                ),
              ),
            ],
          ),
        ),
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
            onTap: items.isEmpty
                ? null
                : () => setState(() => _expanded = !_expanded),
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
                  MetricBar(value: pct, color: automationBarColour(pct)),
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
          Icon(Icons.play_circle_outline, size: 16, color: AppColors.amber),
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
