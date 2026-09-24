import 'package:flutter/foundation.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Non-blocking, fault-tolerant Shorebird OTA integration.
///
/// Runs only in release builds, only when the app was actually built with the
/// Shorebird engine (debug/web/local runs report `isAvailable == false`), and
/// swallows every failure so an update hiccup can never delay or crash app
/// startup.
class AppUpdates {
  AppUpdates._();

  static final AppUpdates instance = AppUpdates._();

  Future<void> checkForUpdates() async {
    if (!kReleaseMode) return;
    try {
      final updater = ShorebirdUpdater();
      if (!updater.isAvailable) return;
      final status = await updater.checkForUpdate();
      if (status == UpdateStatus.outdated) {
        // Downloads the patch; it is applied on the next app launch.
        await updater.update();
      }
    } catch (_) {
      // OTA is best-effort only. Never block the first frame for it.
    }
  }
}
