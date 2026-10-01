import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../features/director/director_widgets.dart' show SectionHeader;
import '../../shared/widgets/common.dart';
import 'leave_planner_client.dart';
import 'leave_planner_service.dart';

/// Leave Schedule Planner - read-only timeline.
///
/// Renders the server's verdict and the server's numbers. It performs no leave
/// arithmetic and offers no "approve" or "reject": the planner's job is to show
/// who is away when and how close each day is to its capacity ceiling, so an
/// executive can see a clash BEFORE approving the request that causes it.
///
/// Default window is the current month, which is the window a leave decision is
/// usually made in; [initialMonths] lets the director drill into other months.
class LeavePlannerScreen extends StatefulWidget {
  const LeavePlannerScreen({super.key, this.initialMonths = 1});

  /// How many months to show in the window, counting back from this month.
  final int initialMonths;

  @override
  State<LeavePlannerScreen> createState() => _LeavePlannerScreenState();
}

class _LeavePlannerScreenState extends State<LeavePlannerScreen> {
  LeavePlanner? _planner;
  String? _error;
  bool _loading = true;

  /// First day of the first month in the window.
  late DateTime _from = _monthStart(0);

  /// Last day of the last month in the window.
  late DateTime _to = _monthEnd(widget.initialMonths - 1);

  /// The month whose detail is expanded, or null for "all months".
  DateTime? _focusMonth;

  static DateTime _monthStart(int back) {
    final now = DateTime.now();
    return DateTime(now.year, now.month - back, 1);
  }

  static DateTime _monthEnd(int back) {
    final start = _monthStart(back);
    return DateTime(start.year, start.month + 1, 0); // day 0 = last of month
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final planner = await LeavePlannerClient.instance.planner(
        from: LeavePlannerClient.isoDate(_from),
        to: LeavePlannerClient.isoDate(_to),
      );
      if (mounted) setState(() => _planner = planner);
    } on LeavePlannerException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Shift the whole window back or forward by [delta] months.
  void _shiftWindow(int delta) {
    setState(() {
      _from = DateTime(_from.year, _from.month + delta, 1);
      final endBack = delta < 0 ? -delta - 1 : widget.initialMonths - 1;
      _to = DateTime(_from.year, _from.month + endBack + 1, 0);
      _focusMonth = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _planner == null) {
      return const PageLoadingView(label: 'Loading the leave planner…');
    }
    if (_error != null && _planner == null) {
      return PageErrorView(message: _error!, onRetry: _load);
    }
    final planner = _planner;
    if (planner == null) return const SizedBox.shrink();

    // Entries in the focused month, or all of them when no month is focused.
    final entries = _focusMonth == null
        ? planner.entries
        : planner.entries.where((e) {
            final start = DateTime.tryParse(e.startDate);
            return start != null &&
                start.year == _focusMonth!.year &&
                start.month == _focusMonth!.month;
          }).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _WindowHeader(
            from: _from,
            to: _to,
            onPrevious: () => _shiftWindow(-1),
            onNext: () => _shiftWindow(1),
          ),
          const SizedBox(height: 12),
          _CapacityHeatmap(days: planner.capacity),
          const SizedBox(height: 12),
          _MonthFocus(
            months: _monthsInWindow(planner),
            selected: _focusMonth,
            onChanged: (m) => setState(() => _focusMonth = m),
          ),
          const SizedBox(height: 12),
          SectionHeader(title: 'ON LEAVE (${entries.length})'),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Nobody is on leave in this window.',
                textAlign: TextAlign.center,
              ),
            )
          else
            for (final group in _groupByDay(entries).entries)
              _DayGroup(date: group.key, entries: group.value),
        ],
      ),
    );
  }

  /// Every month that actually has entries, for the focus filter.
  List<DateTime> _monthsInWindow(LeavePlanner planner) {
    final out = <DateTime>[];
    for (final e in planner.entries) {
      final d = DateTime.tryParse(e.startDate);
      if (d == null) continue;
      final m = DateTime(d.year, d.month);
      if (!out.contains(m)) out.add(m);
    }
    out.sort((a, b) => b.compareTo(a)); // newest first
    return out;
  }

  /// Groups entries by start date so the timeline reads as "who is away today"
  /// rather than an undifferentiated list.
  Map<DateTime, List<PlannerEntry>> _groupByDay(List<PlannerEntry> entries) {
    final out = <DateTime, List<PlannerEntry>>{};
    for (final e in entries) {
      final d = DateTime.tryParse(e.startDate);
      if (d == null) continue;
      (out[DateTime(d.year, d.month, d.day)] ??= <PlannerEntry>[]).add(e);
    }
    final keys = out.keys.toList()..sort((a, b) => a.compareTo(b));
    return {for (final k in keys) k: out[k]!};
  }
}
/// The window being viewed, with month-step controls.
///
/// The label always states the exact range, so a figure is never read against
/// the wrong window - the ambiguity that made "3 on leave" meaningless when the
/// window was not shown.
class _WindowHeader extends StatelessWidget {
  const _WindowHeader({
    required this.from,
    required this.to,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime from;
  final DateTime to;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '${monthName(from)} - ${monthName(to)} ${to.year}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary(context),
            ),
          ),
        ),
        IconButton(
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Previous month',
        ),
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Next month',
        ),
      ],
    );
  }
}

