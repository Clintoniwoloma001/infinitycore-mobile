import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/routing/app_router.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/notification_badge.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../training/signature_pad.dart';
import 'leave_pdf.dart';
import 'leave_service.dart';

/// Mobile Leave Requests module.
///
/// Reads and writes the same `leave_requests` / `leave_balances` /
/// `leave_approvals` records and the same RPCs as the web platform's
/// Leave Requests module, so a request raised here appears in the web
/// approval queue with identical routing.
class LeaveRequestsScreen extends StatefulWidget {
  const LeaveRequestsScreen({super.key});

  @override
  State<LeaveRequestsScreen> createState() => _LeaveRequestsScreenState();
}

class _LeaveRequestsScreenState extends State<LeaveRequestsScreen> {
  List<LeaveBalance> _balances = const [];
  List<LeaveRequest> _requests = const [];
  bool _loading = true;
  String? _error;
  String _filter = 'all';

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
      final balances = await LeaveService.instance.myBalances();
      final requests = await LeaveService.instance.myRequests();
      if (!mounted) return;
      setState(() {
        _balances = balances;
        _requests = requests;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<LeaveRequest> get _visible => _filter == 'all'
      ? _requests
      : _requests
            .where((r) => r.status.toLowerCase() == _filter)
            .toList(growable: false);

  Future<void> _openComposer() async {
    final created = await showModalBottomSheet<LeaveRequest>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const LeaveComposerSheet(),
    );
    if (created != null) {
      if (mounted) {
        showSnack('Leave request submitted for approval.');
      }
      await _load();
      await NotificationBadge.instance.refresh();
    }
  }

  Future<void> _openDetail(LeaveRequest request) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => LeaveDetailSheet(
        request: request,
        onChanged: _load,
      ),
    );
    await _load();
  }

  bool get _canApproveQueue =>
      AuthService.instance.role.isNotEmpty && _approverRoles.contains(
        AuthService.instance.role,
      );

  @override
  Widget build(BuildContext context) {
    if (_loading && _requests.isEmpty && _balances.isEmpty) {
      return const PageLoadingView(label: 'Loading leave records');
    }
    if (_error != null && _requests.isEmpty) {
      return PageErrorView(message: _error!, onRetry: _load);
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      // No floatingActionButton here. HomeShell already pins the SARA chat
      // bubble to the bottom-right, and an inner Scaffold FAB lands on exactly
      // the same anchor, so the two overlap. The primary action rides at the
      // end of the balance strip instead, which cannot collide.
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          children: [
            _BalanceStrip(balances: _balances),
            const SizedBox(height: 14),
            // Primary action, inline. See the note on this Scaffold's missing
            // floatingActionButton: the shell's SARA bubble owns that corner.
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _openComposer,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent(context),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Request leave'),
              ),
            ),
            const SizedBox(height: 16),
            _StatusFilter(
              selected: _filter,
              counts: {
                for (final s in leaveStatuses)
                  s: _requests
                      .where((r) => r.status.toLowerCase() == s)
                      .length,
              },
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 12),
            if (_canApproveQueue) ...[
              _ApprovalQueueHint(
                onOpen: () => showSnack(
                  'Approvals from other employees are managed on the web '
                  'console. Your own requests are shown here.',
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_visible.isEmpty)
              const PageEmptyView(
                title: 'No leave requests',
                description: 'Requests you submit will appear here with their '
                    'approval progress.',
              )
            else
              for (final r in _visible) ...[
                _LeaveRequestTile(
                  request: r,
                  onTap: () => _openDetail(r),
                ),
                const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

/// Roles that carry approval capability on the web console.
const Set<String> _approverRoles = {
  'admin',
  'super_admin',
  'branch_manager',
  'area_manager',
  'head_of_business',
  'head_of_human_resources',
  'hr_officer',
  'line_manager',
};

/// Animated balance strip. Each card fills proportionally to days consumed so
/// the remaining entitlement is readable at a glance.
class _BalanceStrip extends StatelessWidget {
  const _BalanceStrip({required this.balances});

  final List<LeaveBalance> balances;

  @override
  Widget build(BuildContext context) {
    if (balances.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 118,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: balances.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) => _BalanceCard(balance: balances[i]),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.balance});

  final LeaveBalance balance;

  @override
  Widget build(BuildContext context) {
    final entitled = balance.entitled;
    final remaining = balance.remaining;
    final consumed = entitled == null || entitled == 0
        ? 0.0
        : ((entitled - remaining) / entitled).clamp(0.0, 1.0);
    final value = entitled == null || !remaining.isFinite
        ? (entitled == null ? 'Uncapped' : '0')
        : remaining.toStringAsFixed(remaining % 1 == 0 ? 0 : 1);
    return Container(
      width: 158,
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
            balance.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary(context),
            ),
          ),
          const Spacer(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary(context),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'days left',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: consumed),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 6,
                backgroundColor: AppColors.accent(
                  context,
                ).withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation(
                  AppColors.accent(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class _StatusFilter extends StatelessWidget {
  const _StatusFilter({
    required this.selected,
    required this.counts,
    required this.onChanged,
  });

  final String selected;
  final Map<String, int> counts;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final entries = <String>['all', ...leaveStatuses];
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final key = entries[i];
          final active = key == selected;
          final count = key == 'all'
              ? counts.values.fold<int>(0, (a, b) => a + b)
              : counts[key] ?? 0;
          return ChoiceChip(
            selected: active,
            onSelected: (_) => onChanged(key),
            label: Text(
              '${key == 'all' ? 'All' : _titleCase(key)}'
              '${count > 0 ? '  $count' : ''}',
            ),
            labelStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: active ? Colors.white : AppColors.textSecondary(context),
            ),
            selectedColor: AppColors.accent(context),
            backgroundColor: AppColors.surface(context),
            side: BorderSide(color: AppColors.border(context)),
            showCheckmark: false,
          );
        },
      ),
    );
  }
}

class _ApprovalQueueHint extends StatelessWidget {
  const _ApprovalQueueHint({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.verified_user_outlined,
            size: 18,
            color: AppColors.amber,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'You are an approver. Team requests are actioned in the web '
              'console; your own leave is managed here.',
              style: TextStyle(
                fontSize: 11.5,
                color: AppColors.textSecondary(context),
              ),
            ),
          ),
          TextButton(onPressed: onOpen, child: const Text('Got it')),
        ],
      ),
    );
  }
}

