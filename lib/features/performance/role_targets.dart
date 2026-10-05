// ============================================================================
// Performance — CUMULATIVE ROLE TARGETS
//
// The `targets` table is read through RLS, so mobile shows exactly what web
// shows; a row a person may not read is absent on both platforms rather than
// filtered client-side.
//
// WHY TARGETS ARE AGGREGATED BY ROLE
// A department head does not ask "how did Adebayo do", they ask "is my team
// hitting its numbers". RoleTargets does that grouping and nothing else, so the
// same rule cannot drift between this screen and the executive dashboard.
//
// THE CUMULATIVE RULE (the part that is easy to get wrong)
// A target running 1 Jan to 31 Dec is NOT complete when the clock hits 31 Dec.
// Completion is measured against the ELAPSED portion of the window:
//
//     expectedSoFar = (target - start) * (elapsed / total)
//
// so a quarter-old target reads ~25% at the quarter mark, not 0%. Without this
// every long-running target reads as "missed" for most of its life, which is how
// a performance screen ends up ignored.
//
// A target with no start yet is reported as "not yet due", never as 0%.
// ============================================================================

/// How a target's completion is measured.
enum TargetStatus {
  active,
  achieved,
  missed,
  cancelled;

  static TargetStatus parse(Object? v) {
    final s = v?.toString().toLowerCase();
    return TargetStatus.values.firstWhere(
      (e) => e.name == s,
      orElse: () => TargetStatus.active,
    );
  }

  bool get isTerminal =>
      this == TargetStatus.achieved ||
      this == TargetStatus.missed ||
      this == TargetStatus.cancelled;
}

/// One target row.
class PerformanceTarget {
  const PerformanceTarget({
    required this.id,
    required this.title,
    required this.employeeId,
    required this.employeeName,
    required this.role,
    required this.department,
    required this.measurementType,
    required this.targetValue,
    required this.currentValue,
    required this.startingValue,
    required this.unit,
    required this.startDate,
    required this.endDate,
    required this.status,
  });

  final String id;
  final String title;
  final String employeeId;
  final String employeeName;
  final String role;
  final String department;
  final String measurementType;
  final double targetValue;
  final double currentValue;
  final double startingValue;
  final String unit;
  final DateTime? startDate;
  final DateTime? endDate;
  final TargetStatus status;

  /// The measured value is the rise from the starting value, so a target that
  /// begins at 500 and must reach 1,000 is 100% at 500, not 50%.
  double get achievedDelta => currentValue - startingValue;
  double get requiredDelta => targetValue - startingValue;

  /// Where the target stands TODAY against the portion of its window that has
  /// actually elapsed. Null when nothing has been due yet.
  ///
  /// Null rather than 0 is the important part: a target starting next month is
  /// not 0% complete, it is not measurable yet, and rendering it as 0% would
  /// rank it below a genuinely failing target.
  double? completionPct({DateTime? asOf}) {
    if (status.isTerminal || status == TargetStatus.cancelled) return null;
    if (requiredDelta <= 0) return null;

    final now = asOf ?? DateTime.now();
    final start = startDate;
    final end = endDate;

    // Checked BEFORE the no-window branch below. Without this, a target with a
    // future start and no end date falls into "the whole target is due" and
    // reports 0% for a target that has not begun — the exact lie this whole
    // class exists to avoid.
    if (start != null && now.isBefore(start)) return null;

    // No window at all: the whole target is due.
    if (start == null || end == null) {
      return (achievedDelta / requiredDelta * 100).clamp(0, 200);
    }

    final totalMs = end.difference(start).inMilliseconds;
    if (totalMs <= 0) {
      return (achievedDelta / requiredDelta * 100).clamp(0, 200);
    }
    final elapsedMs = now.isAfter(end)
        ? totalMs
        : now.difference(start).inMilliseconds;
    final fraction = (elapsedMs / totalMs).clamp(0.0, 1.0);

    // What SHOULD have been achieved by now, on a straight line.
    final expected = requiredDelta * fraction;
    if (expected <= 0) return null;

    return (achievedDelta / expected * 100).clamp(0, 200);
  }

