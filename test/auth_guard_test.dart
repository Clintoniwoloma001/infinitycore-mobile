import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/routing/auth_gate.dart';
import 'package:infinitycore/core/security/role_guard.dart';

/// Minimal stand-in for [AuthGateState] so every guard branch can be exercised
/// without a live Supabase session or a running router.
class _FakeAuth implements AuthGateState {
  _FakeAuth({
    required this.status,
    this.blockedByStatus = false,
    this.canManageAttendanceRole = false,
    this.biometricEnabled = false,
    this.role = AppRoles.staff,
  });

  @override
  final AuthStatus status;
  @override
  final bool blockedByStatus;
  @override
  final bool canManageAttendanceRole;
  @override
  final bool biometricEnabled;
  @override
  final String role;
}

String? _decide(_FakeAuth auth, String loc, {String query = ''}) =>
    redirectDecision(auth, loc, Uri.parse('$loc$query'));

/// Every route the app registers, used by the exhaustive invariant tests.
const _allRoutes = <String>[
  '/splash',
  '/login',
  '/activate-account',
  '/blocked',
  '/lock',
  '/home',
  '/attendance-terminal',
  '/attendance-management',
  '/profile',
  '/bound-devices',
  '/geofences',
];

void main() {
  group('auth guard — the login bounce-back regression', () {
    // This is the exact failure that was reported as fixed once and then
    // reproduced: Home was rendered on the strength of a session that existed
    // but had NOT been resolved (the mobile-device check was still in flight).
    // The old guard returned `null` ("hold in place") whenever a session
    // existed but had not settled, so a premature navigation to /home STAYED
    // on screen — and when the device check then rejected the device, the app
    // bounced back to Login.
    test('an unresolved session may never remain on Home', () {
      for (final status in const [AuthStatus.unknown, AuthStatus.resolving]) {
        expect(
          _decide(_FakeAuth(status: status), '/home'),
          loadingRoute,
          reason: '$status must never leave Home on screen',
        );
      }
    });

    test('an unresolved session may never remain on any protected route', () {
      const protectedRoutes = [
        '/home',
        '/blocked',
        '/lock',
        '/attendance-management',
        '/profile',
        '/bound-devices',
        '/geofences',
      ];
      for (final status in const [AuthStatus.unknown, AuthStatus.resolving]) {
        for (final route in protectedRoutes) {
          expect(
            _decide(_FakeAuth(status: status), route),
            loadingRoute,
            reason: '$status + $route must park on the loading screen',
          );
        }
      }
    });

    test(
      'the neutral loading screen and public routes are always reachable',
      () {
        for (final status in AuthStatus.values) {
          expect(
            _decide(_FakeAuth(status: status), '/splash'),
            anyOf(isNull, '/home', '/lock', '/login'),
          );
          expect(
            _decide(_FakeAuth(status: status), '/login'),
            anyOf(isNull, '/home'),
          );
        }
      },
    );

    test('first-ever launch with no session resolves to Login, never Home', () {
      // unknown = nothing read yet
      expect(
        _decide(_FakeAuth(status: AuthStatus.unknown), '/home'),
        '/splash',
      );
      // bootstrap() with no persisted session publishes unauthenticated
      expect(
        _decide(_FakeAuth(status: AuthStatus.unauthenticated), '/home'),
        '/login',
      );
      expect(
        _decide(_FakeAuth(status: AuthStatus.unauthenticated), '/splash'),
        '/login',
      );
    });

    test('a resolved session is sent to Home from the loading screen', () {
      final auth = _FakeAuth(status: AuthStatus.authenticated);
      expect(_decide(auth, '/splash'), '/home');
      expect(_decide(auth, '/login'), '/home');
    });

    test('biometric users land on the quick-unlock screen, not Home', () {
      final auth = _FakeAuth(
        status: AuthStatus.authenticated,
        biometricEnabled: true,
      );
      expect(_decide(auth, '/splash'), '/lock');
      expect(_decide(auth, '/lock'), isNull);
    });

    test('the quick-unlock screen is skipped when biometrics are off', () {
      final auth = _FakeAuth(status: AuthStatus.authenticated);
      expect(_decide(auth, '/lock'), '/home');
    });
  });

  group('auth guard — role and status gating', () {
    test('blocked accounts are parked on the blocked screen', () {
      final auth = _FakeAuth(
        status: AuthStatus.authenticated,
        blockedByStatus: true,
      );
      expect(_decide(auth, '/home'), '/blocked');
      expect(_decide(auth, '/blocked'), isNull);
      expect(_decide(auth, '/profile'), '/blocked');
    });

    test('attendance management is role-gated', () {
      expect(
        _decide(
          _FakeAuth(
            status: AuthStatus.authenticated,
            canManageAttendanceRole: true,
          ),
          '/attendance-management',
        ),
        isNull,
      );
      expect(
        _decide(
          _FakeAuth(status: AuthStatus.authenticated),
          '/attendance-management',
        ),
        '/home',
      );
    });

    test('bound-devices is restricted to Super Admin / Head of HR', () {
      for (final role in const [
        AppRoles.superAdmin,
        AppRoles.headOfHumanResources,
      ]) {
        expect(
          _decide(
            _FakeAuth(status: AuthStatus.authenticated, role: role),
            '/bound-devices',
          ),
          isNull,
        );
      }
      for (final role in const [
        AppRoles.staff,
        AppRoles.branchManager,
        AppRoles.hrOfficer,
      ]) {
        expect(
          _decide(
            _FakeAuth(status: AuthStatus.authenticated, role: role),
            '/bound-devices',
          ),
          '/home',
        );
      }
    });

    test('geofence settings is restricted to Super Admin / Head of HR', () {
      // Same audience as /bound-devices and as the server's
      // `is_geofence_admin()`. `hr_manager` is the legacy spelling of the Head
      // of HR role and is accepted for the same rename-tolerance reason the
      // database helper accepts it.
      for (final role in const [
        AppRoles.superAdmin,
        AppRoles.headOfHumanResources,
        AppRoles.hrManager,
      ]) {
        expect(
          _decide(
            _FakeAuth(status: AuthStatus.authenticated, role: role),
            '/geofences',
          ),
          isNull,
          reason: '$role must reach geofence settings',
        );
      }
      for (final role in const [
        AppRoles.staff,
        AppRoles.branchManager,
        AppRoles.hrOfficer,
        AppRoles.admin,
        AppRoles.director,
        AppRoles.customer,
      ]) {
        expect(
          _decide(
            _FakeAuth(status: AuthStatus.authenticated, role: role),
            '/geofences',
          ),
          '/home',
          reason: '$role must be redirected away from geofence settings',
        );
      }
    });
  });

  group('auth guard — public attendance terminal is never gated', () {
    test('a tokened terminal stays reachable in every auth state', () {
      for (final status in AuthStatus.values) {
        expect(
          _decide(
            _FakeAuth(status: status),
            '/attendance-terminal',
            query: '?token=abc123',
          ),
          isNull,
          reason: '$status must not force a login on the kiosk flow',
        );
      }
    });

    test('a tokened terminal stays reachable even for a blocked account', () {
      expect(
        _decide(
          _FakeAuth(status: AuthStatus.authenticated, blockedByStatus: true),
          '/attendance-terminal',
          query: '?token=abc123',
        ),
        isNull,
      );
    });

    test('an untokened terminal follows normal gating', () {
      expect(
        _decide(
          _FakeAuth(status: AuthStatus.unauthenticated),
          '/attendance-terminal',
        ),
        '/login',
      );
    });
  });

  group('auth guard — exhaustive invariants over every route', () {
    test('no route can render a protected screen while unresolved', () {
      for (final status in const [AuthStatus.unknown, AuthStatus.resolving]) {
        for (final route in _allRoutes) {
          final decision = _decide(_FakeAuth(status: status), route);
          final isPublic = publicRoutes.any(route.startsWith);
          if (route == loadingRoute || isPublic) {
            expect(decision, isNull, reason: '$status + $route');
          } else {
            expect(
              decision,
              loadingRoute,
              reason:
                  '$status + $route must go to $loadingRoute, got $decision',
            );
          }
        }
      }
    });

    test('an unauthenticated user can never be sent anywhere but Login', () {
      for (final route in _allRoutes) {
        final decision = _decide(
          _FakeAuth(status: AuthStatus.unauthenticated),
          route,
        );
        final isPublic = publicRoutes.any(route.startsWith);
        if (route == loadingRoute || !isPublic) {
          expect(decision, '/login', reason: route);
        } else {
          expect(decision, isNull, reason: route);
        }
      }
    });

    test('an authenticated user is never parked on the loading screen', () {
      for (final route in _allRoutes) {
        final decision = _decide(
          _FakeAuth(
            status: AuthStatus.authenticated,
            role: AppRoles.superAdmin,
          ),
          route,
        );
        expect(decision, isNot(loadingRoute), reason: route);
      }
    });
  });
}
