import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app/infinity_core_app.dart';
import 'core/config/env.dart';
import 'core/services/location_heartbeat.dart';
import 'core/services/notification_badge.dart';
import 'core/services/notification_service.dart';
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

  // Resume background location tracking only if the employee previously gave
  // consent on this device. Non-blocking, and it re-checks the session first so
  // a signed-out device never records coordinates.
  unawaited(LocationHeartbeat.instance.restoreIfEnabled());

  runApp(const InfinityCoreApp());
}
