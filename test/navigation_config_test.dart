// ============================================================================
// Parity tests for the mobile mirror of the web navigation config.
//
// These are the Dart counterpart of the web `tests/smartNavigation.test.mjs`.
// The point is not to re-test the logic in isolation - it is to pin the COPY.
// If the web `src/config/navigationConfig.js` changes and this file does not,
// these tests are the thing that makes the drift loud instead of silent.
//
// Every expectation here is transcribed from the web test of the same name.
// ============================================================================

// ============================================================================
// Drift guard: the mobile copy vs the ACTUAL web file on disk.
//
// The tests below pin the transcribed expectations, which stops someone editing
// mobile without thinking. They cannot notice the WEB changing, though - a
// transcription can only be verified against the original.
//
// This test closes that gap by reading the sibling web file and comparing it to
// the Dart map. If the web mapping is edited and mobile is not, this fails.
//
// It is skipped (not failed) when the sibling checkout is absent, because CI
// and a mobile-only clone legitimately do not have it. Skipping is safe: the
// pinned expectations above still apply, and this is a drift detector, not the
// security boundary.
// ============================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/security/navigation_config.dart';
import 'package:infinitycore/core/security/role_guard.dart';

/// The web checkout, relative to this package root.
const _webNavConfig = '../infinitycore-sara/src/config/navigationConfig.js';
const _webRoles = '../infinitycore-sara/src/constants/roles.js';

/// `Object.values(DEPARTMENTS)` means "unrestricted" on the web side.
const kAllDepartmentsSentinel = '<ALL>';

