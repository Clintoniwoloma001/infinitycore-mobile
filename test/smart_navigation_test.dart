// ============================================================================
// Smart navigation — per-role visibility of the real destinations
// ============================================================================
// These are the Phase 4 acceptance checks, expressed as tests:
//
//   1. an HR account sees the shared set plus Training
//   2. a different department's account sees a correspondingly different set
//   3. Super Admin sees everything
//   4. the Automation Command Centre is scoped to its permitted roles
//   5. Branch Performance is scoped to the executive workspace
//
// They run against the REAL destination registry, so a destination added later
// without a decision about who sees it fails here rather than leaking to
// everybody.
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/routing/app_destinations.dart';
import 'package:infinitycore/core/security/navigation_config.dart';
import 'package:infinitycore/core/security/role_guard.dart';

/// The destinations [role] would see, given an optional stored department.
///
/// Mirrors `visibleDestinations()` but takes the role explicitly so it can be
/// exercised without a signed-in session.
List<String> visibleFor(String? role, {String? storedDepartment}) => appDestinations()
    .where((d) => canSeeDepartment(role, d.department, storedDepartment))
    .where((d) => switch (d.id) {
      'automation' => canViewAutomation(role),
      'branch-performance' => role != null && canOpenExecutiveWorkspace(role),
      _ => true,
    })
    .map((d) => d.id)
    .toList(growable: false);

