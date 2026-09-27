// ============================================================================
// Phase 70 mobile - director experience + executive routing
// ============================================================================
// Pure/unit tests only. No Supabase session and no network.
import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/core/security/role_guard.dart';
import 'package:infinitycore/core/routing/auth_gate.dart';
import 'package:infinitycore/features/director/director_service.dart';

/// Minimal AuthGateState so the routing rules can be exercised directly.
class _Auth implements AuthGateState {
  _Auth({required this.status, required this.role});

  @override
  final AuthStatus status;
  @override
  final String role;
  @override
  final bool blockedByStatus = false;
  @override
  final bool biometricEnabled = false;
  @override
  bool get canManageAttendanceRole => false;
}

void main() {
  group('Director role catalog', () {
    test('director, chairman and md_ceo all resolve to the family', () {
      expect(AppRoles.isExecutiveViewer(AppRoles.director), isTrue);
      expect(AppRoles.isExecutiveViewer(AppRoles.chairman), isTrue);
      expect(AppRoles.isExecutiveViewer(AppRoles.mdCeo), isTrue);
    });

    test('no other role is an executive viewer', () {
      for (final r in [
        AppRoles.superAdmin,
        AppRoles.admin,
        AppRoles.staff,
        AppRoles.hrOfficer,
        AppRoles.headOfHumanResources,
        AppRoles.loanOfficer,
        AppRoles.branchManager,
        AppRoles.areaManager,
        AppRoles.customer,
      ]) {
        expect(AppRoles.isExecutiveViewer(r), isFalse,
            reason: '$r must not be an executive viewer');
      }
    });

    test('every role has a label and a hierarchy level', () {
      expect(AppRoles.label(AppRoles.director), 'Director');
      expect(AppRoles.label(AppRoles.chairman), 'Chairman');
      expect(AppRoles.label(AppRoles.mdCeo), 'MD/CEO');
      expect(AppRoles.hierarchy[AppRoles.director], isNotNull);
      expect(AppRoles.hierarchy[AppRoles.chairman], isNotNull);
      expect(AppRoles.hierarchy[AppRoles.mdCeo], isNotNull);
    });

    test('executive roles outrank normal management but not super admin', () {
      expect(AppRoles.hierarchy[AppRoles.director]!,
          greaterThan(AppRoles.hierarchy[AppRoles.areaManager]!));
      expect(AppRoles.hierarchy[AppRoles.director]!,
          lessThan(AppRoles.hierarchy[AppRoles.superAdmin]!));
      expect(AppRoles.hierarchy[AppRoles.mdCeo]!,
          lessThan(AppRoles.hierarchy[AppRoles.superAdmin]!));
      // Parity with the web catalog (src/constants/roles.js ROLE_HIERARCHY).
      expect(AppRoles.hierarchy[AppRoles.mdCeo], 98);
      expect(AppRoles.hierarchy[AppRoles.chairman], 96);
      expect(AppRoles.hierarchy[AppRoles.director], 95);
    });
  });

  group('Executive routing', () {
    String? decide(String role, String loc) => redirectDecision(
          _Auth(status: AuthStatus.authenticated, role: role),
          loc,
          Uri.parse(loc),
        );

    test('a director is sent to the executive workspace, not the staff home', () {
      expect(decide(AppRoles.director, '/home'), executiveRoute);
    });

    test('chairman and md_ceo get the same treatment as director', () {
      expect(decide(AppRoles.chairman, '/home'), executiveRoute);
      expect(decide(AppRoles.mdCeo, '/home'), executiveRoute);
    });

    test('a director may open the executive route directly', () {
      expect(decide(AppRoles.director, executiveRoute), isNull);
    });

    test('super admin keeps the normal home and may open the executive route', () {
      expect(decide(AppRoles.superAdmin, '/home'), isNull);
      expect(decide(AppRoles.superAdmin, executiveRoute), isNull);
    });

    test('ordinary roles are redirected away from the executive route', () {
      for (final r in [
        AppRoles.staff,
        AppRoles.hrOfficer,
        AppRoles.loanOfficer,
        AppRoles.branchManager,
        AppRoles.areaManager,
        AppRoles.customer
      ]) {
        expect(decide(r, executiveRoute), '/home',
            reason: '$r must not reach the executive workspace');
      }
    });

    test('ordinary roles keep the standard home', () {
      for (final r in [
        AppRoles.staff,
        AppRoles.hrOfficer,
        AppRoles.loanOfficer,
        AppRoles.branchManager,
        AppRoles.areaManager
      ]) {
        expect(decide(r, '/home'), isNull, reason: '$r keeps /home');
      }
    });

    test('an unauthenticated user never reaches the executive route', () {
      final decision = redirectDecision(
        _Auth(status: AuthStatus.unauthenticated, role: AppRoles.director),
        executiveRoute,
        Uri.parse(executiveRoute),
      );
      expect(decision, '/login');
    });
  });

  group('Presentation formatters never fabricate a value', () {
    test('percent renders null for missing input, not 0%', () {
      expect(percent(null), isNull);
      expect(percent(''), isNull);
      expect(percent(87.4), '87%');
      expect(percent(87.44, decimals: 1), '87.4%');
    });

    test('compactMoney renders null for missing input, not a zero value', () {
      expect(compactMoney(null), isNull);
      expect(compactMoney(42000000), '₦42.0M');
      expect(compactMoney(4200), '₦4.2k');
    });

    test('tenure is only rendered from a server-supplied tenure', () {
      // Nothing supplied: no figure is invented.
      expect(tenureLabel({'full_name': 'John'}), isNull);
      expect(
        tenureLabel({'tenure_years': 12, 'tenure_months': 4}),
        '12 years 4 months in the business',
      );
      expect(tenureLabel({'tenure_years': 7, 'tenure_months': 4}),
          '7 years 4 months in the business');
      expect(tenureLabel({'tenure_years': 1, 'tenure_months': 1}),
          '1 year 1 month in the business');
      expect(tenureLabel({'tenure_years': 0, 'tenure_months': 0}),
          'Less than a month in the business');
    });

    test('asList and asMap tolerate null and wrong shapes', () {
      expect(asList(null), isEmpty);
      expect(asList('nope'), isEmpty);
      expect(asList([1, 'x', {'a': 1}]).length, 1);
      expect(asMap(null), isEmpty);
      expect(asMap('nope'), isEmpty);
    });

    test('int and double parsing tolerate strings from jsonb', () {
      expect(asInt('42'), 42);
      expect(asInt(42.9), 42);
      expect(asInt('x'), isNull);
      expect(asDouble('42.5'), 42.5);
      expect(asDouble('x'), isNull);
    });
  });

  group('Period windows', () {
    test('today covers a single day', () {
      final p = DirectorPeriod.today();
      expect(p.from, p.to);
    });

    test('this week is seven days inclusive', () {
      final p = DirectorPeriod.thisWeek();
      expect(p.to.difference(p.from).inDays, 6);
    });

    test('this month ends on the last day of the month', () {
      final p = DirectorPeriod.thisMonth();
      expect(
        p.to.difference(p.from).inDays + 1,
        DateTime(p.to.year, p.to.month + 1, 0).day,
      );
    });

    test('this quarter spans roughly three months', () {
      final p = DirectorPeriod.thisQuarter();
      final days = p.to.difference(p.from).inDays + 1;
      expect(days, greaterThanOrEqualTo(89));
      expect(days, lessThanOrEqualTo(92));
    });

    test('iso dates are zero padded', () {
      expect(DirectorPeriod.toIso(DateTime(2026, 1, 5)), '2026-01-05');
      expect(DirectorPeriod.toIso(DateTime(2026, 12, 31)), '2026-12-31');
    });
  });
}
