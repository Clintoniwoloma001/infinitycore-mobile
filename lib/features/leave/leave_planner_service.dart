import 'package:flutter/foundation.dart';

/// Leave Schedule Planner, ported 1:1 from the web platform's
/// `src/services/leavePlannerService.js` (Phase 70).
///
/// Every call is a SECURITY DEFINER RPC. The capacity engine, the working-day
/// engine and the availability checker all live in Postgres, so the phone and
/// the browser can never compute leave duration or capacity two different ways.
///
/// The UI never decides whether a rule passes. It renders the server's verdict,
/// the server's conflicts and the server's explanations. Nothing in this file
/// performs leave arithmetic of its own.

/// The glyph shown alongside each planner state chip, so state is never
/// conveyed by colour alone.
class PlannerStateGlyph {
  const PlannerStateGlyph._();

  static const onLeave = '●';
  static const upcoming = '✓';
  static const pending = '!';
  static const completed = '·';
}

/// Label + glyph for one planner state.
@immutable
class PlannerStateMeta {
  const PlannerStateMeta(this.label, this.glyph);

  final String label;
  final String glyph;
}

/// The four planner states the server assigns to a leave entry.
const Map<String, PlannerStateMeta> plannerStates = {
  'on_leave': PlannerStateMeta('On leave', PlannerStateGlyph.onLeave),
  'upcoming': PlannerStateMeta('Upcoming approved', PlannerStateGlyph.upcoming),
  'pending': PlannerStateMeta('Pending', PlannerStateGlyph.pending),
  'completed': PlannerStateMeta('Completed', PlannerStateGlyph.completed),
};

/// The verdict vocabulary returned by `check_leave_availability`.
enum LeaveVerdict { available, warning, conflict, unknown }

LeaveVerdict leaveVerdictFrom(String? raw) => switch (raw) {
  'AVAILABLE' => LeaveVerdict.available,
  'WARNING' => LeaveVerdict.warning,
  'CONFLICT' => LeaveVerdict.conflict,
  _ => LeaveVerdict.unknown,
};

/// One leave row on the planner timeline.
class PlannerEntry {
  const PlannerEntry({
    required this.employeeId,
    required this.fullName,
    this.employeeNumber,
    this.position,
    this.department,
    this.branchId,
    this.branchName,
    this.requestId,
    required this.leaveType,
    required this.status,
    required this.startDate,
    this.endDate,
    this.workingDays = 0,
    this.plannerState = 'completed',
  });

  final String employeeId;
  final String fullName;
  final String? employeeNumber;
  final String? position;
  final String? department;
  final String? branchId;
  final String? branchName;
  final String? requestId;
  final String leaveType;
  final String status;
  final String startDate;
  final String? endDate;
  final num workingDays;
  final String plannerState;

  /// The server treats a null `end_date` as a single-day request.
  String get effectiveEnd => endDate ?? startDate;

  factory PlannerEntry.fromJson(Map<String, dynamic> j) => PlannerEntry(
    employeeId: (j['employee_id'] ?? '').toString(),
    fullName: (j['full_name'] ?? '').toString(),
    employeeNumber: j['employee_number']?.toString(),
    position: j['position']?.toString(),
    department: j['department']?.toString(),
    branchId: j['branch_id']?.toString(),
    branchName: j['branch_name']?.toString(),
    requestId: j['request_id']?.toString(),
    leaveType: (j['leave_type'] ?? '').toString(),
    status: (j['status'] ?? '').toString(),
    startDate: (j['start_date'] ?? '').toString(),
    endDate: j['end_date']?.toString(),
    workingDays: (j['working_days'] as num?) ?? 0,
    plannerState: (j['planner_state'] ?? 'completed').toString(),
  );
}
/// One day of leave capacity pressure, exactly as the server scored it.
class LeaveCapacityDay {
  const LeaveCapacityDay(this.raw);

  final Map<String, dynamic> raw;

  String get date => raw['date']?.toString() ?? '';

  /// People already away on this day.
  int get onLeave => _asInt(raw['on_leave']);

  /// The ceiling the server applied, or null when no rule governs the day.
  int? get maxOnLeave {
    final v = raw['max_on_leave'];
    return v == null ? null : _asInt(v);
  }

  /// True when the day is at or over its ceiling.
  bool get isAtCapacity {
    final max = maxOnLeave;
    return max != null && max > 0 && onLeave >= max;
  }

  /// 0..1, used ONLY to tint the heatmap. Never rendered as a score: the server
  /// owns the policy, this only spreads colour across its verdict.
  double get pressure {
    final max = maxOnLeave;
    if (max == null || max <= 0) return 0;
    return (onLeave / max).clamp(0.0, 1.0);
  }

  static int _asInt(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}'.trim()) ?? 0;
  }
}

/// The whole planner in one aggregated read: timeline entries, the overview
/// counters and the capacity heatmap.
///
/// One payload rather than three, because the web reads it the same way.
/// Splitting it would let the counters and the timeline come from two different
/// snapshots and disagree on screen.
class LeavePlanner {
  const LeavePlanner({
    required this.entries,
    required this.summary,
    required this.capacity,
  });

  final List<PlannerEntry> entries;

  /// The server's own counters, rendered as-is. The client never recomputes a
  /// leave duration or a headcount the server already decided.
  final Map<String, dynamic> summary;

  /// Capacity pressure per day, exactly as the server scored it.
  final List<LeaveCapacityDay> capacity;

  /// Entries grouped by department, for the grouped view.
  Map<String, List<PlannerEntry>> get byDepartment {
    final out = <String, List<PlannerEntry>>{};
    for (final e in entries) {
      final key = (e.department?.isNotEmpty ?? false) ? e.department! : 'Unassigned';
      (out[key] ??= <PlannerEntry>[]).add(e);
    }
    return out;
  }
}