String _titleCase(String value) => value.isEmpty
    ? value
    : '${value[0].toUpperCase()}${value.substring(1)}';


/// One leave request row, with an inline progress rail showing how far the
/// configured approval chain has advanced.
class _LeaveRequestTile extends StatelessWidget {
  const _LeaveRequestTile({required this.request, required this.onTap});

  final LeaveRequest request;
  final VoidCallback onTap;

  Color _statusColor(BuildContext context) {
    switch (request.status.toLowerCase()) {
      case 'approved':
        return AppColors.accent(context);
      case 'rejected':
        return AppColors.rose;
      case 'cancelled':
        return AppColors.textTertiary(context);
      default:
        return AppColors.amber;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      request.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary(context),
                      ),
                    ),
                  ),
                  StatusBadge(
                    label: _titleCase(request.status),
                    color: color,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.date_range_outlined,
                    size: 14,
                    color: AppColors.textTertiary(context),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${request.startDate} → ${request.endDate}'
                      '  ·  ${request.days.toStringAsFixed(request.days % 1 == 0 ? 0 : 1)} day(s)',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary(context),
                      ),
                    ),
                  ),
                ],
              ),
              if (request.reason.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  request.reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textTertiary(context),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  for (var i = 0; i < 4; i++) ...[
                    Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        height: 4,
                        decoration: BoxDecoration(
                          color: i < request.approvalLevel
                              ? color
                              : AppColors.border(context),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    if (i < 3) const SizedBox(width: 4),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                request.approverName.trim().isEmpty
                    ? 'Stage ${request.approvalLevel} · awaiting approver'
                    : 'Stage ${request.approvalLevel} · ${request.approverName}',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// New-leave composer. Writes to the same `leave_requests` table as web, so
/// the server resolves the identical approval chain from the created row.
class LeaveComposerSheet extends StatefulWidget {
  const LeaveComposerSheet({super.key});

  @override
  State<LeaveComposerSheet> createState() => _LeaveComposerSheetState();
}

class _LeaveComposerSheetState extends State<LeaveComposerSheet> {
  final _reason = TextEditingController();
  String _leaveType = 'annual';
  DateTime _start = DateTime.now().add(const Duration(days: 1));
  DateTime _end = DateTime.now().add(const Duration(days: 1));
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  double get _days => workingDays(_start, _end);

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _start : _end,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 400)),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _start = picked;
        if (_end.isBefore(_start)) _end = _start;
      } else {
        _end = picked;
        if (_end.isBefore(_start)) _start = _end;
      }
    });
  }

  Future<void> _submit() async {
    if (_days <= 0) {
      setState(
        () => _error = 'Select a range containing at least one weekday.',
      );
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'A reason is required for the approval chain.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final created = await LeaveService.instance.submitRequest(
        leaveType: _leaveType,
        startDate: _start,
        endDate: _end,
        reason: _reason.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Could not submit: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Request leave',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _leaveType,
              decoration: const InputDecoration(labelText: 'Leave type'),
              items: [
                for (final entry in leaveTypeLabels.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (v) => setState(() => _leaveType = v ?? 'annual'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _DateField(
                    label: 'From',
                    value: _start,
                    onTap: () => _pickDate(isStart: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DateField(
                    label: 'To',
                    value: _end,
                    onTap: () => _pickDate(isStart: false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              decoration: BoxDecoration(
                color: AppColors.accent(context).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.event_available_outlined,
                    size: 18,
                    color: AppColors.accent(context),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${_days.toStringAsFixed(_days % 1 == 0 ? 0 : 1)} '
                    'working day(s)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Briefly explain the request',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: AppColors.rose),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Submit for approval'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${value.year}-'
                '${value.month.toString().padLeft(2, '0')}-'
                '${value.day.toString().padLeft(2, '0')}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary(context),
                ),
              ),
            ),
            Icon(
              Icons.calendar_today_outlined,
              size: 15,
              color: AppColors.textTertiary(context),
            ),
          ],
        ),
      ),
    );
  }
}


