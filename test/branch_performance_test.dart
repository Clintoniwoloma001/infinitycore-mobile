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
}
