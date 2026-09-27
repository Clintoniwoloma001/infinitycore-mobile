import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import 'urgent_ack_service.dart';

/// Records the acknowledgment for [item] and reports the outcome.
///
/// Kept outside the widget tree so the gate and any future inline prompt share
/// one code path. A failure is *not* treated as success: the caller stays
/// blocked so the client cannot claim compliance the server has not recorded.
Future<bool> confirmPendingAck(
  BuildContext context,
  PendingAck item,
) async {
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

/// Non-dismissible gate that blocks the app while a mandatory acknowledgment
/// is outstanding.
///
/// Enforcement is deliberately blunt: the barrier cannot be tapped away, the
/// back gesture is swallowed, and the only way out is the acknowledge button.
/// That is the whole product requirement — a user must not be able to scroll
/// past an urgent directive they have not confirmed.
///
/// A failed acknowledgment is *not* dismissible either. It leaves the user
/// blocked with a retry affordance, because a locally-faked "done" would
/// desynchronise the client from the server record the audit reads.
///
/// The gate is inserted into the app's [Overlay] rather than painted in a
/// `Stack` above the router. That is what makes the back button work: a
/// `PopScope` only registers with an enclosing [ModalRoute], and an
/// `OverlayEntry` is inside one while a widget above the `Navigator` is not.
///
/// Mount it once, above the router, so it also covers the splash → home
/// transition and any full-screen route pushed while an obligation is open.
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

  /// Inserts or removes the blocking overlay to match the pending queue.
  ///
  /// The entry is built with a `ValueListenableBuilder` rather than being torn
  /// down and rebuilt, so a mid-queue transition (acknowledging item 1 of 3)
  /// swaps the content in place instead of flashing.
  void _syncOverlay() {
    if (!mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    if (UrgentAckService.instance.hasPending) {
      _entry ??= OverlayEntry(
        builder: (context) => ValueListenableBuilder<List<PendingAck>>(
          valueListenable: UrgentAckService.instance.pending,
          builder: (context, items, _) {
            if (items.isEmpty) return const SizedBox.shrink();
            return _BlockingGate(
              item: _oldest(items),
              remaining: items.length,
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

  /// The oldest outstanding item, because a compliance queue is worked front to
  /// back. Mirrors `UrgentAckService.current` so the gate and the reminder
  /// notification always speak about the same message.
  static PendingAck _oldest(List<PendingAck> items) => items.reduce((a, b) {
    final ta = DateTime.tryParse(a.createdAt);
    final tb = DateTime.tryParse(b.createdAt);
    if (ta == null || tb == null) return a;
    return ta.isBefore(tb) ? a : b;
  });

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The full-screen blocking surface for a single [PendingAck].
class _BlockingGate extends StatelessWidget {
  const _BlockingGate({required this.item, required this.remaining});

  final PendingAck item;
  final int remaining;

  @override
  Widget build(BuildContext context) {
    final accent = item.isUrgent ? AppColors.rose : AppColors.orange;
    return PopScope(
      // Swallow the back gesture: leaving the gate is only possible by
      // acknowledging.
      canPop: false,
      child: Material(
        color: AppColors.surface(context),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          item.isUrgent
                              ? Icons.priority_high_rounded
                              : Icons.mark_email_unread_outlined,
                          size: 38,
                          color: accent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      item.isUrgent
                          ? 'Urgent — acknowledgement required'
                          : 'Acknowledgement required',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary(context),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Please read and confirm this message before continuing.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary(context),
                      ),
                    ),
                    const SizedBox(height: 22),
                    _MessageCard(item: item, accent: accent),
                    const SizedBox(height: 20),
                    _AcknowledgeButton(item: item, accent: accent),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: () => _openSource(context),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Open the full conversation'),
                    ),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      onPressed: () =>
                          UrgentAckService.instance.fireReminderNow(),
                      icon: const Icon(
                        Icons.notifications_active_outlined,
                        size: 18,
                      ),
                      label: const Text('Remind me again in 5 minutes'),
                    ),
                    if (remaining > 1) ...[
                      const SizedBox(height: 6),
                      Text(
                        // `remaining` counts the item on screen too, so the
                        // honest phrasing is "N more *after* this one".
                        '${remaining - 1} more message'
                        '${remaining - 1 == 1 ? '' : 's'} waiting after this one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textTertiary(context),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the source conversation. The gate stays mounted on top, so the user
  /// reads the message in context and then returns to confirm — which is
  /// exactly the review step the requirement asks for.
  void _openSource(BuildContext context) {
    if (item.route == '/messages') {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('This message is not in a conversation you can open.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    context.push(item.route);
  }
}

/// The message body inside the gate, tinted with the priority accent.
class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.item, required this.accent});

  final PendingAck item;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  item.priority.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            item.title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary(context),
            ),
          ),
          if (item.body.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              item.body,
              style: TextStyle(
                fontSize: 14,
                height: 1.4,
                color: AppColors.textPrimary(context),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 13,
                color: AppColors.iconMuted(context),
              ),
              const SizedBox(width: 4),
              Text(
                item.age.isEmpty ? 'Just now' : 'Sent ${item.age}',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.iconMuted(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The primary action, disabled and showing a spinner while the RPC is in
/// flight so a double-tap cannot create two acknowledgment records.
class _AcknowledgeButton extends StatelessWidget {
  const _AcknowledgeButton({required this.item, required this.accent});

  final PendingAck item;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: UrgentAckService.instance.acknowledging,
      builder: (context, busyId, _) {
        final busy = busyId == item.id;
        return FilledButton.icon(
          onPressed: busy ? null : () => confirmPendingAck(context, item),
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            disabledBackgroundColor: accent.withValues(alpha: 0.5),
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.done_all_rounded),
          label: Text(
            busy ? 'Recording your confirmation…' : 'I have read and acknowledge this',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
        );
      },
    );
  }
}