/// Full detail for one request: approval trail (including any dates an
/// approver revised and every sign-off), PDF export, feedback, and the
/// approver decision actions when the signed-in user is eligible to act.
class LeaveDetailSheet extends StatefulWidget {
  const LeaveDetailSheet({
    super.key,
    required this.request,
    this.onChanged,
  });

  final LeaveRequest request;
  final Future<void> Function()? onChanged;

  @override
  State<LeaveDetailSheet> createState() => _LeaveDetailSheetState();
}

class _LeaveDetailSheetState extends State<LeaveDetailSheet> {
  List<LeaveApproval> _trail = const [];
  List<Map<String, String>> _chain = defaultApprovalChain;
  bool _loading = true;
  bool _busy = false;

  late final LeaveRequest _request = widget.request;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final trail = await LeaveService.instance.approvalsFor(_request.id);
    final chain = await LeaveService.instance.chainFor(_request.id);
    if (!mounted) return;
    setState(() {
      _trail = trail;
      _chain = chain;
      _loading = false;
    });
  }

  bool get _canDecide {
    final auth = AuthService.instance;
    return canActOnRequest(
      _request,
      _chain,
      userId: SupabaseService.client.auth.currentUser?.id,
      role: auth.role,
      isAdmin: auth.isAdmin,
    );
  }

  Future<void> _exportPdf() async {
    setState(() => _busy = true);
    final ok = await LeavePdf.share(
      request: _request,
      trail: _trail,
      chain: _chain,
    );
    if (mounted) {
      setState(() => _busy = false);
      if (!ok) {
        showSnack('Could not prepare the PDF on this device.', isError: true);
      }
    }
  }

  Future<void> _openFeedback() async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface(context),
      builder: (_) => _FeedbackSheet(requestId: _request.id),
    );
    if (sent == true && mounted) showSnack('Thank you — feedback recorded.');
  }

  Future<void> _decide(LeaveDecisionAction action) async {
    final result = await showModalBottomSheet<_DecisionResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface(context),
      builder: (_) => _DecisionSheet(action: action, request: _request),
    );
    if (result == null) return;
    setState(() => _busy = true);
    try {
      await LeaveService.instance.decide(
        requestId: _request.id,
        decision: action.decision,
        comment: result.comment,
        signatureName: result.signatureName,
        signaturePng: result.signaturePng,
        revisedStart: result.revisedStart,
        revisedEnd: result.revisedEnd,
        requestInfo: action == LeaveDecisionAction.requestInfo,
      );
      showSnack('Decision recorded and routed to the next approver.');
      await widget.onChanged?.call();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showSnack('Could not save the decision: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelOwn() async {
    setState(() => _busy = true);
    try {
      await LeaveService.instance.cancelRequest(_request.id);
      await widget.onChanged?.call();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showSnack('Could not cancel: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _request.label,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary(context),
                    ),
                  ),
                ),
                StatusBadge(
                  label: _titleCase(_request.status),
                  color: _statusColor(context, _request.status),
                ),
              ],
            ),
            const SizedBox(height: 12),
            InfoRow(
              label: 'Period',
              value: '${_request.startDate} → ${_request.endDate}',
            ),
            InfoRow(
              label: 'Working days',
              value: _request.days.toStringAsFixed(
                _request.days % 1 == 0 ? 0 : 1,
              ),
            ),
            if (_request.employeeName.trim().isNotEmpty)
              InfoRow(label: 'Employee', value: _request.employeeName),
            InfoRow(
              label: 'Current stage',
              value:
                  '${currentStage(_request, _chain)['label'] ?? ''}'
                  '${isFinalStage(_request, _chain) ? ' (final)' : ''}',
            ),
            if (_request.reason.trim().isNotEmpty)
              InfoRow(label: 'Reason', value: _request.reason),
            const SizedBox(height: 16),
            Text(
              'Approval trail',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_trail.isEmpty)
              Text(
                'No decisions recorded yet.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary(context),
                ),
              )
            else
              for (final approval in _trail)
                _TrailTile(
                  approval: approval,
                  fallbackStart: _request.startDate,
                  fallbackEnd: _request.endDate,
                ),
            const SizedBox(height: 18),
            if (_busy)
              const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              if (_request.isApproved)
                FilledButton.icon(
                  onPressed: _exportPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  label: const Text('Print / share approved PDF'),
                ),
              if (!_request.isPending)
                OutlinedButton.icon(
                  onPressed: _openFeedback,
                  icon: const Icon(Icons.rate_review_outlined, size: 18),
                  label: const Text('Give feedback'),
                ),
              if (_canDecide) ...[
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () => _decide(LeaveDecisionAction.approve),
                        child: const Text('Approve'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            _decide(LeaveDecisionAction.requestInfo),
                        child: const Text('Request info'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => _decide(LeaveDecisionAction.reject),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.rose,
                    side: const BorderSide(color: AppColors.rose),
                  ),
                  child: const Text('Reject'),
                ),
              ],
              if (_request.isPending &&
                  _request.createdBy ==
                      SupabaseService.client.auth.currentUser?.id)
                TextButton(
                  onPressed: _cancelOwn,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.rose,
                  ),
                  child: const Text('Cancel this request'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

Color _statusColor(BuildContext context, String status) {
  switch (status.toLowerCase()) {
    case 'approved':
      return AppColors.accent(context);
    case 'rejected':
      return AppColors.rose;
    case 'cancelled':
      return AppColors.textTertiary(context);
    default:
      return AppColors.amber;
  }
}


/// The three approver outcomes the web workflow supports.
enum LeaveDecisionAction {
  approve('approved', 'Approve', 'Signature authorises this stage.'),
  reject('rejected', 'Reject', 'Explain the reason for the rejection.'),
  requestInfo(
    'info_requested',
    'Request more information',
    'Tell the employee what is missing.',
  );

  const LeaveDecisionAction(this.decision, this.title, this.hint);

  final String decision;
  final String title;
  final String hint;
}

/// Outcome of the decision sheet — the payload handed to
/// `process_leave_decision`.
class _DecisionResult {
  const _DecisionResult({
    required this.comment,
    this.signatureName,
    this.signaturePng,
    this.revisedStart,
    this.revisedEnd,
  });

  final String comment;
  final String? signatureName;
  final Uint8List? signaturePng;
  final DateTime? revisedStart;
  final DateTime? revisedEnd;
}

/// One decision in the approval trail. Revised dates and the sign-off are
/// rendered inline so they remain visible through to the final approved
/// record, matching the web trail.
class _TrailTile extends StatelessWidget {
  const _TrailTile({
    required this.approval,
    required this.fallbackStart,
    required this.fallbackEnd,
  });

  final LeaveApproval approval;
  final String fallbackStart;
  final String fallbackEnd;

  @override
  Widget build(BuildContext context) {
    final approved = approval.decision.toLowerCase().contains('approv');
    final rejected = approval.decision.toLowerCase().contains('reject');
    final color = rejected
        ? AppColors.rose
        : approved
        ? AppColors.accent(context)
        : AppColors.amber;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                width: 2,
                height: 46,
                color: AppColors.border(context),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${approval.stageLabel.isEmpty ? approval.stageKey : approval.stageLabel}'
                  ' · ${approval.decision}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary(context),
                  ),
                ),
                if (approval.approverName.trim().isNotEmpty)
                  Text(
                    approval.approverName,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                if (approval.hasRevisedDates)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.amber.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Dates revised: '
                      '${approval.revisedStart.isEmpty ? fallbackStart : approval.revisedStart}'
                      ' → '
                      '${approval.revisedEnd.isEmpty ? fallbackEnd : approval.revisedEnd}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary(context),
                      ),
                    ),
                  ),
                if (approval.comment.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      approval.comment,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textSecondary(context),
                      ),
                    ),
                  ),
                if (approval.signature.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.draw_outlined,
                          size: 13,
                          color: AppColors.textTertiary(context),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            approval.signature.length > 40
                                ? 'Signed (captured signature)'
                                : 'Signed: ${approval.signature}',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontStyle: FontStyle.italic,
                              color: AppColors.textTertiary(context),
                            ),
                          ),
                        ),
                      ],
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


