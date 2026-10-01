// ============================================================================
// Leave Schedule Planner - RPC client
//
// Calls the SAME SECURITY DEFINER functions the web planner uses
// (src/services/leavePlannerService.js). The capacity engine, the working-day
// engine and the availability checker all live in Postgres, so the phone and the
// browser can never compute a leave duration or a verdict two different ways.
//
// This file performs NO leave arithmetic. If it derived a duration locally it
// would disagree with the web the first time a public holiday fell inside a
// request.
// ============================================================================
import 'package:intl/intl.dart';

import '../../core/services/supabase_service.dart';
import 'leave_planner_service.dart';

/// Raised when a planner RPC refuses the caller.
///
/// [forbidden] separates "you may not see this" from "that request was invalid",
/// so the screen can explain the refusal rather than showing a raw DB message.
class LeavePlannerException implements Exception {
  const LeavePlannerException(this.message, {this.forbidden = false});

  final String message;
  final bool forbidden;

  @override
  String toString() => message;
}

/// The result of `check_leave_availability`: a verdict plus the server's own
/// conflicts, warnings and alternatives.
///
/// Every field is the server's opinion. The screen renders them; it never
/// re-derives whether a request is permitted.
class LeaveAvailability {
  const LeaveAvailability({
    required this.verdict,
    required this.conflicts,
    required this.warnings,
    required this.alternatives,
  });

  final LeaveVerdict verdict;
  final List<Map<String, dynamic>> conflicts;
  final List<Map<String, dynamic>> warnings;
  final List<Map<String, dynamic>> alternatives;

  /// A conflict is a hard no from the server. Anything else - including
  /// [LeaveVerdict.unknown] - must never be presented as approved.
  bool get isBlocked => verdict == LeaveVerdict.conflict;

  static List<Map<String, dynamic>> rows(Object? v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  static LeaveAvailability fromJson(Map<String, dynamic> j) => LeaveAvailability(
    verdict: leaveVerdictFrom(j['verdict']?.toString()),
    conflicts: rows(j['conflicts']),
    warnings: rows(j['warnings']),
    alternatives: rows(j['alternatives']),
  );
}

/// Read client for the Leave Schedule Planner.
class LeavePlannerClient {
  const LeavePlannerClient._();

  static final LeavePlannerClient instance = LeavePlannerClient._();

  /// ISO date for [d] - the format every planner RPC expects.
  static String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  /// Converts a refusal into a typed [LeavePlannerException].
  ///
  /// `LEAVE_FORBIDDEN` / `LEAVE_CONFIG_FORBIDDEN` are permission refusals; the
  /// machine prefix is stripped so the UI shows the human sentence.
  Never _fail(Object? error) {
    final raw = (error is Map && error['message'] != null)
        ? error['message'].toString()
        : error.toString();
    final forbidden =
        raw.contains('LEAVE_FORBIDDEN') || raw.contains('LEAVE_CONFIG_FORBIDDEN');
    final detail = raw.contains(':')
        ? raw.substring(raw.indexOf(':') + 1).trim()
        : raw;
    throw LeavePlannerException(
      detail.isEmpty ? raw : detail,
      forbidden: forbidden,
    );
  }

  /// The whole planner for a window: timeline, counters and capacity heatmap in
  /// ONE read, so the counters and the timeline can never come from two
  /// different snapshots and disagree on screen.
  Future<LeavePlanner> planner({
    required String from,
    required String to,
    String? department,
    String? branchId,
    String? leaveType,
    String? status,
  }) async {
    final res = await SupabaseService.client.rpc(
      'get_leave_planner',
      params: {
        'p_from': from,
        'p_to': to,
        'p_department': department,
        'p_branch_id': branchId,
        'p_area': null,
        'p_role': null,
        'p_employee_id': null,
        'p_leave_type': leaveType,
        'p_status': status,
      },
    );

    if (res is Map && res['ok'] == false) {
      _fail(res['message'] ?? 'Unable to load the leave planner.');
    }
    if (res is! Map) {
      throw const LeavePlannerException(
        'The server returned an unexpected response.',
      );
    }
    final map = Map<String, dynamic>.from(res);
    return LeavePlanner(
      entries: LeaveAvailability.rows(map['entries'])
          .map(PlannerEntry.fromJson)
          .toList(growable: false),
      summary: map['summary'] is Map
          ? Map<String, dynamic>.from(map['summary'] as Map)
          : <String, dynamic>{},
      capacity: LeaveAvailability.rows(map['capacity'])
          .map(LeaveCapacityDay.new)
          .toList(growable: false),
    );
  }

  /// The server's verdict for a proposed request.
  ///
  /// [forUpdate] asks the server to take a transaction-scoped advisory lock,
  /// which is what stops two people claiming the last remaining slot at the
  /// same moment. The request composer must pass true.
  Future<LeaveAvailability> checkAvailability({
    required List<String> employeeIds,
    required String leaveType,
    required String start,
    required String end,
    bool forUpdate = false,
  }) async {
    final res = await SupabaseService.client.rpc(
      'check_leave_availability',
      params: {
        'p_employee_ids': employeeIds,
        'p_leave_type': leaveType,
        'p_start': start,
        'p_end': end,
        'p_for_update': forUpdate,
        'p_depth': 0,
      },
    );

    if (res is Map && res['ok'] == false) {
      _fail(res['message'] ?? 'Unable to check leave availability.');
    }
    if (res is! Map) {
      throw const LeavePlannerException(
        'The server returned an unexpected response.',
      );
    }
    return LeaveAvailability.fromJson(Map<String, dynamic>.from(res));
  }

  /// Working days in a range, using the platform's configured calendar.
  ///
  /// Always the server's count. The client must never assume a leave run of
  /// "3 working days" from a date span - public holidays and weekend rules live
  /// in Postgres, and a client-side guess would silently disagree with web.
  Future<int> workingDays(String start, String end, {String? branchId}) async {
    final res = await SupabaseService.client.rpc(
      'leave_working_days',
      params: {
        'p_start': start,
        'p_end': end,
        'p_branch_id': branchId,
      },
    );
    if (res is Map && res['ok'] == false) _fail(res['message']);
    if (res == null) return 0;
    if (res is num) return res.toInt();
    if (res is String) return int.tryParse(res.trim()) ?? 0;
    return 0;
  }

  /// The configured leave-year window for [year].
  ///
  /// The leave year rarely starts on 1 January, so a hardcoded Jan-Dec range
  /// would show the wrong months at the edges of the year.
  Future<({String start, String? end})> leaveYearWindow(int year) async {
    final res = await SupabaseService.client.rpc(
      'leave_year_window',
      params: {'p_year': year},
    );
    if (res is! Map) return (start: '$year-01-01', end: null);
    return (
      start: res['start']?.toString() ?? '$year-01-01',
      end: res['end']?.toString(),
    );
  }
}
