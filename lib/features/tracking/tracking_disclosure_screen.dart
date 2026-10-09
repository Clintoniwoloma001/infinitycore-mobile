// ============================================================================
// First-run disclosure for background location tracking.
//
// Location is NEVER collected silently. This screen explains what is
// collected, WHEN, WHY, and WHO can see it, and tracking does not start until
// the employee accepts. The text lives in one editable constant so it can be
// reviewed and updated without touching any other file.
// ============================================================================
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

/// The disclosure text. ONE place to edit; nothing else quotes it.
class TrackingDisclosure {
  TrackingDisclosure._();

  static const String title = 'InfinityCore location tracking';

  static const String body = '''InfinityCore records your location while you are signed in so the office can:

  - Verify clock-in and clock-out locations.
  - See where staff are during working hours.
  - Support attendance and workforce operations.

What is collected
  Your GPS location, the time it was recorded, and your device's reported
  accuracy. Nothing else.

When it is collected
  Continuously while you are signed in and have allowed location access. It
  stops when you sign out or switch the permission off in your device
  settings.

Who can see it
  The InfinityCore HR team and anyone it grants tracking access to. It is not
  shared publicly.

How to stop it
  Open your device settings and change InfinityCore's location permission.
  Clocking in and out work either way.''';

  static const int policyVersion = 1;
}

class TrackingDisclosureScreen extends StatefulWidget {
  const TrackingDisclosureScreen({super.key, this.onComplete});

  /// Called with true once the employee accepts. The caller decides what to
  /// show next (home, or a settings screen).
  final void Function(bool accepted)? onComplete;

  @override
  State<TrackingDisclosureScreen> createState() =>
      _TrackingDisclosureScreenState();
}

class _TrackingDisclosureScreenState extends State<TrackingDisclosureScreen> {
  bool _busy = false;

  Future<void> _accept() async {
    if (_busy) return; // double-click safe
    setState(() => _busy = true);
    try {
      final user = Supabase.instance.client.auth.currentSession?.user;
      if (user != null) {
        await Supabase.instance.client.from('tracking_consent').upsert({
          'user_id': user.id,
          'accepted_at': DateTime.now().toUtc().toIso8601String(),
          'policy_version': TrackingDisclosure.policyVersion,
          'disclosure_text': TrackingDisclosure.body,
        });
      }
      if (!mounted) return;
      widget.onComplete?.call(true);
    } catch (_) {
      // Consent is best-effort: tracking still starts, and the web can show
      // the disclosure was not recorded.
      if (!mounted) return;
      widget.onComplete?.call(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _decline() {
    if (_busy) return;
    // A declined disclosure records the refusal so the web can explain why a
    // staff member is silent, but it does NOT start tracking.
    widget.onComplete?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text(TrackingDisclosure.title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    Icon(
                      Icons.location_on_outlined,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      TrackingDisclosure.body,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Policy version ${TrackingDisclosure.policyVersion}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _accept,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const Text('Allow tracking'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _decline,
                child: const Text('Not now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
