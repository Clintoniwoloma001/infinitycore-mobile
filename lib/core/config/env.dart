import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// App configuration — remote Supabase project.
///
/// Public, client-safe values only. Never place service-role keys,
/// BankOne tokens, or other privileged secrets in this project.
///
/// Values are loaded from environment variables (flutter_dotenv on dev
/// machines) or passed as --dart-define at build time (CI / prod builds).
/// Defaults are the remote InfinityCore Supabase project.
class Env {
  Env._();

  /// Remote Supabase project reference.
  /// Override with --dart-define="SUPABASE_URL=https://your-project.supabase.co"
  static const _defaultSupabaseUrl = 'https://atzomqicwjufuxhfexxd.supabase.co';

  /// Remote Supabase anonymous (publishable) key.
  /// Override with --dart-define="SUPABASE_ANON_KEY=your_anon_key"
  static const _defaultSupabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF0em9tcWljd2p1ZnV4aGZleHhkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYxODU1MjQsImV4cCI6MjEwMTc2MTUyNH0.DsaPA-MJG0iO6ABw-oW1Dtg6910HVtpEBak4FdiXYIE';

  static String? get supabaseUrl {
    // --dart-define always wins (works in release APK with no .env)
    final define = const String.fromEnvironment('SUPABASE_URL');
    if (define.isNotEmpty) return define.trim();
    // Fall back to .env file (dev machines)
    return dotenv.env['SUPABASE_URL']?.trim().isNotEmpty == true
        ? dotenv.env['SUPABASE_URL']!.trim()
        : _defaultSupabaseUrl;
  }

  static String? get supabaseAnonKey {
    final define = const String.fromEnvironment('SUPABASE_ANON_KEY');
    if (define.isNotEmpty) return define.trim();
    return dotenv.env['SUPABASE_PUBLISHABLE_KEY']?.trim().isNotEmpty == true
        ? dotenv.env['SUPABASE_PUBLISHABLE_KEY']!.trim()
        : _defaultSupabaseAnonKey;
  }

  static String get appName => 'InfinityCore';

  /// Which AI model SARA is routed to (display pointer only).
  /// The authoritative model is resolved SERVER-SIDE by aiRouter.ts
  /// (OPENAI_MODEL function secret). The app never talks to the AI endpoint
  /// directly — all SARA calls go through the `sara-chat` Edge Function — so
  /// no base URL or auth token ever lives in this file or the app bundle.
  /// Override with --dart-define="OPENAI_MODEL=Jarvis".
  static String get aiModel {
    const define = String.fromEnvironment('OPENAI_MODEL');
    if (define.isNotEmpty) return define.trim();
    return dotenv.env['OPENAI_MODEL']?.trim().isNotEmpty == true
        ? dotenv.env['OPENAI_MODEL']!.trim()
        : 'Jarvis';
  }

  /// Public deployment origin used when encoding attendance-terminal QR codes.
  static String get terminalBaseUrl =>
      dotenv.env['TERMINAL_BASE_URL']?.trim().isNotEmpty == true
      ? dotenv.env['TERMINAL_BASE_URL']!.trim()
      : 'https://clintoniwoloma001.github.io/infinitycore-sara';

  static bool get isConfigured =>
      supabaseUrl != null && supabaseAnonKey != null;

  /// Hard guard: a release build must NEVER resolve Supabase to a local
  /// develop server (127.0.0.1 / localhost:54321). Local Supabase is only
  /// permitted in debug builds. Called once at startup; throws loudly instead
  /// of silently shipping a device build that talks to localhost.
  static void guardReleaseConfig() {
    if (!kReleaseMode) return;
    final url = supabaseUrl ?? '';
    var host = url.replaceFirst(RegExp(r'^https?://'), '');
    host = host.split('/').first.split(':').first.toLowerCase();
    if (host == '127.0.0.1' || host == 'localhost' || host.isEmpty) {
      throw StateError(
        'Fatal: this release build resolved a local Supabase URL "$url". '
        'Build with the remote project URL (https://<ref>.supabase.co).',
      );
    }
    final key = supabaseAnonKey ?? '';
    if (key.isEmpty) {
      throw StateError(
        'Fatal: this release build has no Supabase anon/publishable key.',
      );
    }
  }
}
