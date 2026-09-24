import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app/infinity_core_app.dart';
import 'core/config/env.dart';
import 'core/services/notification_service.dart';
import 'core/services/reminder_service.dart';
import 'core/services/supabase_service.dart';
import 'core/theme/theme_controller.dart';
import 'core/updates/app_updates.dart';

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

  // Non-blocking: never delays first frame; failures are swallowed.
  AppUpdates.instance.checkForUpdates();
  NotificationService.instance.requestPermissions();
  ReminderService.instance.start();

  await ThemeController.instance.load();

  runApp(const InfinityCoreApp());
}
