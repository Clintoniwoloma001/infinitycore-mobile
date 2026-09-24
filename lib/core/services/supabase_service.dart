import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// Thin typed wrapper around the shared Supabase client.
///
/// Initialization happens once in `main()`. All repository/service code uses
/// [Supabase.instance.client] through these helpers. Nothing in this layer
/// holds privileged credentials.
class SupabaseService {
  SupabaseService._();

  static final SupabaseClient client = Supabase.instance.client;

  static Future<void> initialize() async {
    Env.guardReleaseConfig();
    await Supabase.initialize(
      url: Env.supabaseUrl!,
      publishableKey: Env.supabaseAnonKey!,
    );
  }

  static Future<Session?> currentSession() async {
    return client.auth.currentSession;
  }

  static String? get userId => client.auth.currentUser?.id;

  /// Invoke an edge function through the authenticated client, so RLS and
  /// authorization inside the function apply to the caller's session.
  static Future<dynamic> invokeFunction(
    String name, {
    Map<String, dynamic>? body,
  }) async {
    final response = await client.functions.invoke(name, body: body);
    return response.data;
  }

  static bool rpcMissing(Object? error) {
    final message = error.toString();
    return message.contains('PGRST202') ||
        message.contains('could not find the function') ||
        message.contains('schema cache');
  }
}

/// Best-effort audit log, mirroring the web `logAction` helper. The backend
/// audit tables remain authoritative; this only supplements them.
Future<void> logAction({
  required String action,
  String entityType = '',
  String entityId = '',
  String details = '',
  String severity = 'info',
}) async {
  try {
    final user = SupabaseService.client.auth.currentUser;
    await SupabaseService.client.from('audit_logs').insert({
      'action': action,
      'entity_type': entityType,
      'entity_id': entityId,
      'details': details,
      'severity': severity,
      'user_name': user?.email ?? '',
    });
  } catch (_) {
    // Best effort only.
  }
}