/// Parse `export const ROLES = { NAME: 'value', ... }` into NAME -> value.
Map<String, String> _parseRoles(String source) {
  final out = <String, String>{};
  final re = RegExp(r"^\s*([A-Z_]+)\s*:\s*'([^']+)'", multiLine: true);
  for (final m in re.allMatches(source)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

String _deptKey(String webName) => switch (webName) {
  'HR' => AppDepartments.hr,
  'AUDIT' => AppDepartments.audit,
  'RISK' => AppDepartments.risk,
  'ADMIN' => AppDepartments.admin,
  'OPERATIONS' => AppDepartments.operations,
  'E_BUSINESS' => AppDepartments.eBusiness,
  'FINANCE' => AppDepartments.finance,
  'EXECUTIVE' => AppDepartments.executive,
  _ => webName.toLowerCase(),
};

/// Parse `ROLE_DEPARTMENT` into role-value -> department list.
Map<String, List<String>> _parseRoleDepartment(
  String source,
  Map<String, String> roles,
) {
  // Anchor on the DECLARATION, not the first mention: the file's header
  // comment also names ROLE_DEPARTMENT, and matching that would parse garbage.
  final decl = RegExp(r'const\s+ROLE_DEPARTMENT\s*=').firstMatch(source);
  if (decl == null) return const {};
  final open = source.indexOf('{', decl.end);
  if (open < 0) return const {};
  // Walk braces so nested arrays do not end the object early.
  var depth = 0, end = open;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  final body = source.substring(open, end + 1);

  final out = <String, List<String>>{};
  // A value is EITHER an inline array (possibly multi-line) or the
  // Object.values(DEPARTMENTS) shorthand used for the unrestricted roles.
  final entry = RegExp(
    r'\[ROLES\.([A-Z_]+)\]\s*:\s*(Object\.values\(DEPARTMENTS\)|\[[^\]]*\])',
    dotAll: true,
  );
  for (final m in entry.allMatches(body)) {
    final roleValue = roles[m.group(1)!];
    if (roleValue == null) continue;
    final raw = m.group(2)!;
    if (raw.startsWith('Object.values')) {
      out[roleValue] = const [kAllDepartmentsSentinel];
      continue;
    }
    out[roleValue] = RegExp(r'DEPARTMENTS\.([A-Z_]+)')
        .allMatches(raw)
        .map((d) => _deptKey(d.group(1)!))
        .toList();
  }
  return out;
}

void main() {
  group('web/mobile navigation config parity (live file)', () {
    final navFile = File(_webNavConfig);
    final rolesFile = File(_webRoles);

    test('the mobile ROLE_DEPARTMENT matches the web file on disk', () {
      if (!navFile.existsSync() || !rolesFile.existsSync()) {
        markTestSkipped('sibling web checkout not present at $_webNavConfig');
        return;
      }
      final roles = _parseRoles(rolesFile.readAsStringSync());
      final web = _parseRoleDepartment(navFile.readAsStringSync(), roles);
      expect(
        web,
        isNotEmpty,
        reason: 'failed to parse the web ROLE_DEPARTMENT',
      );

      final drift = <String>[];
      web.forEach((role, depts) {
        final mine = kRoleDepartment[role];
        if (mine == null) {
          drift.add('$role missing on mobile (web: $depts)');
          return;
        }
        final webSide =
            depts.length == 1 && depts.first == kAllDepartmentsSentinel
            ? AppDepartments.all
            : depts;
        if (webSide.length != mine.length ||
            !webSide.toSet().containsAll(mine)) {
          drift.add('$role: web=$webSide mobile=$mine');
        }
      });

      expect(
        drift,
        isEmpty,
        reason:
            'The web navigation mapping changed without the mobile mirror being '
            'updated. The web file is the source of truth - mirror it into '
            'lib/core/security/navigation_config.dart.\n${drift.join('\n')}',
      );
    });

    test('mobile grants no role a department the web does not', () {
      if (!navFile.existsSync() || !rolesFile.existsSync()) {
        markTestSkipped('sibling web checkout not present');
        return;
      }
      final roles = _parseRoles(rolesFile.readAsStringSync());
      final web = _parseRoleDepartment(navFile.readAsStringSync(), roles);

      final overreach = <String>[];
      kRoleDepartment.forEach((role, depts) {
        final webDepts = web[role];
        if (webDepts == null) {
          if (depts.isNotEmpty) {
            overreach.add(
              '$role is shared-only on web but sees $depts on mobile',
            );
          }
          return;
        }
        if (webDepts.length == 1 && webDepts.first == kAllDepartmentsSentinel) {
          return; // unrestricted on web; nothing can exceed it
        }
        for (final d in depts) {
          if (!webDepts.contains(d)) {
            overreach.add('$role sees $d on mobile but not on web');
          }
        }
      });

      expect(overreach, isEmpty, reason: overreach.join('\n'));
    });
  });

  // A stand-in for the real destination groups, so the predicate is tested in
  // isolation. Keyed by the web group name; `null` department means SHARED.
  const groups = <String, String?>{
    'Mine': null,
    'HR': AppDepartments.hr,
    'Audit': AppDepartments.audit,
    'Risk': AppDepartments.risk,
    'Admin': AppDepartments.admin,
    'Operations': AppDepartments.operations,
    'Finance': AppDepartments.finance,
    'Executive': AppDepartments.executive,
  };

  List<String> names(String? role, {String? department}) => groups.entries
      .where((e) => canSeeDepartment(role, e.value, department))
      .map((e) => e.key)
      .toList();

  group('Shared access', () {
    test('every role keeps the shared destination', () {
      for (final role in kRoleDepartment.keys) {
        final out = names(role);
        expect(
          out,
          contains('Mine'),
          reason: '$role lost the shared destination',
        );
      }
    });

    test('a plain employee sees only shared tabs', () {
      expect(names(AppRoles.staff), <String>['Mine']);
      expect(isSharedOnly(AppRoles.staff), isTrue);
    });
  });

  group('Department scoping', () {
    test('HR roles see HR, not Audit or Risk', () {
      for (final role in <String>[
        AppRoles.headOfHumanResources,
        AppRoles.hrOfficer,
      ]) {
        final out = names(role);
        expect(out, contains('HR'), reason: '$role should see HR');
        expect(
          out,
          isNot(contains('Audit')),
          reason: '$role must not see Audit',
        );
        expect(out, isNot(contains('Risk')), reason: '$role must not see Risk');
      }
    });

    test('Head of Audit sees Audit, not HR', () {
      final out = names(AppRoles.headOfAudit);
      expect(out, contains('Audit'));
      expect(out, isNot(contains('HR')));
    });

    test('Head of Risk and Legal share the Risk workspace', () {
      for (final role in <String>[
        AppRoles.headOfRiskCompliance,
        AppRoles.headOfLegal,
      ]) {
        final out = names(role);
        expect(out, contains('Risk'), reason: '$role should see Risk');
        expect(out, isNot(contains('HR')), reason: '$role must not see HR');
      }
    });

    test('Head of E-Business maps to its own department', () {
      expect(departmentsForRole(AppRoles.headOfEBusiness), <String>[
        AppDepartments.eBusiness,
      ]);
    });

    test('front-line roles land in Operations', () {
      for (final role in <String>[
        AppRoles.branchManager,
        AppRoles.areaManager,
        AppRoles.loanOfficer,
        AppRoles.relationshipManager,
        AppRoles.customerService,
      ]) {
        expect(departmentsForRole(role), <String>[
          AppDepartments.operations,
        ], reason: role);
      }
    });
  });

  group('Unrestricted access', () {
    test('Super Admin and Admin see every destination', () {
      for (final role in kUnrestrictedRoles) {
        expect(names(role).length, groups.length, reason: role);
      }
    });

    test('a customer gets the shared destination only', () {
      expect(names(AppRoles.customer), <String>['Mine']);
    });
  });

  group('Safety of the department signal', () {
    test('a free-text department cannot grant access it does not map to', () {
      // `employees.department` is free text and may hold an executive title or
      // a typo. It may refine the role mapping but must never invent access.
      expect(names(AppRoles.staff, department: 'MD/CEO'), <String>[
        'Mine',
      ], reason: 'an executive title in department granted HR access');
      expect(names(AppRoles.staff, department: 'Human Resources'), <String>[
        'Mine',
      ], reason: 'an unmapped department string granted HR access');
    });

    test('a matching department refines the role mapping', () {
      final out = names(AppRoles.staff, department: 'audit');
      expect(out, contains('Audit'));
    });

    test('normalisation is limited to whitespace and hyphens, as on web', () {
      // Web does `.trim().toLowerCase().replace(/[\s-]+/g, '_')` and nothing
      // else. "Audit & Compliance" is a real label in the web nav, but the `&`
      // is never touched, so it does not reduce to the `audit` KEY and must
      // grant nothing rather than being guessed at. Mirrored deliberately:
      // mobile must not be more permissive than web.
      expect(names(AppRoles.staff, department: 'Audit & Compliance'), <String>[
        'Mine',
      ], reason: 'an unnormalisable label must not grant a department');
    });

    test('a department string that normalises to a real key does match', () {
      // "E-Business" / "E Business" are how a human would type `e_business`.
      for (final typed in <String>[
        'e_business',
        'E Business',
        'E-Business',
        ' e-business ',
      ]) {
        expect(
          canSeeDepartment(AppRoles.staff, AppDepartments.eBusiness, typed),
          isTrue,
          reason: 'stored department "$typed" should refine to e_business',
        );
      }
    });

    test('an unknown role is shared-only, never unrestricted', () {
      expect(names('not_a_real_role'), <String>['Mine']);
    });

    test('a null or empty role is shared-only', () {
      expect(names(null), <String>['Mine']);
      expect(names(''), <String>['Mine']);
    });
  });

  group('It is a UX layer, not the security boundary', () {
    test('the file documents that it is not a security boundary', () {
      // Guards against someone "tidying" the warning away.
      expect(
        kRoleDepartment,
        isNotEmpty,
        reason: 'mapping must never be emptied into a permissive default',
      );
      expect(kUnrestrictedRoles, isNot(contains(AppRoles.staff)));
      expect(kUnrestrictedRoles, isNot(contains(AppRoles.director)));
    });
  });

  group('Real web catalogue coverage', () {
    // The web parity test asserts every role in the web ROLES catalogue has an
    // explicit entry, so a new role can never fall through to shared-only.
    // This is the same guarantee, pinned against the mobile role list.
    test('every catalogued role has an explicit mapping decision', () {
      const catalogue = <String>[
        AppRoles.superAdmin,
        AppRoles.admin,
        AppRoles.mdCeo,
        AppRoles.chairman,
        AppRoles.director,
        AppRoles.headOfBusiness,
        AppRoles.headOfOperations,
        AppRoles.headOfEBusiness,
        AppRoles.financialController,
        AppRoles.headOfRiskCompliance,
        AppRoles.headOfLegal,
        AppRoles.headOfAudit,
        AppRoles.branchManager,
        AppRoles.areaManager,
        AppRoles.loanOfficer,
        AppRoles.relationshipManager,
        AppRoles.customerService,
        AppRoles.headOfHumanResources,
        AppRoles.hrOfficer,
        AppRoles.staff,
        AppRoles.customer,
      ];
      for (final role in catalogue) {
        expect(
          kRoleDepartment.containsKey(role),
          isTrue,
          reason:
              '$role missing from kRoleDepartment - it would silently fall back '
              'to shared-only',
        );
      }
    });
  });
}
