// ============================================================================
// Branch Performance — sort
// ============================================================================
// Presentation only. Sorting reorders rows the server already produced; it never
// recomputes a figure and never drops a branch that has no value for the
// sorted metric.
//
// A branch with no measured rate sorts to the END of a descending list rather
// than being treated as 0%. That distinction matters: "we did not measure this"
// and "this scored zero" are different facts, and conflating them would make a
// missing figure look like a failing branch.
import 'branch_performance_screen.dart';

enum BranchSortKey { staff, attendance, name }

class BranchSort {
  const BranchSort(this.key, {required this.descending, required this.label});

  final BranchSortKey key;
  final bool descending;
  final String label;

  /// Most staff first. This is the order the server already returns, so it is
  /// the default and needs no client-side work to look right.
  static const byStaff = BranchSort(BranchSortKey.staff, descending: true, label: 'Most staff');

  static const attendanceDesc = BranchSort(
    BranchSortKey.attendance,
    descending: true,
    label: 'Best attendance',
  );

  static const attendanceAsc = BranchSort(
    BranchSortKey.attendance,
    descending: false,
    label: 'Lowest attendance',
  );

  static const nameAsc = BranchSort(BranchSortKey.name, descending: false, label: 'Name');

  /// [measure] returns the sortable value, or null when the server did not
  /// measure it.
  List<BranchPerformance> apply(List<BranchPerformance> branches) {
    final out = List<BranchPerformance>.of(branches);
    out.sort((a, b) {
      int cmp;
      switch (key) {
        case BranchSortKey.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case BranchSortKey.staff:
          cmp = a.totalStaff.compareTo(b.totalStaff);
        case BranchSortKey.attendance:
          final av = a.attendanceRate;
          final bv = b.attendanceRate;
          if (av == null && bv == null) return 0;
          // Unmeasured rows always sink to the bottom, whichever way the
          // sort runs, so a gap in the data cannot masquerade as a low score.
          if (av == null) return 1;
          if (bv == null) return -1;
          cmp = av.compareTo(bv);
      }
      return descending ? -cmp : cmp;
    });
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is BranchSort && other.key == key && other.descending == descending;

  @override
  int get hashCode => Object.hash(key, descending);
}
