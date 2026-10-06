// Tests for the supervisory role set and the MPR period-key mapping.
//
// Two rules under test:
//   * the supervisory set contains exactly the line-management/executive
//     offices, and does NOT contain system administrators;
//   * a reporting window maps to an MPR period key only when it genuinely
//     sits inside one month or one quarter — never across a boundary, where a
//     single key would mislabel the data.

import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/security/role_guard.dart';
import 'package:infinitycore/core/security/supervisory_roles.dart';
import 'package:infinitycore/features/performance/mpr_service.dart';

void main() {
  group('supervisory role set', () {
    test('includes every office the spec names', () {
      expect(
        SupervisoryRoles.supervisory,
        containsAll(<String>[
          AppRoles.headOfHumanResources,
          AppRoles.headOfEBusiness,
          AppRoles.headOfOperations,
          AppRoles.financialController,
          AppRoles.headOfAudit,
          AppRoles.areaManager,
          AppRoles.branchManager,
          AppRoles.mdCeo,
        ]),
      );
    });

    test('the board is two stored roles, not one', () {
      expect(SupervisoryRoles.isSupervisory(AppRoles.director), isTrue);
      expect(SupervisoryRoles.isSupervisory(AppRoles.chairman), isTrue);
    });

    test('excludes system administrators', () {
      expect(
        SupervisoryRoles.isSupervisory(AppRoles.superAdmin),
        isFalse,
        reason: 'Super Admin is not a line-management office',
      );
      expect(SupervisoryRoles.isSupervisory(AppRoles.admin), isFalse);
    });

    test('excludes individual contributors', () {
      for (final r in <String>[
        AppRoles.loanOfficer,
        AppRoles.staff,
        AppRoles.customerService,
        AppRoles.hrOfficer,
        AppRoles.customer,
      ]) {
        expect(
          SupervisoryRoles.isSupervisory(r),
          isFalse,
          reason: '$r must not be offered as a supervisor',
        );
      }
    });

    test('an area manager is not a branch manager\'s peer in the above set', () {
      expect(
        SupervisoryRoles.supervisoryAboveBranchManager,
        contains(AppRoles.areaManager),
      );
      expect(
        SupervisoryRoles.supervisoryAboveBranchManager,
        isNot(contains(AppRoles.branchManager)),
      );
    });
  });

  group('supervisory person', () {
    SupervisoryPerson p(Map<String, dynamic> j) =>
        SupervisoryPerson.fromJson(j);

    test('builds a searchable label from name and role', () {
      final x = p({
        'id': 'u1',
        'full_name': 'Ada Okafor',
        'role': AppRoles.headOfHumanResources,
      });
      expect(x.searchLabel, contains('Ada Okafor'));
      expect(x.searchLabel, contains('Head of Human Resources'));
    });

    test('an executive with no employee row is not an error', () {
      final x = p({
        'id': 'u2',
        'full_name': 'Tunde Balogun',
        'role': AppRoles.mdCeo,
        'employee_id': null,
      });
      expect(x.employeeId, isNull);
      expect(x.fullName, 'Tunde Balogun');
    });

    test('falls back to the role when there is no name', () {
      final x = p({'id': 'u3', 'full_name': '', 'role': AppRoles.headOfAudit});
      expect(x.searchLabel, 'Head of Audit');
    });

    test('subtitle is null when neither department nor branch is set', () {
      final x = p({
        'id': 'u4',
        'full_name': 'A',
        'role': AppRoles.areaManager,
      });
      expect(x.subtitle, isNull);
    });
  });

  group('defence-in-depth filter', () {
    test('drops anyone who is not supervisory', () {
      final kept = SupervisorService.onlySupervisory([
        SupervisoryPerson.fromJson(
            {'id': '1', 'full_name': 'Boss', 'role': AppRoles.branchManager}),
        SupervisoryPerson.fromJson(
            {'id': '2', 'full_name': 'Clerk', 'role': AppRoles.customer}),
      ]);
      expect(kept, hasLength(1));
      expect(kept.first.fullName, 'Boss');
    });
  });

  group('MPR period keys', () {
    test('a single-month window becomes YYYY-MM', () {
      expect(
        MprPeriod.monthLabel(DateTime(2026, 5, 1), DateTime(2026, 5, 31)),
        '2026-05',
      );
    });

    test('zero-pads single-digit months', () {
      expect(
        MprPeriod.monthLabel(DateTime(2026, 1, 3), DateTime(2026, 1, 9)),
        '2026-01',
      );
    });

    test('a single-quarter window becomes YYYY-Qn', () {
      expect(
        MprPeriod.quarterLabel(DateTime(2026, 4, 1), DateTime(2026, 6, 30)),
        '2026-Q2',
      );
    });

    test('quarter boundaries are correct', () {
      expect(MprPeriod.quarterLabel(DateTime(2026, 1, 1), DateTime(2026, 3, 31)),
          '2026-Q1');
      expect(MprPeriod.quarterLabel(DateTime(2026, 7, 1), DateTime(2026, 9, 30)),
          '2026-Q3');
      expect(
          MprPeriod.quarterLabel(DateTime(2026, 10, 1), DateTime(2026, 12, 31)),
          '2026-Q4');
    });

    test('a window crossing a month boundary has no single month key', () {
      expect(
        MprPeriod.monthLabel(DateTime(2026, 5, 25), DateTime(2026, 6, 2)),
        isNull,
      );
    });

    test('a window crossing a quarter boundary falls back to quarter only if '
        'it still fits one', () {
      // 1–10 May crosses April→May, but both are Q2, so the quarter is honest.
      expect(
        MprPeriod.bestFor(DateTime(2026, 4, 28), DateTime(2026, 5, 3)),
        '2026-Q2',
      );
    });

    test('a window crossing a year boundary yields nothing', () {
      expect(
        MprPeriod.bestFor(DateTime(2025, 12, 28), DateTime(2026, 1, 4)),
        isNull,
      );
    });

    test('a single day inside one month resolves to that month', () {
      expect(
        MprPeriod.bestFor(DateTime(2026, 5, 10), DateTime(2026, 5, 10)),
        '2026-05',
      );
    });
  });
}
