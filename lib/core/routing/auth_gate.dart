import '../security/role_guard.dart';

/// How far the app has got in deciding whether the user is signed in.
///
/// The distinction between [unknown]/[resolving] and [authenticated] is the
/// entire point of this file: *a session existing* is NOT the same thing as
/// *a session being resolved* (profile loaded + mobile-device check finished).
/// Only a resolved, valid session may render Home. The previous bounce-back
/// bug came from treating the raw session as good enough to navigate on.
enum AuthStatus {
  /// Nothing has been read yet — the first frame after process start.
  unknown,

  /// A session exists and the post-sign-in pipeline (profile load +
  /// mobile-device check) is still running.
  resolving,

  /// Resolved: the session exists and passed the device check.
  authenticated,

  /// Resolved with no usable session (never signed in, signed out, or the
  /// device check rejected it).
  unauthenticated,
}

/// The read-only slice of auth state the router needs.
///
/// Kept as a narrow interface instead of reading the auth service directly, so
/// the guard below is a pure function that can be unit-tested against every
/// state/route combination without a live Supabase session.
abstract class AuthGateState {
  AuthStatus get status;
  bool get blockedByStatus;
  bool get canManageAttendanceRole;
  bool get biometricEnabled;
  String get role;
}

/// Routes reachable without a resolved session.
const List<String> publicRoutes = <String>[
  '/login',
  '/activate-account',
  '/certificate-verify',
];

/// The neutral loading route. It is the app's `initialLocation` and the only
/// place the guard parks an unresolved user.
const String loadingRoute = '/splash';

/// The single navigation authority for authentication.
///
/// Returns the location the router must move to, or `null` to stay put.
///
/// Invariant enforced here — this *is* the login bounce-back fix:
///
/// > While the auth state is unresolved ([AuthStatus.unknown] or
/// > [AuthStatus.resolving]) the user may only be on [loadingRoute] or a
/// > public route. Any protected route (notably `/home`) is redirected **back
/// > to** [loadingRoute] rather than being left in place.
///
/// The old guard returned `null` ("hold in place") whenever a session existed
/// but had not settled. On `/login` that was harmless, but if any other code
/// path had already navigated to `/home`, `null` meant "Home stays on screen"
/// — so a session that later failed the mobile-device check produced
/// Home-then-bounce. Redirecting to the loading route instead makes that
/// window impossible to observe: there is no state in which Home is rendered
/// on a partially-resolved read.
String? redirectDecision(AuthGateState auth, String loc, Uri uri) {
  final isLoading = loc == loadingRoute;
  final isPublic = publicRoutes.any(loc.startsWith);

  // The public attendance terminal (token in the query) is a kiosk flow and
  // must never be forced through an InfinityCore login.
  final isPublicTerminal =
      loc.startsWith('/attendance-terminal') &&
      uri.queryParameters.containsKey('token');
  if (isPublicTerminal) return null;

  switch (auth.status) {
    case AuthStatus.unknown:
    case AuthStatus.resolving:
      // Not resolved: only the neutral loading screen and public routes are
      // permitted. Everything else goes back to the loading screen.
      if (isLoading || isPublic) return null;
      return loadingRoute;

    case AuthStatus.unauthenticated:
      // Resolved with no session: Login is the only destination.
      if (isPublic) return null;
      return '/login';

    case AuthStatus.authenticated:
      break; // resolved and valid — fall through to the route rules below
  }

  if (isLoading) return auth.biometricEnabled ? '/lock' : '/home';
  if (loc == '/login') return '/home';

  // Status-blocked accounts are parked on the blocked screen (sign-out is
  // offered there). Inactive accounts keep read access.
  if (auth.blockedByStatus && loc != '/blocked') return '/blocked';

  // Quick-unlock is only meaningful when biometrics are enabled.
  if (loc == '/lock' && !auth.biometricEnabled) return '/home';

  // ---- Executive workspace (Phase 70) -------------------------------------
  // The director family (Director / Chairman / MD-CEO) uses this as its HOME
  // experience and never sees the standard staff dashboard. Super Admin keeps
  // its own experience and can also open the executive workspace.
  //
  // Hiding the nav entry is not the control: this redirect runs before the
  // screen mounts, so deep-linking or editing a route cannot reach executive
  // data. The authoritative check remains the role gate inside
  // get_director_executive_snapshot on the server.
  final onExecutiveRoute = loc == executiveRoute;
  final wantsExecutiveHome = loc == '/home' && usesExecutiveWorkspace(auth.role);

  if (onExecutiveRoute && !canOpenExecutiveWorkspace(auth.role)) {
    return '/home';
  }
  if (wantsExecutiveHome) {
    return executiveRoute;
  }

  // Attendance management is role-gated (the server also enforces this).
  if (loc == '/attendance-management' && !auth.canManageAttendanceRole) {
    return '/home';
  }

  // Bound-device management is restricted to Super Admin / Head of HR.
  if (loc == '/bound-devices' &&
      auth.role != AppRoles.superAdmin &&
      auth.role != AppRoles.headOfHumanResources) {
    return '/home';
  }

  // Communication Administration is restricted to the same roles as the web
  // Comm Admin page (mirrored by `canAccessCommAdmin`). Hiding the nav entry
  // is not enough — an unauthorized user who deep-links here is redirected
  // away before any screen mounts and before any query runs. The authoritative
  // check remains `public.is_communication_admin()` in Postgres.
  if (loc.startsWith('/comm-admin') && !canAccessCommAdmin(auth.role)) {
    return '/home';
  }

  return null;
}