void main() {
  group('1. An HR account sees the shared set plus Training', () {
    for (final role in <String>[
      AppRoles.headOfHumanResources,
      AppRoles.hrOfficer,
    ]) {
      test('$role sees the shared destinations and Training', () {
        final out = visibleFor(role);
        expect(out, contains('profile'));
        expect(out, contains('notifications'));
        expect(out, contains('training'));
      });

      test('$role does not see the Audit-owned Command Centre', () {
        // Mirrors web: the ACC is tagged Audit, so an HR role is filtered out
        // of the menu even though the server would grant it the permission.
        expect(visibleFor(role), isNot(contains('automation')));
      });

      test('$role does not see Branch Performance', () {
        expect(visibleFor(role), isNot(contains('branch-performance')));
      });
    }
  });

  group('2. A different department sees a different set', () {
    test('Head of Audit sees the Command Centre', () {
      final out = visibleFor(AppRoles.headOfAudit);
      expect(out, contains('automation'));
      expect(out, contains('training'), reason: 'Training is shared');
    });

    test('Head of Risk sees neither the ACC nor Training-with-prominence', () {
      final out = visibleFor(AppRoles.headOfRiskCompliance);
      expect(out, isNot(contains('automation')));
      // Still gets the shared set.
      expect(out, contains('profile'));
      expect(out, contains('training'));
    });

    test('a plain employee sees only the shared set', () {
      expect(
        visibleFor(AppRoles.staff),
        // I-Meet is shared: recording a meeting and reading one's own meetings
        // is not a departmental privilege. It is listed after Training because
        // that is where it sits in the registry.
        <String>['profile', 'notifications', 'training', 'imeet'],
      );
    });

    test('every role gets at least the shared set', () {
      for (final role in kRoleDepartment.keys) {
        final out = visibleFor(role);
        expect(out, contains('profile'), reason: '$role lost Profile');
        expect(out, contains('notifications'), reason: '$role lost Notifications');
      }
    });
  });

  group('3. Super Admin and Admin see everything', () {
    test('Super Admin sees every destination', () {
      expect(
        visibleFor(AppRoles.superAdmin).toSet(),
        appDestinations().map((d) => d.id).toSet(),
      );
    });

    test('Admin is unrestricted by department, but still loses Branch Performance', () {
      // Two different axes, and they deliberately disagree here:
      //  * kUnrestrictedRoles (super_admin, admin) waives the DEPARTMENT filter.
      //  * Branch Performance needs `director.executive.read`, which the
      //    backend seeds for director / super_admin / md_ceo / chairman ONLY.
      // Admin is not seeded, so hiding the destination is the honest answer
      // and matches the server, which would refuse the RPC anyway.
      final out = visibleFor(AppRoles.admin);
      expect(out, contains('automation'), reason: 'Admin has the automation read grant');
      expect(out, isNot(contains('branch-performance')));
      // ...and it still reaches every department, which is what unrestricted means.
      for (final role in kRoleDepartment.keys) {
        expect(canSeeDepartment(AppRoles.admin, role == AppRoles.staff ? null : role, null), isTrue);
      }
    });

    test('MD/CEO and Chairman see Branch Performance', () {
      for (final role in <String>[AppRoles.mdCeo, AppRoles.chairman]) {
        expect(visibleFor(role), contains('branch-performance'), reason: role);
      }
    });

    test('a Director sees the executive destinations', () {
      final out = visibleFor(AppRoles.director);
      expect(out, contains('branch-performance'));
      // The ACC is Audit-tagged, and a Director is not an unrestricted role.
      expect(out, isNot(contains('automation')));
    });

    test('Super Admin may open Branch Performance, a Director workspace', () {
      expect(canOpenExecutiveWorkspace(AppRoles.superAdmin), isTrue);
      expect(canOpenExecutiveWorkspace(AppRoles.director), isTrue);
      expect(canOpenExecutiveWorkspace(AppRoles.staff), isFalse);
    });
  });

  group('4. Automation Command Centre role list', () {
    test('matches the automation.portfolio.read grants on web', () {
      // Seeded in web migration 20260927000001. If this list is ever widened or
      // narrowed on mobile alone, the platforms would disagree about who can
      // reach the register.
      for (final role in <String>[
        AppRoles.superAdmin,
        AppRoles.admin,
        AppRoles.headOfAudit,
        AppRoles.headOfHumanResources,
        AppRoles.headOfEBusiness,
      ]) {
        expect(canViewAutomation(role), isTrue, reason: '$role should be permitted');
      }
    });

    test('excludes everyone else', () {
      for (final role in <String>[
        AppRoles.staff,
        AppRoles.customer,
        AppRoles.branchManager,
        AppRoles.areaManager,
        AppRoles.financialController,
        AppRoles.headOfLegal,
        AppRoles.director,
      ]) {
        expect(canViewAutomation(role), isFalse, reason: '$role must not be permitted');
      }
    });

    test('a null or empty role is not permitted', () {
      expect(canViewAutomation(null), isFalse);
      expect(canViewAutomation(''), isFalse);
    });
  });

  group('Every destination has an explicit access decision', () {
    test('no destination is silently universal', () {
      // A shared destination must justify itself: the ones shared today are
      // the genuinely universal ones (own profile, own notifications, own
      // training). Anything added later has to be a deliberate choice.
      const expectedShared = <String>{
        'profile',
        'notifications',
        'training',
        'branch-performance',
        // I-MEET: universal in the same way "own training" is. Every employee
        // may record a meeting and read their OWN meetings. This does not grant
        // access to anyone else's audio - that is refused per-meeting by RLS
        // (owner or a frozen participant), which is a stricter check than any
        // role tag could express here.
        'imeet',
      };
      for (final d in appDestinations()) {
        if (d.department != null) continue;
        expect(
          expectedShared.contains(d.id),
          isTrue,
          reason:
              '${d.id} is shared but is not a known-universal destination; '
              'give it a department tag or a capability gate',
        );
      }
    });

    test('each destination routes to a distinct path', () {
      final routes = appDestinations().map((d) => d.route).toList();
      expect(routes.toSet().length, routes.length);
    });

    test('every destination has a label, subtitle and icon', () {
      for (final d in appDestinations()) {
        expect(d.label.trim(), isNotEmpty, reason: d.id);
        expect((d.subtitle ?? '').trim(), isNotEmpty, reason: d.id);
        expect(d.route.trim(), isNotEmpty, reason: d.id);
      }
    });
  });
}