  /// The value the target "should" be at today. Null when nothing is due.
  double? expectedValue({DateTime? asOf}) {
    if (status == TargetStatus.cancelled) return null;
    final now = asOf ?? DateTime.now();
    final start = startDate;
    final end = endDate;
    // Checked before the no-window branch, for the same reason as in
    // completionPct: a target that has not started owes nothing yet, so there is
    // no expectation to report.
    if (start != null && now.isBefore(start)) return null;

    if (start == null || end == null) return targetValue;

    final totalMs = end.difference(start).inMilliseconds;
    if (totalMs <= 0) return targetValue;
    final elapsedMs = now.isAfter(end)
        ? totalMs
        : now.difference(start).inMilliseconds;
    final fraction = (elapsedMs / totalMs).clamp(0.0, 1.0);
    return startingValue + (requiredDelta * fraction);
  }

  /// Days remaining, negative when overdue. Null when there is no deadline.
  int? daysRemaining({DateTime? asOf}) {
    final end = endDate;
    if (end == null) return null;
    final now = asOf ?? DateTime.now();
    return end.difference(DateTime(now.year, now.month, now.day)).inDays;
  }

  bool get isOverdue {
    final left = daysRemaining();
    if (left == null) return false;
    if (status.isTerminal) return false;
    return left < 0;
  }

  /// The role this target belongs to, with an explicit fallback so an employee
  /// with no recorded position is grouped and visible rather than vanishing.
  String get roleKey {
    final r = role.trim();
    if (r.isEmpty) return 'Unassigned';
    return r[0].toUpperCase() + r.substring(1);
  }
}

/// Every target for one role, with the figures a manager actually asks for.
class RoleTargets {
  const RoleTargets({required this.role, required this.targets});

  final String role;
  final List<PerformanceTarget> targets;

  /// Only targets with something measurable, so a not-yet-due target cannot drag
  /// a role average down as though it had failed.
  List<PerformanceTarget> get measurable =>
      targets.where((t) => t.completionPct() != null).toList(growable: false);

  /// Mean completion across measurable targets. Null when none are measurable,
  /// which is different from 0% and is rendered as "—".
  double? get averageCompletion {
    final m = measurable;
    if (m.isEmpty) return null;
    final sum = m.fold<double>(0, (acc, t) => acc + t.completionPct()!);
    return sum / m.length;
  }

  int get total => targets.length;
  int get notYetDue => targets.where((t) => t.completionPct() == null).length;
  int get overdue => targets.where((t) => t.isOverdue).length;
  int get achieved =>
      targets.where((t) => t.status == TargetStatus.achieved).length;

  /// Counted separately from "average" because one cancelled target should not
  /// be reported as a miss.
  int get cancelled =>
      targets.where((t) => t.status == TargetStatus.cancelled).length;

  /// A value formatted for display: "—" when there is nothing to measure.
  String get completionLabel {
    final v = averageCompletion;
    return v == null ? '—' : '${v.toStringAsFixed(0)}%';
  }
}

/// Groups targets by employee role, best-performing role first.
///
/// [roleOf] resolves the role for an employee id, because `targets` does not
/// carry one. Roles with no measurable target are still returned: a role whose
/// targets have not started is a real answer ("not yet due"), not an empty row.
///
/// Such a role sorts LAST rather than first. A missing average is not a perfect
/// score, and letting it head the leaderboard would be the same error as
/// reporting "not reported" as 0% — in the opposite direction.
Map<String, RoleTargets> groupTargetsByRole(
  List<PerformanceTarget> targets,
  Map<String, String> roleOf,
) {
  final byRole = <String, List<PerformanceTarget>>{};
  for (final t in targets) {
    final role = t.role.trim().isEmpty
        ? (roleOf[t.employeeId]?.trim() ?? '')
        : t.role.trim();
    final key = role.isEmpty
        ? 'Unassigned'
        : role[0].toUpperCase() + role.substring(1);
    byRole.putIfAbsent(key, () => []).add(t);
  }

  final result = <String, RoleTargets>{
    for (final e in byRole.entries)
      e.key: RoleTargets(role: e.key, targets: e.value),
  };

  final ordered = result.entries.toList()
    ..sort((a, b) {
      final av = a.value.averageCompletion;
      final bv = b.value.averageCompletion;
      // Roles with nothing measurable go to the bottom.
      if (av == null && bv == null) return a.key.compareTo(b.key);
      if (av == null) return 1;
      if (bv == null) return -1;
      final byScore = bv.compareTo(av);
      return byScore != 0 ? byScore : a.key.compareTo(b.key);
    });

  return Map.fromEntries(ordered.map((e) => MapEntry(e.key, e.value)));
}
