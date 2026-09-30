import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../core/services/supabase_service.dart';

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