/// Approver decision capture: comment, optional revised dates, and a sign-off
/// by signature pad or typed name/initials.
class _DecisionSheet extends StatefulWidget {
  const _DecisionSheet({required this.action, required this.request});

  final LeaveDecisionAction action;
  final LeaveRequest request;

  @override
  State<_DecisionSheet> createState() => _DecisionSheetState();
}

class _DecisionSheetState extends State<_DecisionSheet> {
  final _comment = TextEditingController();
  final _typedName = TextEditingController();
  final _padKey = GlobalKey<SignaturePadState>();
  Uint8List? _signaturePng;
  bool _usePad = true;
  DateTime? _revisedStart;
  DateTime? _revisedEnd;

  @override
  void dispose() {
    _comment.dispose();
    _typedName.dispose();
    super.dispose();
  }

  Future<void> _pickRevised({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart
          ? (_revisedStart ?? DateTime.now())
          : (_revisedEnd ?? DateTime.now()),
      firstDate: DateTime.now().subtract(const Duration(days: 60)),
      lastDate: DateTime.now().add(const Duration(days: 400)),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _revisedStart = picked;
      } else {
        _revisedEnd = picked;
      }
    });
  }

  bool get _needsComment => widget.action != LeaveDecisionAction.approve;

  void _submit() {
    if (_needsComment && _comment.text.trim().isEmpty) {
      showSnack('A comment is required for this action.', isError: true);
      return;
    }
    final signaturePng = _usePad ? _signaturePng : null;
    final typed = _usePad ? null : _typedName.text.trim();
    if (widget.action != LeaveDecisionAction.requestInfo &&
        signaturePng == null &&
        (typed == null || typed.isEmpty)) {
      showSnack(
        'Capture a signature or type your name/initials to sign off.',
        isError: true,
      );
      return;
    }
    Navigator.of(context).pop(
      _DecisionResult(
        comment: _comment.text.trim(),
        signatureName: typed,
        signaturePng: signaturePng,
        revisedStart: _revisedStart,
        revisedEnd: _revisedEnd,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.action.title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.action.hint,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _comment,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: _needsComment
                    ? 'Comment (required)'
                    : 'Comment (optional)',
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Adjust dates (optional)',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Applied for ${widget.request.startDate} → '
              '${widget.request.endDate}. A new range here is recorded in the '
              'approval trail and stays visible on the final record.',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textTertiary(context),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _DateField(
                    label: 'New from',
                    value:
                        _revisedStart ?? _parseDate(widget.request.startDate),
                    onTap: () => _pickRevised(isStart: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DateField(
                    label: 'New to',
                    value: _revisedEnd ?? _parseDate(widget.request.endDate),
                    onTap: () => _pickRevised(isStart: false),
                  ),
                ),
              ],
            ),
            if (_revisedStart != null || _revisedEnd != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() {
                    _revisedStart = null;
                    _revisedEnd = null;
                  }),
                  child: const Text('Clear revised dates'),
                ),
              ),
            const SizedBox(height: 12),
            if (widget.action != LeaveDecisionAction.requestInfo) ...[
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('Signature pad')),
                  ButtonSegment(value: false, label: Text('Type name')),
                ],
                selected: {_usePad},
                onSelectionChanged: (s) => setState(() => _usePad = s.first),
              ),
              const SizedBox(height: 10),
              if (_usePad)
                Container(
                  height: 160,
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border(context)),
                    borderRadius: BorderRadius.circular(12),
                    color: AppColors.surface(context),
                  ),
                  child: SignaturePad(
                    key: _padKey,
                    onChanged: (bytes) => _signaturePng = bytes,
                  ),
                )
              else
                TextField(
                  controller: _typedName,
                  decoration: const InputDecoration(
                    labelText: 'Full name or initials',
                  ),
                ),
              const SizedBox(height: 16),
            ],
            FilledButton(
              onPressed: _submit,
              child: Text('Confirm ${widget.action.title.toLowerCase()}'),
            ),
          ],
        ),
      ),
    );
  }
}

DateTime _parseDate(String value) =>
    DateTime.tryParse(value) ?? DateTime.now();

/// Post-decision feedback, written through `submit_leave_feedback`.
class _FeedbackSheet extends StatefulWidget {
  const _FeedbackSheet({required this.requestId});

  final String requestId;

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  final _text = TextEditingController();
  int _turnaround = 4;
  int _ease = 4;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await LeaveService.instance.submitFeedback(
        requestId: widget.requestId,
        turnaroundRating: _turnaround,
        easeRating: _ease,
        feedbackText: _text.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack('Could not send feedback: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'How was the process?',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(height: 14),
            _RatingRow(
              label: 'Turnaround time',
              value: _turnaround,
              onChanged: (v) => setState(() => _turnaround = v),
            ),
            _RatingRow(
              label: 'Ease of requesting',
              value: _ease,
              onChanged: (v) => setState(() => _ease = v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Comments (optional)',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _send,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Send feedback'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary(context),
              ),
            ),
          ),
          for (var i = 1; i <= 5; i++)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => onChanged(i),
              icon: Icon(
                i <= value ? Icons.star : Icons.star_border,
                size: 20,
                color: AppColors.amber,
              ),
            ),
        ],
      ),
    );
  }
}

