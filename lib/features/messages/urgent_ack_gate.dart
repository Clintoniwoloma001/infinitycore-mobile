import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import 'urgent_ack_service.dart';

/// Records the acknowledgment for [item] and reports the outcome.
///
/// Kept outside the widget tree so the gate and any future inline prompt share
/// one code path. A failure is *not* treated as success: the caller stays
/// blocked so the client cannot claim compliance the server has not recorded.
Future<bool> confirmPendingAck(BuildContext context, PendingAck item) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ok = await UrgentAckService.instance.acknowledge(item);
  if (!context.mounted || ok) return ok;
  messenger?.showSnackBar(
    SnackBar(
      content: const Text(
        'Your confirmation could not be saved. '
        'Check your connection and try again.',
      ),
      behavior: SnackBarBehavior.floating,
    ),
  );
  return false;
}

/// Hosts the global acknowledgement reminder.
///
/// A BANNER, not a modal. The previous implementation froze the app behind an
/// undismissable barrier, which contradicted two requirements: a sender must
/// never be blocked (point 1), and the reminder must be dismissible while still
/// resurfacing until acknowledged (point 8). The banner sits above every route,
/// so the obligation is visible on Dashboard, Attendance, Leave, Employees and
/// Messages alike (point 7).
///
/// The obligation is still not optional: the five-minute reminder notification
/// keeps firing and the banner returns after every dismissal, so ignoring it
/// never clears anything. Only a successful server write does.
///
/// The banner is inserted into the app's [Overlay] rather than painted in a
/// `Stack` above the router, so it also covers the splash → home transition and
/// any route pushed while an obligation is open.
///
/// Mount it once, above the router.
class UrgentAckGate extends StatefulWidget {
  const UrgentAckGate({super.key, required this.child});

  final Widget child;

  @override
  State<UrgentAckGate> createState() => _UrgentAckGateState();
}

class _UrgentAckGateState extends State<UrgentAckGate> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    // Starting here rather than in a service constructor means the first query
    // runs only once a real frame tree exists, so `WidgetsBinding` is safe.
    UrgentAckService.instance.start();
    UrgentAckService.instance.pending.addListener(_syncOverlay);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncOverlay());
  }

  @override
  void dispose() {
    UrgentAckService.instance.pending.removeListener(_syncOverlay);
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  /// Inserts or removes the banner overlay to match the pending queue.
  ///
  /// The entry is built with a `ValueListenableBuilder` rather than being torn
  /// down and rebuilt, so a mid-queue transition (acknowledging item 1 of 3)
  /// swaps the content in place instead of flashing.
  ///
  /// A BANNER, not a modal: the obligation must be visible on every screen
  /// (point 7) without freezing the app (point 1), and it must be dismissible
  /// while still resurfacing (point 8).
  void _syncOverlay() {
    if (!mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    if (UrgentAckService.instance.hasPending) {
      _entry ??= OverlayEntry(
        builder: (context) => ValueListenableBuilder<List<PendingAck>>(
          valueListenable: UrgentAckService.instance.pending,
          builder: (context, items, _) {
            // Honour an active dismissal. The service re-arms a timer, so the
            // banner reappears on its own after exactly the dismiss window.
            final visible = UrgentAckService.instance.visible(items);
            if (visible == null) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.topCenter,
              child: SafeArea(
                bottom: false,
                child: AckReminderBanner(item: visible),
              ),
            );
          },
        ),
      );
      if (_entry!.mounted) return;
      overlay.insert(_entry!);
      return;
    }
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Small, non-blocking acknowledgment banner (points 7/8).
///
/// This replaces the previous full-screen modal, which froze the entire app
/// until the user acknowledged. Two requirements forced the change: a sender
/// must never be blocked (point 1), and the reminder must be dismissible while
/// still resurfacing until acknowledged (point 8). A modal could satisfy
/// neither without also trapping users who are only trying to read something
/// else.
///
/// Dismissal is NOT acknowledgment. It is recorded with a timestamp and the
/// banner returns after exactly [resurfaceAfter], repeating until the server
/// record for that message reads 'acknowledged'. The dismissal lives in the
/// service (not the widget) so it survives a rebuild, a tab switch and a
/// restart.
class AckReminderBanner extends StatefulWidget {
  const AckReminderBanner({super.key, required this.item});

  final PendingAck item;

  /// Exactly five minutes, per the product spec.
  static const resurfaceAfter = Duration(minutes: 5);

  @override
  State<AckReminderBanner> createState() => _AckReminderBannerState();
}

class _AckReminderBannerState extends State<AckReminderBanner> {
  bool _busy = false;

  Future<void> _acknowledge() async {
    setState(() => _busy = true);
    final ok = await UrgentAckService.instance.acknowledge(widget.item);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) return;
    // A failed write leaves the obligation standing. Saying so matters: a
    // locally-faked "done" would desync from the record an audit reads.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Your confirmation could not be saved. '
          'Check your connection and try again.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _openSource(BuildContext context) {
    if (widget.item.route == '/messages') {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('This message is not in a conversation you can open.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    context.push(widget.item.route);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final accent = item.isUrgent ? AppColors.rose : AppColors.orange;
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              item.isUrgent
                  ? Icons.priority_high_rounded
                  : Icons.mark_email_unread_outlined,
              size: 20,
              color: accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.isUrgent
                        ? 'URGENT MESSAGE — acknowledgement required'
                        : 'IMPORTANT MESSAGE — acknowledgement required',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary(context),
                    ),
                  ),
                  if (item.body.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary(context),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : _acknowledge,
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                        ),
                        child: Text(
                          _busy ? 'Saving…' : 'Acknowledge',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () => _openSource(context),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                        ),
                        child: const Text(
                          'View',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => UrgentAckService.instance.dismissUntil(
                item.id,
                AckReminderBanner.resurfaceAfter,
              ),
              tooltip: 'Hide for 5 minutes (this does not acknowledge)',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.close,
                size: 18,
                color: AppColors.textTertiary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
