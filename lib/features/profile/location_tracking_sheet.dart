// ============================================================================
// Location tracking consent (Phase 70)
// ============================================================================
// Location is NEVER collected silently. This sheet is shown BEFORE any
// permission prompt so the employee is told what it is for, how often it
// runs, who can see it, and how to turn it off - and can decline without any
// consequence to their attendance.
//
// Attendance works with while-in-use location only. The background heartbeat is
// strictly optional: declining it leaves clock-in/clock-out completely
// unaffected.
import 'package:flutter/material.dart';

import '../../core/services/location_heartbeat.dart';
import '../../core/theme/app_theme.dart';

class LocationTrackingSheet extends StatefulWidget {
  const LocationTrackingSheet({super.key});

  static Future<bool?> show(BuildContext context) => showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const LocationTrackingSheet(),
      );

  @override
  State<LocationTrackingSheet> createState() => _LocationTrackingSheetState();
}

class _LocationTrackingSheetState extends State<LocationTrackingSheet> {
  bool _busy = false;

  Future<void> _enable() async {
    setState(() => _busy = true);
    // The permission prompt only appears after the user has read and accepted
    // the explanation above.
    final granted = await LocationHeartbeat.instance.explainAndRequest();
    if (!mounted) return;
    setState(() => _busy = false);
    if (granted) {
      await LocationHeartbeat.instance.start();
    }
    if (mounted) Navigator.of(context).pop(granted);
  }

  Future<void> _disable() async {
    setState(() => _busy = true);
    await LocationHeartbeat.instance.stop();
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final hb = LocationHeartbeat.instance;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Location tracking',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              LocationHeartbeat.purposeMessage,
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 14),
            const _Point(
              icon: Icons.schedule_outlined,
              text: 'Records a position roughly every 30 minutes while you '
                  'are signed in and tracking is on. Your phone may record '
                  'it less often - the real time of every point is stored, '
                  'and nothing is ever filled in for a missed one.',
            ),
            const _Point(
              icon: Icons.admin_panel_settings_outlined,
              text: 'Only the Super Admin, and staff they explicitly grant '
                  'access to, can view your location history. Nobody else can, '
                  'including your manager.',
            ),
            const _Point(
              icon: Icons.fact_check_outlined,
              text: 'This is separate from attendance. Turning tracking off '
                  'does not affect clocking in or out.',
            ),
            const _Point(
              icon: Icons.schedule_outlined,
              text: 'You can turn it off at any time, here or from your '
                  'phone settings.',
            ),
            const SizedBox(height: 18),
            ValueListenableBuilder<HeartbeatStatus>(
              valueListenable: hb.status,
              builder: (_, status, _) {
                if (status.note != null || status.lastRecordedAt != null) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      status.summary,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textSecondary(context),
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _disable,
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _enable,
                    child: Text(_busy ? 'Starting...' : 'Turn on tracking'),
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

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: const Color(0xFF009944)),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: AppColors.textTertiary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