/// Abbreviated month name. Shared by the window header, the heatmap and the day
/// groups so a month can never be spelled two ways on one screen.
/// Capacity heatmap: one cell per day the server scored.
///
/// The ceiling and the headcount are the SERVER's. This only tints them, and
/// days at their ceiling are also labelled in text so the warning is never
/// carried by colour alone.
class _CapacityHeatmap extends StatelessWidget {
  const _CapacityHeatmap({required this.days});

  final List<LeaveCapacityDay> days;

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();

    final atCapacity = days.where((d) => d.isAtCapacity).length;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'LEAVE CAPACITY',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
              if (atCapacity > 0)
                Text(
                  '$atCapacity day${atCapacity == 1 ? '' : 's'} at capacity',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warn(context),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final d in days)
                Tooltip(
                  message:
                      '${d.date}: ${d.onLeave} away'
                      '${d.maxOnLeave == null ? '' : ' of ${d.maxOnLeave} allowed'}',
                  child: Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _tint(context, d),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: d.isAtCapacity
                            ? AppColors.warn(context)
                            : AppColors.border(context),
                      ),
                    ),
                    // The day number is the non-colour signal.
                    child: Text(
                      '${DateTime.tryParse(d.date)?.day ?? ''}',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: d.isAtCapacity
                            ? FontWeight.w800
                            : FontWeight.w500,
                        color: AppColors.textPrimary(context),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Amber as a day approaches its ceiling, red once it is reached.
  ///
  /// Only a tint. The server owns the policy; this just makes pressure visible.
  Color _tint(BuildContext context, LeaveCapacityDay d) {
    final base = AppColors.surface(context);
    if (d.isAtCapacity) return AppColors.warn(context).withValues(alpha: 0.35);
    if (d.pressure <= 0) return base;
    return AppColors.accent(context).withValues(alpha: d.pressure * 0.45);
  }
}

/// Month focus filter. "All" clears the filter.
class _MonthFocus extends StatelessWidget {
  const _MonthFocus({
    required this.months,
    required this.selected,
    required this.onChanged,
  });

  final List<DateTime> months;
  final DateTime? selected;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (months.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _chip(context, 'All months', selected == null, () => onChanged(null)),
          for (final m in months)
            _chip(
              context,
              monthName(m),
              selected?.year == m.year && selected?.month == m.month,
              () => onChanged(m),
            ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    String label,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          color: isSelected
              ? AppColors.accent(context)
              : AppColors.textSecondary(context),
        ),
      ),
    );
  }
}

/// One day on the timeline, with everyone starting leave that day.
class _DayGroup extends StatelessWidget {
  const _DayGroup({required this.date, required this.entries});

  final DateTime date;
  final List<PlannerEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${date.day} ${monthName(date)} ${date.year}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 6),
          for (final e in entries) _EntryRow(entry: e),
        ],
      ),
    );
  }
}

/// One person on the timeline.
class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry});

  final PlannerEntry entry;

  @override
  Widget build(BuildContext context) {
    final state = plannerStates[entry.plannerState];

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.fullName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle(),
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          // Glyph + label, so state is never conveyed by colour alone.
          Text(
            '${state?.glyph ?? '·'} ${state?.label ?? entry.status}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary(context),
            ),
          ),
        ],
      ),
    );
  }

  /// "Legal · 3 working days" - never a computed duration, always the server's.
  String _subtitle() {
    final parts = <String>[
      if (entry.department?.isNotEmpty ?? false) entry.department!,
      if (entry.position?.isNotEmpty ?? false) entry.position!,
      if (entry.workingDays > 0)
        '${entry.workingDays} working day${entry.workingDays == 1 ? '' : 's'}',
      entry.leaveType,
    ];
    return parts.join(' · ');
  }
}
/// Abbreviated month name.
///
/// Shared by the window header, the heatmap and the day groups so a month can
/// never be spelled two different ways on one screen.
String monthName(DateTime d) => const [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ][d.month - 1];
