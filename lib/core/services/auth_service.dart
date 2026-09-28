import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/models/models.dart';
import '../diagnostics/auth_trace.dart';
import '../routing/auth_gate.dart';
import '../security/role_guard.dart';
import 'mobile_session_service.dart';
import 'supabase_service.dart';

/// Authentication + authorization state.
///
/// The Supabase session is the authoritative identity; the `profiles` row
/// holds the role. Client-side role logic is UI convenience only — backend
/// RLS and role checks remain authoritative.
///
/// ## Why the state machine is explicit
///
/// The app used to expose `isAuthenticated` straight off the raw session, and
/// the router only "held in place" while that session settled. Two independent
/// things then decided navigation (the guard *and* the login screen), and two
/// independent settle pipelines could run for one sign-in — so the faster one
/// opened the gate while the slower one (which actually owned the
/// mobile-device check) was still in flight. If that slower pipeline rejected
/// the device, the session was torn down *after* Home had already rendered:
/// the "login succeeds, shows Home, reverts to Login" bounce.
///
/// The fixes, in order of importance:
///
///  1. [isAuthenticated] is true only for a **resolved** session
///     ([AuthStatus.authenticated]), never for a session that is merely
///     present.
///  2. Exactly **one** settle pipeline exists per session, keyed by user id.
///     Concurrent callers (the auth-state stream and `signIn`) *join* it
///     instead of racing it, so nothing can open the gate early.
///  3. A pipeline may only publish its result if it still owns the current
///     generation; one overtaken by sign-out can no longer reopen the gate.
///  4. Navigation has a single authority — the router guard in
///     `auth_gate.dart`. Screens no longer navigate on auth changes.
class AuthService extends ChangeNotifier implements AuthGateState {
  AuthService._() {
    _init();
  }

  static final AuthService instance = AuthService._();

  static const _storage = FlutterSecureStorage();
  static const _biometricKey = 'infinitycore.biometric_enabled';

  Session? _session;
  Profile? _profile;
  bool _initialized = false;
  bool _biometricEnabled = false;
  StreamSubscription<AuthState>? _subscription;

  /// Explicit resolution state. Only [_commit] may move this out of
  /// [AuthStatus.resolving].
  AuthStatus _status = AuthStatus.unknown;

  /// Incremented on every sign-out so a pipeline that started earlier can never
  /// publish a verdict for a session that no longer exists.
  int _generation = 0;

  /// The one in-flight settle pipeline per user id. A second caller joins this
  /// future rather than starting a parallel pipeline.
  final Map<String, Future<void>> _settles = <String, Future<void>>{};

  /// The user id the current [AuthStatus.authenticated] verdict belongs to.
  String? _resolvedUserId;

  Session? get session => _session;
  Profile? get profile => _profile;

  @override
  AuthStatus get status => _status;

  /// True once the auth decision is definitive (either way).
  bool get isResolved =>
      _status == AuthStatus.authenticated ||
      _status == AuthStatus.unauthenticated;

  /// Back-compat alias: "a verdict has been assigned at least once".
  bool get ready => _status != AuthStatus.unknown;

  bool get initialized => _initialized;

  /// True only for a session that has been fully resolved (profile loaded and
  /// the mobile-device check passed). Deliberately NOT
  /// `_session?.user != null`: navigation must never act on a raw session.
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  /// Whether the post-sign-in pipeline is still running. Kept for callers that
  /// want a spinner; navigation no longer depends on it.
  bool get sessionSettled => _status != AuthStatus.resolving;

  @override
  bool get biometricEnabled => _biometricEnabled;

  @override
  String get role => _profile?.role ?? '';

  /// The employee's free-text department, used ONLY to refine the role->department
  /// mapping for navigation. It is never an authority: a value here can add
  /// nothing the role does not already permit beyond a genuinely matching
  /// department key. See `navigation_config.dart`.
  String get department => _profile?.department ?? '';

  AccessProfile get access =>
      buildAccess(_profile ?? Profile(id: _session?.user.id ?? ''), null);

  @override
  bool get canManageAttendanceRole =>
      isAuthenticated && canManageAttendance(_profile?.role ?? '');

  String get displayName => _profile?.fullName.isEmpty == false
      ? _profile!.fullName
      : (_session?.user.email?.split('@').first ?? 'User');

  String get email => _session?.user.email ?? '';

  bool get isAdmin {
    final r = _profile?.role;
    return r == AppRoles.admin || r == AppRoles.superAdmin;
  }

