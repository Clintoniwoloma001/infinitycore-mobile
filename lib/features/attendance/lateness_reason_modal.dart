import 'package:flutter/material.dart';

import '../../core/routing/app_router.dart';
import '../../core/theme/app_theme.dart';
import 'lateness_service.dart';

/// The "You're late — why?" modal shown immediately after a late clock-in.
///
/// Non-dismissable by design: the existing late rule has already marked the
/// user late, and a reason that can be skipped is a reason nobody records. The
/// clock-in itself is already committed by the time this opens, so closing the
/// app (or the offline path) never loses the punch — only the reason, which is
/// queued locally and synced by [LatenessService.syncQueue].
class LatenessReasonModal extends StatefulWidget {
  const LatenessReasonModal({
    super.key,
    required this.minutesLate,
    required this.clockedInAt,
    this.attendanceId,
    this.branchId,
    this.branchName,
  });

  final int minutesLate;
  final DateTime clockedInAt;
  final String? attendanceId;
  final String? branchId;
  final String? branchName;

  /// Opens the modal and resolves once it has been submitted (or queued).
  static Future<bool> show(
    BuildContext context, {
    required int minutesLate,
    required DateTime clockedInAt,
    String? attendanceId,
    String? branchId,
    String? branchName,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      // Tapping the barrier or pressing Back must NOT dismiss: a reason is
      // mandatory.
      barrierDismissible: false,
      builder: (_) => LatenessReasonModal(
        minutesLate: minutesLate,
        clockedInAt: clockedInAt,
        attendanceId: attendanceId,
        branchId: branchId,
        branchName: branchName,
      ),
    );
    return result ?? false;
  }

  @override
  State<LatenessReasonModal> createState() => _LatenessReasonModalState();
}

class _LatenessReasonModalState extends State<LatenessReasonModal> {
  LatenessCategory? _category;
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final category = _category;
    if (category == null) {
      setState(() => _error = 'Please choose a reason.');
      return;
    }
    final text = _text.text.trim();
    // 'Others' MUST carry an explanation of at least 5 characters.
    if (category == LatenessCategory.others && text.length < 5) {
      setState(() => _error = 'Please describe the reason (at least 5 characters).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final queued = await LatenessService.instance.submit(
      minutesLate: widget.minutesLate,
      clockedInAt: widget.clockedInAt,
      attendanceId: widget.attendanceId,
      branchId: widget.branchId,
      branchName: widget.branchName,
      category: category,
      text: text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!queued) {
      // Offline (or a transient failure): the reason is queued on the device
      // and will sync. Treat it as done so the modal never blocks the user.
      showSnack(
        'Saved on this device — it will be sent when you are back online.',
      );
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.schedule,
                    color: AppColors.amber,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "You're late — why?",
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'You clocked in ${widget.minutesLate} minutes late. '
                'Please tell us why. This cannot be skipped.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary(context),
                ),
              ),
              const SizedBox(height: 12),
              RadioGroup<LatenessCategory>(
                groupValue: _category,
                onChanged: (value) {
                  if (_busy) return;
                  setState(() {
                    _category = value;
                    _error = null;
                  });
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final category in LatenessCategory.values)
                      RadioListTile<LatenessCategory>(
                        value: category,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(category.label),
                      ),
                  ],
                ),
              ),
              if (_category == LatenessCategory.others) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _text,
                  minLines: 2,
                  maxLines: 4,
                  enabled: !_busy,
                  onChanged: (_) => setState(() => _error = null),
                  decoration: const InputDecoration(
                    labelText: 'Please describe',
                    hintText: 'At least 5 characters',
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFB42318),
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Submit'),
              ),
              const SizedBox(height: 4),
              Text(
                'Your clock-in is already recorded; only this reason is '
                'required.',
                textAlign: TextAlign.center,
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
