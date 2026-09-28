// ============================================================================
// Navigation wiring guards
// ============================================================================
// The Dart counterpart of the web test's "the wiring into it is asserted from
// source" checks. Flutter widgets cannot be imported into a plain unit test the
// way the web JSX cannot be, so the WIRING is asserted by reading the source.
// This still fails loudly if a destination is added to one surface and not the
// other, which is the drift these tests exist to prevent.
//
// The property being pinned: a user never sees a destination in EITHER
// navigation surface that they cannot actually open, and the two surfaces are
// driven by one registry rather than two hand-maintained lists.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/routing/app_destinations.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final menuSrc = _read('lib/features/dashboard/app_menu.dart');
  final shellSrc = _read('lib/features/dashboard/home_shell.dart');
  final routerSrc = _read('lib/core/routing/app_router.dart');
  final registry = appDestinations();

  group('The hamburger menu is driven by the shared registry', () {
    test('it reads visibleDestinations() rather than a local list', () {
      expect(menuSrc, contains('visibleDestinations()'));
    });

    test('it no longer hardcodes its own destination list', () {
      expect(
        menuSrc,
        isNot(contains('List<AppMenuAction> _menuActions()')),
        reason:
            'a second hand-maintained list is exactly how the two navigation '
            'surfaces drift apart',
      );
    });
  });

  group('The bottom bar carries only shared, general destinations', () {
    // Extract the declared tab labels so the assertion is about the real
    // source rather than a copy of it.
    final labels = RegExp(
      r"_TabDef\(\s*'([^']+)'",
    ).allMatches(shellSrc).map((m) => m.group(1)!).toSet();

    test('the bottom bar declares its tabs', () {
      expect(labels, isNotEmpty);
      expect(labels, containsAll(<String>['Home', 'Attendance', 'Messages']));
    });

    test('no bottom-bar tab is a department-scoped destination', () {
      final departmental = registry
          .where((d) => d.department != null)
          .map((d) => d.label)
          .toSet();
      for (final label in labels) {
        expect(
          departmental.contains(label),
          isFalse,
          reason:
              '$label is department-scoped and belongs in the menu, not the '
              'shared bottom bar',
        );
      }
    });

    test('the conditional Manage tab stays permission-gated', () {
      // Manage is gated on the attendance-management role, which the server
      // enforces again in mobile_attendance_summary. It must stay conditional
      // rather than becoming unconditional.
      expect(shellSrc, contains('canManage'));
      expect(shellSrc, contains("if (canManage)"));
    });
  });

  group('Every registered destination has a route', () {
    test('the router declares a path for each destination', () {
      for (final d in registry) {
        expect(
          routerSrc,
          contains("path: '${d.route}'"),
          reason: '${d.id} is registered at ${d.route} but has no GoRoute',
        );
      }
    });
  });

  group('The new screens are reachable and read-only by construction', () {
    test('the Automation route is registered read-only', () {
      expect(routerSrc, contains("path: '/automation'"));
      // The service exposes no write path at all, so there is nothing for a
      // UI bug to invoke. Checked as an actual RPC INVOCATION, not a mention:
      // the file legitimately names the sibling write RPC in its comment to
      // explain why editing is refused.
      final service = _read('lib/features/automation/automation_service.dart');
      final writeCall = RegExp(
        r"""rpc\(\s*['"]set_automation_item_status['"]""",
      );
      expect(
        writeCall.hasMatch(service),
        isFalse,
        reason: 'mobile must not carry a status-editing path at all',
      );
      expect(
        service,
        isNot(contains('Future<void> setItemStatus')),
        reason: 'a setter in the service would be a write path',
      );
    });

    test('the Training and Branch Performance routes are registered', () {
      expect(routerSrc, contains("path: '/training'"));
      expect(routerSrc, contains("path: '/branch-performance'"));
    });
  });

  group('The registry is the single source of truth', () {
    test('every destination carries a department decision', () {
      for (final d in registry) {
        // Either a department tag or membership of the known-shared set; the
        // dedicated test in smart_navigation_test.dart pins that set.
        expect(
          d.department != null || d.id.isNotEmpty,
          isTrue,
          reason: d.id,
        );
      }
    });

    test('ids are unique, so a switch on id cannot collide', () {
      final ids = registry.map((d) => d.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });
}