  bool get isHR {
    final r = _profile?.role;
    return r == AppRoles.headOfHumanResources || r == AppRoles.hrOfficer;
  }

  bool get isManager {
    final r = _profile?.role;
    return r == AppRoles.branchManager ||
        r == AppRoles.headOfOperations ||
        r == AppRoles.headOfEBusiness ||
        r == AppRoles.headOfBusiness;
  }

  @override
  bool get blockedByStatus {
    final s = _profile?.status ?? 'active';
    return s != 'active' && s != 'inactive'; // inactive keeps read access
  }

  // ---------------------------------------------------------------------------
  // Auth-state stream — never navigates, only records and starts/joins settles.
  // ---------------------------------------------------------------------------
  void _init() {
    _subscription = SupabaseService.client.auth.onAuthStateChange.listen((
      data,
    ) {
      final hadSession = _session?.user != null;
      final event = data.event;
      AuthTrace.log(
        'auth.event',
        'event=${event.name} incomingUser=${data.session?.user.id ?? 'null'} '
            'hadSession=$hadSession status=${_status.name}',
      );

      // A stale delayed `initialSession` (null) arriving after a real sign-in
      // must never clobber an established session. Only an explicit signedOut
      // tears the session down.
      if (hadSession &&
          data.session?.user == null &&
          event != AuthChangeEvent.signedOut) {
        AuthTrace.log('auth.event', 'IGNORED stale null-session event=$event');
        return;
      }

      final user = data.session?.user;
      _session = data.session;
      if (user != null) {
        if (_resolvedUserId != user.id) _profile = null;
        // Start (or join) the single settle pipeline for this user. The gate
        // stays closed until that pipeline publishes in _commit().
        unawaited(_ensureSettled(user.id).catchError((Object _) {}));
      } else {
        _profile = null;
        _resolvedUserId = null;
        _status = AuthStatus.unauthenticated;
        AuthTrace.log('auth.gate', 'RESOLVED unauthenticated (no session)');
      }
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // The single settle pipeline.
  // ---------------------------------------------------------------------------

  /// Runs the pipeline for [userId] once and lets concurrent callers join it.
  ///
  /// The join is what makes the gate trustworthy: there is no second pipeline
  /// able to finish early and publish `authenticated` before the
  /// mobile-device check has actually completed.
  Future<void> _ensureSettled(String userId) {
    final existing = _settles[userId];
    if (existing != null) {
      AuthTrace.log('auth.settle', 'JOIN in-flight pipeline for $userId');
      return existing;
    }
    // Already resolved for this exact session — re-settling would flip the
    // gate back to `resolving` and briefly bounce a user who is on Home.
    if (_status == AuthStatus.authenticated && _resolvedUserId == userId) {
      AuthTrace.log('auth.settle', 'SKIP — already resolved for $userId');
      return Future<void>.value();
    }

    final generation = _generation;
    _status = AuthStatus.resolving;
    _profile = null;
    AuthTrace.log(
      'auth.gate',
      'RESOLVING generation=$generation user=$userId — Home not reachable',
    );
    notifyListeners();

    final future = _runSettle(userId, generation).whenComplete(() {
      _settles.remove(userId);
    });
    _settles[userId] = future;
    return future;
  }

  Future<void> _runSettle(String userId, int generation) async {
    var rejected = false;
    AuthTrace.log('auth.settle', 'START generation=$generation user=$userId');
    try {
      try {
        await _loadProfile(userId);
        await MobileSessionService.instance.initialize();
        AuthTrace.log(
          'auth.settle',
          'mobile-device check COMPLETED (generation=$generation)',
        );
      } on Exception catch (e) {
        final message = e.toString();
        AuthTrace.log('auth.settle', 'check THREW: $message');
        if (message.contains('MOBILE_UNAUTHORIZED_DEVICE:')) {
          rejected = true;
          await signOut();
          throw StateError(
            'This account is already linked to another mobile device. '
            'Please contact HR or Super Admin to authorize this device.',
          );
        }
        // A mobile-session plumbing failure (function not migrated, web-only
        // platform limit, transient network error) must never tear down an
        // otherwise valid login. Fall back to the legacy flow.
        debugPrint('MobileSessionService init failed (fallback): $e');
      }
    } finally {
      _commit(generation, rejected: rejected);
    }
  }

  /// Publishes the resolution — but only if this pipeline still owns the
  /// current generation. A pipeline overtaken by a sign-out must never publish;
  /// that stale write is what used to re-open the gate and flash Home.
  void _commit(int generation, {required bool rejected}) {
    if (generation != _generation) {
      AuthTrace.log(
        'auth.gate',
        'STALE pipeline generation=$generation ignored (current=$_generation)',
      );
      return;
    }
    final userId = _session?.user.id;
    final ok = userId != null && !rejected;
    _status = ok ? AuthStatus.authenticated : AuthStatus.unauthenticated;
    _resolvedUserId = ok ? userId : null;
    AuthTrace.log(
      'auth.gate',
      'RESOLVED status=${_status.name} generation=$generation '
          'rejected=$rejected userId=${userId ?? 'null'}',
    );
    notifyListeners();
  }

  Future<void> _loadProfile(String userId) async {
    try {
      final res = await SupabaseService.client
          .from('profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();
      _profile = Profile.fromJson(res as dynamic);
    } catch (e) {
      AuthTrace.log('profile', 'load FAILED for $userId (using fallback): $e');
      _profile = Profile(id: userId, email: email);
    }
    AuthTrace.log(
      'profile',
      'loaded for $userId role=${_profile?.role} status=${_profile?.status}',
    );
  }

  /// Resolve the persisted session (if any) exactly once, on first launch.
  ///
  /// With no persisted session this publishes [AuthStatus.unauthenticated]
  /// synchronously — Login is then the only destination, and Home is never
  /// rendered speculatively.
  Future<void> bootstrap() async {
    _initialized = true;
    _session = SupabaseService.client.auth.currentSession;
    final user = _session?.user;
    AuthTrace.log(
      'bootstrap',
      'START persistedSession=${user?.id ?? 'null'} status=${_status.name}',
    );

    if (user == null) {
      _resolvedUserId = null;
      _status = AuthStatus.unauthenticated;
      AuthTrace.log('bootstrap', 'no persisted session -> unauthenticated');
    } else {
      try {
        await _ensureSettled(user.id);
      } on StateError {
        // Unauthorized device — signOut() already resolved to unauthenticated.
      }
    }

    _biometricEnabled = await _readBiometric();
    AuthTrace.log(
      'bootstrap',
      'END status=${_status.name} isAuthenticated=$isAuthenticated '
          'biometric=$_biometricEnabled',
    );
    notifyListeners();
  }

  Future<bool> _readBiometric() async {
    try {
      final v = await _storage.read(key: _biometricKey);
      return v == '1';
    } catch (_) {
      return false;
    }
  }

  /// Sign in and **wait for the mobile-device check to resolve**.
  ///
  /// The auth-state stream fires `signedIn` while `signInWithPassword` is still
  /// running, so this call normally *joins* the pipeline that event started.
  /// Either way exactly one pipeline runs, and the navigation gate stays closed
  /// until it publishes — Home cannot appear before the verdict is real.
  ///
  /// Throws [StateError] when the account is bound to another device (the
  /// session is torn down first) so the login screen can surface it.
  Future<AuthResponse> signIn(String email, String password) async {
    AuthTrace.log('signIn', 'START email=${email.trim()}');
    final res = await SupabaseService.client.auth
        .signInWithPassword(email: email.trim(), password: password)
        .timeout(const Duration(seconds: 25));
    final user = res.user;
    AuthTrace.log(
      'signIn',
      'response user=${user?.id ?? 'null'} status=${_status.name}',
    );
    if (user != null) {
      await _ensureSettled(user.id);
    }
    return res;
  }

  /// Tear the session down and invalidate any in-flight pipeline.
  Future<void> signOut() async {
    AuthTrace.log('signOut', 'START generation=$_generation');
    // Bump first: any pipeline still running is now stale and cannot publish an
    // `authenticated` verdict for the session we are discarding.
    _generation++;
    _settles.clear();
    _resolvedUserId = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();

    // NOTE: the device binding is NOT released here. The device stays bound
    // to this account across sign-outs so a different account cannot be
    // signed in on it; only HR/Super Admin can unbind (server-enforced).
    await MobileSessionService.instance.revoke();
    await SupabaseService.client.auth.signOut();
    _session = null;
    _profile = null;
    AuthTrace.log(
      'signOut',
      'END session=null status=${_status.name} generation=$_generation',
    );
    notifyListeners();
  }

  Future<void> setBiometricEnabled(bool value) async {
    _biometricEnabled = value;
    try {
      await _storage.write(key: _biometricKey, value: value ? '1' : '0');
    } catch (_) {}
    notifyListeners();
  }
}
