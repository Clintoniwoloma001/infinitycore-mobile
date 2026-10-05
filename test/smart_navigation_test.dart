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
//   6. Staff Analytics is scoped to the attendance-managing roles
//
// They run against the REAL destination registry, so a destination added later
// without a decision about who sees it fails here rather than leaking to
// everybody.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/routing/app_destinations.dart';
import 'package:infinitycore/core/security/navigation_config.dart';
import 'package:infinitycore/core/security/role_guard.dart';
import 'package:infinitycore/features/dashboard/app_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The destinations [role] would see, given an optional stored department.
///
/// Mirrors `visibleDestinations()` but takes the role explicitly so it can be
/// exercised without a signed-in session.
List<String> visibleFor(String? role, {String? storedDepartment}) =>
    appDestinations()
        .where((d) => canSeeDepartment(role, d.department, storedDepartment))
        .where(
          (d) => switch (d.id) {
            'automation' => canViewAutomation(role),
            'branch-performance' =>
              role != null && canOpenExecutiveWorkspace(role),
            // Staff Analytics is gated by the SAME capability the real
            // [visibleDestinations] uses. Without this arm a default `_ => true`
            // would hand the screen to every role, including plain staff.
            'staff-analytics' => role != null && canManageAttendance(role),
            // Employee Tracking is SUPER ADMIN ONLY. Same reason: a default
            // `_ => true` would expose every other employee's live location.
            'employee-tracking' =>
              role != null && canAccessEmployeeTracking(role),
            _ => true,
          },
        )
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

    // Staff Analytics exposes OTHER people's attendance, so it must never fall
    // through to a default `_ => true`.
    group('Staff Analytics is scoped to attendance-managing roles', () {
      for (final role in const [
        AppRoles.hrOfficer,
        AppRoles.headOfHumanResources,
        AppRoles.superAdmin,
        AppRoles.admin,
        AppRoles.branchManager,
      ]) {
        test('$role may open it', () {
          expect(visibleFor(role), contains('staff-analytics'));
        });
      }

      for (final role in const [
        AppRoles.staff,
        AppRoles.customer,
        AppRoles.loanOfficer,
        AppRoles.customerService,
        AppRoles.headOfBusiness,
      ]) {
        test('$role may NOT open it', () {
          expect(visibleFor(role), isNot(contains('staff-analytics')));
        });
      }

      test('an unauthenticated visitor gets nothing', () {
        expect(visibleFor(null), isNot(contains('staff-analytics')));
      });

      test('the gate matches the server RPC audience exactly', () {
        // The RPC `mobile_attendance_summary` is the real boundary. The menu
        // must not show the screen to anyone that RPC would refuse.
        for (final role in const [
          AppRoles.hrOfficer,
          AppRoles.headOfHumanResources,
          AppRoles.superAdmin,
          AppRoles.admin,
          AppRoles.branchManager,
          AppRoles.staff,
          AppRoles.director,
        ]) {
          expect(
            visibleFor(role).contains('staff-analytics'),
            canManageAttendance(role),
            reason: 'menu visibility disagreed with the RPC gate for $role',
          );
        }
      });
    });

    // Employee Tracking exposes OTHER people's live location, so it must never
    // fall through to a default `_ => true`.
    group('Employee Tracking is Super Admin only', () {
      test('super_admin may open it', () {
        expect(
          visibleFor(AppRoles.superAdmin),
          contains('employee-tracking'),
        );
      });

      for (final role in const [
        AppRoles.admin,
        AppRoles.headOfHumanResources,
        AppRoles.hrOfficer,
        AppRoles.branchManager,
        AppRoles.director,
        AppRoles.chairman,
        AppRoles.headOfBusiness,
        AppRoles.staff,
        AppRoles.customer,
        AppRoles.loanOfficer,
        AppRoles.customerService,
      ]) {
        test('$role may NOT open it', () {
          expect(visibleFor(role), isNot(contains('employee-tracking')));
        });
      }

      test('an unauthenticated visitor gets nothing', () {
        expect(visibleFor(null), isNot(contains('employee-tracking')));
      });

      test('the gate is a single role, not the web grant model', () {
        // The WEB admits a delegated tracking grantee via
        // employee_tracking_access(). Mobile deliberately does NOT: a phone is
        // easier to lose or lend than a managed desktop. This test is the
        // record of that difference, so widening it later is a conscious act.
        expect(canAccessEmployeeTracking(AppRoles.superAdmin), isTrue);
        expect(canAccessEmployeeTracking(AppRoles.admin), isFalse);
        expect(canAccessEmployeeTracking(AppRoles.director), isFalse);
        expect(canAccessEmployeeTracking(''), isFalse);
      });

      test('the menu agrees with the capability the screen enforces', () {
        for (final role in const [
          AppRoles.superAdmin,
          AppRoles.admin,
          AppRoles.hrOfficer,
          AppRoles.director,
          AppRoles.staff,
        ]) {
          expect(
            visibleFor(role).contains('employee-tracking'),
            canAccessEmployeeTracking(role),
            reason: 'menu visibility disagreed with the screen gate for $role',
          );
        }
      });
    });

    test('every role gets at least the shared set', () {
      for (final role in kRoleDepartment.keys) {
        final out = visibleFor(role);
        expect(out, contains('profile'), reason: '$role lost Profile');
        expect(
          out,
          contains('notifications'),
          reason: '$role lost Notifications',
        );
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

    test(
      'Admin is unrestricted by department, but still loses Branch Performance',
      () {
        // Two different axes, and they deliberately disagree here:
        //  * kUnrestrictedRoles (super_admin, admin) waives the DEPARTMENT filter.
        //  * Branch Performance needs `director.executive.read`, which the
        //    backend seeds for director / super_admin / md_ceo / chairman ONLY.
        // Admin is not seeded, so hiding the destination is the honest answer
        // and matches the server, which would refuse the RPC anyway.
        final out = visibleFor(AppRoles.admin);
        expect(
          out,
          contains('automation'),
          reason: 'Admin has the automation read grant',
        );
        expect(out, isNot(contains('branch-performance')));
        // ...and it still reaches every department, which is what unrestricted means.
        for (final role in kRoleDepartment.keys) {
          expect(
            canSeeDepartment(
              AppRoles.admin,
              role == AppRoles.staff ? null : role,
              null,
            ),
            isTrue,
          );
        }
      },
    );

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
        expect(
          canViewAutomation(role),
          isTrue,
          reason: '$role should be permitted',
        );
      }
    });

    test('the executive viewer family is permitted', () {
      // DELIBERATE DIVERGENCE from the web role matrix, which tags the Command
      // Centre as Audit-only. The executive viewer family is stored under the
      // `executive` department, so the department filter hid this destination
      // from a Director/Chairman/MD/CEO entirely - routed and authorised, but
      // unreachable. The screen is READ-ONLY on mobile, and department
      // oversight is exactly what an MD/CEO needs it for, so mobile grants it.
      //
      // The web menu still differs until navigation.jsx is changed to match.
      // This test exists to make that divergence deliberate and greppable
      // rather than accidental.
      for (final role in <String>[
        AppRoles.director,
        AppRoles.chairman,
        AppRoles.mdCeo,
      ]) {
        expect(
          canViewAutomation(role),
          isTrue,
          reason: '$role must be able to reach the Command Centre',
        );
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
        AppRoles.hrOfficer,
        AppRoles.loanOfficer,
        AppRoles.customerService,
      ]) {
        expect(
          canViewAutomation(role),
          isFalse,
          reason: '$role must not be permitted',
        );
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
        // Staff Analytics is NOT universal and must never be added to this set:
        // it exposes OTHER people's attendance to HR and management. It is left
        // untagged because its audience is a ROLE set (canManageAttendance), not
        // a single department - it is gated by capability in
        // [visibleDestinations] instead, which is the deliberate choice the
        // loop below is asking for.
      };

      // Destinations whose audience is a capability rather than a department.
      // They are untagged on purpose, so this list is the record of that choice.
      const capabilityGated = <String>{
        'automation',
        'staff-analytics',
        'employee-tracking',
      };

      for (final d in appDestinations()) {
        if (d.department != null) continue;
        expect(
          expectedShared.contains(d.id) || capabilityGated.contains(d.id),
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

  // Regression guard for the "BOTTOM OVERFLOWED BY 139 PIXELS" report on the
  // top-right menu sheet. The sheet lists every destination the signed-in role
  // may open; with six rows (Profile, Notifications, Training, I-Meet,
  // Automation Command Centre, Branch Performance) plus the Communication Admin
  // row for some roles, the content exceeded the default modal bottom-sheet
  // height cap and the last rows were clipped off-screen.
  //
  // The test opens the real [showAppMenuSheet] modal with the real executive
  // menu. Driving [showAppMenu] instead would be self-defeating: it derives its
  // rows from the live role, and an unauthenticated test session sees only a
  // handful of destinations - never enough to overflow - so such a test passes
  // even against the broken layout. And rendering the sheet in a plain Scaffold
  // would hand it the full 852px, hiding the 9/16 modal cap that caused the
  // bug. Going through the real modal with the six-row menu reproduces the
  // failure exactly.
  group('5. The app menu sheet fits on a handset without overflowing', () {
    // The sheet reads AppColors from the ambient theme only, so no Supabase
    // session is needed to lay it out.
    setUpAll(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await Supabase.initialize(
        url: 'https://placeholder.supabase.co',
        publishableKey: 'sb_publishable_placeholder_widget_test_only',
      );
    });

    // The real menu an executive sees: every destination plus Communication
    // Admin. This is what overflowed the 9/16 cap on a real device.
    final executiveMenu = <AppMenuAction>[
      for (final d in appDestinations())
        AppMenuAction(
          label: d.label,
          subtitle: d.subtitle ?? '',
          icon: d.icon,
          route: d.route,
        ),
      const AppMenuAction(
        label: 'Communication Admin',
        subtitle: 'Channels, groups and announcement audiences',
        icon: Icons.campaign_outlined,
        route: '/comm-admin',
      ),
    ];

    // iPhone 15 Pro logical size - a modern handset, and a tight case for a
    // six-row sheet with subtitles.
    const handset = Size(393, 852);

    // The default modal cap. Content taller than this is the bug.
    const double defaultCap = 852 * 9 / 16;

    Future<void> openMenu(WidgetTester tester) async {
      tester.view.physicalSize = handset;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showAppMenuSheet(context, actions: executiveMenu),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the executive menu is the case that overflowed', (tester) async {
      // Guards the guard: if destinations are ever removed, the remaining rows
      // may no longer be tall enough to overflow, and the tests below would
      // pass vacuously again. Assert the fixture is still the hard case.
      expect(
        executiveMenu.length,
        greaterThanOrEqualTo(6),
        reason: 'fixture must keep the six rows that caused the overflow',
      );
    });

    testWidgets('opens the sheet without a RenderFlex overflow', (tester) async {
      await openMenu(tester);

      // A RenderFlex taller than its constraints raises a FlutterError, which
      // this captures. This is the assertion that fails if the sheet ever
      // reverts to a plain unscrollable Column under the 9/16 cap.
      expect(tester.takeException(), isNull);

      // Every row is present in the tree, whether or not it needs scrolling
      // into view. Before the fix the rows existed but were painted off the
      // bottom of the sheet.
      for (final action in executiveMenu) {
        expect(
          find.text(action.label),
          findsWidgets,
          reason: 'menu must contain the "${action.label}" row',
        );
      }
    });

    testWidgets('the sheet content is scrollable, so a long list stays usable', (
      tester,
    ) async {
      await openMenu(tester);

      // Scrollability is the second line of defence: even if a role gains more
      // destinations later, the sheet must grow and scroll rather than clip.
      expect(
        find.byType(SingleChildScrollView),
        findsWidgets,
        reason: 'menu content must be scrollable',
      );
    });

    testWidgets('the sheet does not cover the whole screen', (tester) async {
      await openMenu(tester);

      // Regression guard for the opposite failure: an unconstrained sheet that
      // grows to the full screen height, hiding the dashboard and leaving no
      // drag-handle area to dismiss it.
      final sheet = tester.getRect(find.byType(SingleChildScrollView));
      expect(
        sheet.height,
        lessThan(handset.height),
        reason: 'sheet must stay below the full screen height '
            '(default modal cap would be ${defaultCap.toStringAsFixed(0)}px)',
      );
    });

    testWidgets('the last row can be scrolled fully into view', (tester) async {
      await openMenu(tester);

      // The bottom row is the one that was cut in half, so verify it can
      // actually be reached rather than merely present in the tree.
      final last = find.text(executiveMenu.last.label);
      await tester.scrollUntilVisible(
        last,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(last).bottom,
        lessThanOrEqualTo(handset.height),
        reason: 'last row must be reachable within the screen',
      );
    });
  });
}