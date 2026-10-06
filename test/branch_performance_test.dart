// ============================================================================
// Branch Performance — server-figure passthrough and sort behaviour
// ============================================================================
// The properties that matter here are negative ones: a figure the server did
// not measure must not be turned into a zero, and a gap in the data must not
// sort as though it were a failing branch.
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/performance/branch_performance_screen.dart';
import 'package:infinitycore/features/performance/branch_sort.dart';

/// Shaped exactly like the `branches` array the live
/// `get_director_executive_snapshot` RPC returns.
BranchPerformance _b({
  required String name,
  int? totalStaff,
  int? activeStaff,
  int? onLeave,
  Object? attendanceRate,
  Object? kpi,
  Object? targets,
}) => BranchPerformance(<String, dynamic>{
  'id': name,
  'name': name,
  'total_staff': totalStaff,
  'active_staff': activeStaff,
  'on_leave': onLeave,
  'attendance_rate': attendanceRate,
  'kpi_completion': kpi,
  'target_completion': targets,
});

void main() {
  group('Server figures are read, never recomputed', () {
    test('reads the branch row the server sent', () {
      final b = _b(
        name: 'Lagos Main',
        totalStaff: 12,
        activeStaff: 10,
        onLeave: 2,
        attendanceRate: 91,
        kpi: 87,
        targets: 64,
      );
      expect(b.name, 'Lagos Main');
      expect(b.totalStaff, 12);
      expect(b.activeStaff, 10);
      expect(b.onLeave, 2);
      expect(b.attendanceRate, 91.0);
      expect(b.kpiCompletion, 87.0);
      expect(b.targetCompletion, 64.0);
    });

    test('an unmeasured rate stays null, never 0', () {
      final b = _b(name: 'Unmeasured');
      expect(b.attendanceRate, isNull);
      expect(b.kpiCompletion, isNull);
      expect(b.targetCompletion, isNull);
    });

    test('an explicit zero is preserved as a real score', () {
      // 0% attendance and "not measured" are different facts and must not
      // collapse into one another.
      final b = _b(name: 'Zero', attendanceRate: 0);
      expect(b.attendanceRate, 0.0);
    });

    test('a rate sent as a string is still read', () {
      final b = _b(name: 'Texty', attendanceRate: '88.5');
      expect(b.attendanceRate, 88.5);
    });

    test('a missing row degrades rather than throwing', () {
      final b = BranchPerformance(<String, dynamic>{});
      expect(b.name, '');
      expect(b.totalStaff, 0);
      expect(b.attendanceRate, isNull);
    });
  });

  group('Sorting never lets a data gap look like a low score', () {
    final rows = [
      _b(name: 'Alpha', totalStaff: 10, attendanceRate: 80),
      _b(name: 'Bravo', totalStaff: 5, attendanceRate: 60),
      _b(name: 'Unmeasured', totalStaff: 8),
    ];

    test('best attendance puts the unmeasured branch last, not first', () {
      final out = BranchSort.attendanceDesc.apply(rows).map((r) => r.name);
      expect(out, <String>['Alpha', 'Bravo', 'Unmeasured']);
    });

    test('lowest attendance also puts the unmeasured branch last', () {
      // A descending list of "worst" is where an unmeasured row is most
      // dangerous: treating null as 0 would invent a failing branch.
      final out = BranchSort.attendanceAsc.apply(rows).map((r) => r.name);
      expect(out, <String>['Bravo', 'Alpha', 'Unmeasured']);
    });

    test(
      'an explicit 0% branch sorts as a real score, ahead of unmeasured',
      () {
        final withZero = [
          _b(name: 'Zero', attendanceRate: 0),
          _b(name: 'Unmeasured', attendanceRate: null),
        ];
        final out = BranchSort.attendanceAsc.apply(withZero).map((r) => r.name);
        expect(out, <String>['Zero', 'Unmeasured']);
      },
    );

    test('sorting by staff is stable and drops nothing', () {
      final out = BranchSort.byStaff.apply(rows).map((r) => r.name);
      expect(out, <String>['Alpha', 'Unmeasured', 'Bravo']);
      expect(out, hasLength(rows.length));
    });

    test('sorting by name is alphabetical', () {
      final out = BranchSort.nameAsc.apply(rows).map((r) => r.name);
      expect(out, <String>['Alpha', 'Bravo', 'Unmeasured']);
    });

    test('an empty list sorts to an empty list', () {
      expect(BranchSort.byStaff.apply(const []), isEmpty);
    });

    test('sort does not mutate the input', () {
      final input = List<BranchPerformance>.of(rows);
      BranchSort.byStaff.apply(input);
      expect(input.map((r) => r.name), <String>[
        'Alpha',
        'Bravo',
        'Unmeasured',
      ]);
    });
  });

  group('Sort identity', () {
    test(
      'equal key and direction compare equal, so the menu selection sticks',
      () {
        expect(BranchSort.attendanceDesc, BranchSort.attendanceDesc);
        expect(BranchSort.attendanceDesc, isNot(BranchSort.attendanceAsc));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // REGRESSION: the Deep-Dive RPC takes p_branch_id uuid, but the snapshot's
  // performance `branches` rows carry id = branch NAME (they are grouped by
  // name). Passing that straight through produced
  // `invalid input syntax for type uuid: "Head Office"` on screen.
  // ---------------------------------------------------------------------------
  group('Deep-dive branch id resolution', () {
    const headOfficeUuid = '0b6f2a1e-9c3d-4f21-8a77-2f5f1c9d4e10';
    const ikoroduUuid = '8d1c6b2f-1a2b-4c3d-9e8f-0a1b2c3d4e5f';

    /// Shaped like the `filters.branches` array the same snapshot returns:
    /// `[{id: <uuid>, name: <branch_name>}]`.
    final filters = <String, dynamic>{
      'branches': [
        {'id': headOfficeUuid, 'name': 'Head Office'},
        {'id': ikoroduUuid, 'name': 'Ikorodu'},
      ],
    };

    test('a name-valued row id resolves to the branch uuid', () {
      // The exact screenshot failure: row id is "Head Office", the RPC wants
      // the UUID behind that name.
      expect(
        resolveBranchUuid(
          branchId: 'Head Office',
          branchName: 'Head Office',
          filters: filters,
        ),
        headOfficeUuid,
      );
    });

    test('an id that is already a uuid passes through untouched', () {
      expect(
        resolveBranchUuid(
          branchId: headOfficeUuid,
          branchName: 'Head Office',
          filters: const <String, dynamic>{},
        ),
        headOfficeUuid,
      );
    });

    test('resolution keys off the row name, not the id', () {
      expect(
        resolveBranchUuid(
          branchId: 'odd-server-key',
          branchName: 'Ikorodu',
          filters: filters,
        ),
        ikoroduUuid,
      );
    });

    test('the Unassigned aggregate resolves to null, never a fake id', () {
      // "Unassigned" is an aggregate of staff with no branch — there is no
      // branch record, and inventing an id would query the wrong people.
      expect(
        resolveBranchUuid(
          branchId: 'Unassigned',
          branchName: 'Unassigned',
          filters: filters,
        ),
        isNull,
      );
    });

    test('missing or malformed filters resolve to null instead of throwing', () {
      expect(
        resolveBranchUuid(
          branchId: 'Head Office',
          branchName: 'Head Office',
          filters: const <String, dynamic>{},
        ),
        isNull,
      );
      expect(
        resolveBranchUuid(
          branchId: 'Head Office',
          branchName: 'Head Office',
          filters: const <String, dynamic>{'branches': 'not-a-list'},
        ),
        isNull,
      );
    });

    test('a filter entry whose id is not a uuid is never returned', () {
      expect(
        resolveBranchUuid(
          branchId: 'Broken',
          branchName: 'Broken',
          filters: const <String, dynamic>{
            'branches': [
              {'id': 'Broken', 'name': 'Broken'},
            ],
          },
        ),
        isNull,
      );
    });

    test('a blank branch name resolves to null', () {
      expect(
        resolveBranchUuid(
          branchId: '',
          branchName: '   ',
          filters: filters,
        ),
        isNull,
      );
    });
  });
}
