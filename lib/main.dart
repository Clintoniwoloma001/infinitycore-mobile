import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app/infinity_core_app.dart';
import 'core/config/env.dart';
import 'core/services/location_tracking_service.dart';
import 'core/services/notification_badge.dart';
import 'core/services/notification_service.dart';
import 'core/services/permission_service.dart';
import 'core/services/reminder_service.dart';
import 'core/services/supabase_service.dart';
import 'core/theme/theme_controller.dart';
import 'core/updates/app_updates.dart';
import 'features/messages/messaging_hub.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: '.env');

  if (!Env.isConfigured) {
    throw StateError(
      'Supabase configuration missing. Set SUPABASE_URL and '
      'SUPABASE_PUBLISHABLE_KEY in .env.',
    );
  }

  await SupabaseService.initialize();

  // Non-blocking update check; it must not delay the first frame.
  AppUpdates.instance.checkForUpdates();

  // Request runtime notification/exact-alarm access before reminders are
  // armed. Awaiting this keeps Android's first-launch prompt deterministic.
  await NotificationService.instance.requestPermissions();
  ReminderService.instance.start();

  // Web <-> mobile message sync. The hub owns a single Supabase Realtime
  // subscription for chat_messages, so it must be started once at app launch
  // (it is idempotent and safe to call again from a screen). It also restores
  // the offline outbox and keeps the unread badge current.
  MessagingHub.instance.start();

  // Header bell: unread official notifications, kept live alongside the
  // messaging hub's unread-message count.
  NotificationBadge.instance.start();

  await ThemeController.instance.load();

  // Background location is an automatic platform capability, not a Profile
  // setting: this starts it for an authenticated, eligible employee who has
  // already granted location permission, and keeps it correct across sign-in,
  // sign-out and foreground/background transitions. Non-blocking, and it never
  // raises a permission prompt on its own.
  unawaited(LocationTrackingService.instance.init());

  // Effective permissions drive every menu and guard on Android and iOS, from
  // the SAME backend document the web uses. Started here so the first frame
  // after sign-in already knows what the account may do, and kept subscribed
  // afterwards so a grant or revoke reaches the device without a re-login.
  PermissionService.instance.init();

  runApp(const InfinityCoreApp());
}
