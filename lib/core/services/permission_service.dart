// ============================================================================
// PermissionService — the ONE effective-permission source on mobile
// ============================================================================
// WHY THIS FILE EXISTS
// Android, iOS and the web had no shared notion of "what may this account do".
// The web read `get_my_permissions()`; Flutter consulted `RoleGuard`, a local
// role→module table. That is the same split-brain that made the web menu lie:
// two clients, two answers, and a grant made in Access Control was invisible on
// the phone.
//
// This service closes that gap by asking the SAME database document the web menu
// and the backend ask for. There is no second permission system here: no local
// role matrix, no hard-coded menu map, no per-widget overrides.
//
// PRECEDENCE (identical to the web, see src/config/accessControl.js and
// public._permission_state):
//   1. super admin     -> everything
//   2. explicit DENY   -> denied     (beats every allow below)
//   3. explicit ALLOW  -> allowed
//   4. no entry        -> denied
// The database already resolves all of that; this class only transports the
// answer and never re-derives it.
//
// FAIL CLOSED. If the document cannot be fetched, `has` returns false rather
// than optimistically allowing. A client that cannot prove authorisation must
// not proceed — the backend would refuse anyway, and a menu that flashes
// restricted items before the error is worse than one that stays closed.
//
// BACKEND IS STILL AUTHORITATIVE. This is a UX and defence-in-depth layer.
// Hiding a menu item does not protect the data: RLS and the RPC layer are.
import 'dart:async';

import 'package:flutter/widgets.dart';
// Imported unfiltered: `postgresChanges` is an extension method on
// RealtimeChannel, so a `show` clause would hide it and the subscription would
// not compile.
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'supabase_service.dart';

/// The caller's effective permission document, as returned by
/// `get_my_permissions()`.
@immutable
class EffectivePermissions {
  const EffectivePermissions({
    this.allowed = const {},
    this.denied = const {},
    this.isSuperUser = false,
    this.epoch,
    this.loaded = false,
    this.error,
  });

  final Set<String> allowed;
  final Set<String> denied;
  final bool isSuperUser;

  /// Server-side version of this document. A change here is what makes a
  /// realtime refresh authoritative rather than heuristic.
  final int? epoch;

  /// False while the first fetch is in flight, so callers can distinguish
  /// "not allowed" from "not known yet" and avoid a false denial flash.
  final bool loaded;

  final String? error;

  /// Deterministic precedence, mirroring the database.
  bool has(String key) {
    if (isSuperUser) return true;
    if (denied.contains(key)) return false; // deny wins
    return allowed.contains(key);
  }

  /// True when the account holds ANY of [keys] — the same "any of" rule the web
  /// route guard uses for a menu entry listing several permissions.
  bool hasAny(Iterable<String> keys) {
    if (isSuperUser) return true;
    return keys.any(has);
  }

  /// True only when EVERY key is held. For pages that need full access, not
  /// just visibility.
  bool hasAll(Iterable<String> keys) => keys.every(has);

  /// The subset this account can actually see, for building a menu.
  Set<String> visibleFrom(Iterable<String> keys) => keys.where(has).toSet();
}

class PermissionService with WidgetsBindingObserver {
  PermissionService._();

  static final instance = PermissionService._();

  /// The single observable the whole app reads. No screen keeps its own copy,
  /// because a second copy is exactly how a stale permission survives a
  /// revocation.
  final ValueNotifier<EffectivePermissions> current =
      ValueNotifier<EffectivePermissions>(const EffectivePermissions());

  bool _started = false;
  String? _forUserId;

  void init() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    AuthService.instance.addListener(_onAuthChanged);
    final uid = SupabaseService.userId;
    if (uid != null) {
      startRealtime(uid);
      unawaited(refresh(uid));
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AuthService.instance.removeListener(_onAuthChanged);
    stopRealtime();
  }

  void _onAuthChanged() {
    final uid = SupabaseService.userId;
    if (uid == null) {
      // Signed out: clear immediately so no permission outlives the session.
      _forUserId = null;
      stopRealtime();
      current.value = const EffectivePermissions();
      return;
    }
    if (uid != _forUserId) {
      startRealtime(uid);
      unawaited(refresh(uid));
    }
  }

  /// Re-read the document from the backend.
  ///
  /// Always fetches rather than patching a local copy, so the app can never
  /// hold a permission the server has since revoked.
  Future<EffectivePermissions> refresh([String? userId]) async {
    final uid = userId ?? SupabaseService.userId;
    if (uid == null) {
      current.value = const EffectivePermissions();
      return current.value;
    }
    try {
      final res = await SupabaseService.client.rpc('get_my_permissions');
      final data = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map)
          : const <String, dynamic>{};
      _forUserId = uid;
      current.value = EffectivePermissions(
        allowed: _keys(data['allowed']),
        denied: _keys(data['denied']),
        isSuperUser: data['is_super_user'] == true,
        epoch: data['epoch'] is int ? data['epoch'] as int : null,
        loaded: true,
      );
    } catch (e) {
      // Fail closed, but say why: a screen can show "still loading" or an error
      // instead of pretending the account is simply not permitted.
      current.value = EffectivePermissions(loaded: true, error: '$e');
    }
    return current.value;
  }

  static Set<String> _keys(dynamic raw) {
    if (raw is Map) return raw.keys.map((k) => '$k').toSet();
    if (raw is List) return raw.map((k) => '$k').toSet();
    return const {};
  }

  // --- Convenience predicates. Screens ask these; they never ask the DB. ---

  bool can(String key) => current.value.has(key);
  bool canAny(List<String> keys) => current.value.hasAny(keys);
  bool canAll(List<String> keys) => current.value.hasAll(keys);
  bool get isSuperAdmin => current.value.isSuperUser;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground is the one moment a permission can have
    // changed without us hearing about it (a revoked app, a slept device, a
    // dropped realtime socket). Cheap to re-check, and it is what makes a
    // fresh launch and a resume behave identically.
    if (state == AppLifecycleState.resumed) {
      final uid = SupabaseService.userId;
      if (uid != null) unawaited(refresh(uid));
    }
  }

  // -------------------------------------------------------------------------
  // LIVE PROPAGATION
  // -------------------------------------------------------------------------
  // Mirrors the web: a Super Admin's grant must reach the phone without the
  // employee signing out and back in.
  //
  // The tables are in the `supabase_realtime` publication (migration
  // 20260931000006). Before that, the subscription had nothing to deliver, which
  // is why a mobile user had to fully restart the app to pick up a change.
  //
  // `user_permissions` is filtered to this user — a broadcast of every other
  // employee's grant would be both a privacy leak and pointless traffic. Role
  // changes cannot be filtered the same way (the row has no user id), so those
  // are unfiltered and simply cause a re-read of the caller's own document.
  void startRealtime(String userId) {
    stopRealtime();
    _channel = SupabaseService.client
        .channel('mobile-permissions:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_permissions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => unawaited(refresh(userId)),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'role_permissions',
          callback: (_) => unawaited(refresh(userId)),
        )
        .subscribe();
  }

  void stopRealtime() {
    if (_channel == null) return;
    SupabaseService.client.removeChannel(_channel!);
    _channel = null;
  }

  RealtimeChannel? _channel;
}
