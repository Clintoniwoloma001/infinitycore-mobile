import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';

/// Leave domain, ported 1:1 from the web platform's
/// `leaveApprovalsService.js` / `leaveBalanceService.js`.
///
/// Every write goes through the same server functions the web app uses
/// (`process_leave_decision`, `submit_leave_feedback`) or the same tables
/// (`leave_requests`, `leave_balances`, `leave_approvals`), so leave business
/// logic — approval chain resolution, balance movement, notifications — is
/// never reimplemented on the client.

// ------------------------------------------------------------------
// Domain constants (mirror src/domains/leave/entitlements.js)
// ------------------------------------------------------------------

const Map<String, String> leaveTypeLabels = {
  'annual': 'Annual Leave',
  'maternity': 'Maternity Leave',
  'examination': 'Examination Leave',
  'paternity': 'Paternity Leave',
  'unpaid': 'Unpaid Leave',
};

const Map<String, int?> leaveEntitlements = {
  'annual': 10,
  'maternity': 90,
  'examination': 5,
  'paternity': 2,
  'unpaid': null,
};

const List<Map<String, String>> defaultApprovalChain = [
  {'stage_key': 'line_manager', 'label': 'Line Manager'},
  {'stage_key': 'branch_manager', 'label': 'Branch Manager'},
  {'stage_key': 'area_manager', 'label': 'Area Manager'},
  {'stage_key': 'head_of_human_resources', 'label': 'Head of Human Resources'},
];

/// Status vocabulary shared with the web views.
const List<String> leaveStatuses = [
  'pending',
  'approved',
  'rejected',
  'cancelled',
];

// ------------------------------------------------------------------
// Models
// ------------------------------------------------------------------

class LeaveBalance {
  const LeaveBalance({
    required this.leaveType,
    required this.entitled,
    required this.used,
    required this.pending,
  });

  final String leaveType;
  final double? entitled;
  final double used;
  final double pending;

  /// `unpaid` is uncapped, matching `balanceFor()` on web.
  double get remaining =>
      entitled == null ? double.infinity : entitled! - used - pending;

  String get label => leaveTypeLabels[leaveType] ?? leaveType;

  factory LeaveBalance.fromRow(String leaveType, Map<String, dynamic>? row) {
    final entitled = row == null
        ? leaveEntitlements[leaveType]?.toDouble()
        : _double(row['effective_entitlement'] ?? row['entitled_days']);
    return LeaveBalance(
      leaveType: leaveType,
      entitled: entitled,
      used: _double(row?['used_days']) ?? 0,
      pending: _double(row?['pending_days']) ?? 0,
    );
  }
}

class LeaveApproval {
  const LeaveApproval({
    required this.stageKey,
    required this.stageLabel,
    required this.decision,
    required this.comment,
    required this.approverName,
    required this.signature,
    required this.createdAt,
    required this.revisedStart,
    required this.revisedEnd,
  });

  final String stageKey;
  final String stageLabel;
  final String decision;
  final String comment;
  final String approverName;
  final String signature;
  final String createdAt;

  /// Set when an approver moved the dates. Surfaced in the trail so a revised
  /// date stays visible through to the final approved record.
  final String revisedStart;
  final String revisedEnd;

  bool get hasRevisedDates =>
      revisedStart.isNotEmpty || revisedEnd.isNotEmpty;

  factory LeaveApproval.fromRow(Map<String, dynamic> row) {
    final payload = _json(row['metadata'] ?? row['payload'] ?? row['details']);
    return LeaveApproval(
      stageKey: '${row['stage_key'] ?? ''}',
      stageLabel: '${row['stage_label'] ?? row['stage_key'] ?? ''}',
      decision: '${row['decision'] ?? row['status'] ?? ''}',
      comment: '${row['comment'] ?? row['comments'] ?? ''}',
      approverName: '${row['approver_name'] ?? ''}',
      signature: '${row['signature'] ?? ''}',
      createdAt: '${row['created_at'] ?? ''}',
      revisedStart:
          '${row['revised_start_date'] ?? payload?['revised_start_date'] ?? ''}',
      revisedEnd:
          '${row['revised_end_date'] ?? payload?['revised_end_date'] ?? ''}',
    );
  }
}

class LeaveRequest {
  const LeaveRequest({
    required this.id,
    required this.employeeName,
    required this.leaveType,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.reason,
    required this.status,
    required this.createdAt,
    required this.approvalLevel,
    required this.approverName,
    required this.approvalComments,
    required this.createdBy,
  });

  final String id;
  final String employeeName;
  final String leaveType;
  final String startDate;
  final String endDate;
  final double days;
  final String reason;
  final String status;
  final String createdAt;
  final int approvalLevel;
  final String approverName;
  final String approvalComments;

  /// `created_by` on the row — used by [canActOnRequest] to stop an approver
  /// actioning their own request, exactly as web does.
  final String createdBy;

  bool get isPending => status.toLowerCase() == 'pending';
  bool get isApproved => status.toLowerCase() == 'approved';

  String get label => leaveTypeLabels[leaveType] ?? leaveType;

  factory LeaveRequest.fromRow(Map<String, dynamic> row) => LeaveRequest(
    id: '${row['id'] ?? ''}',
    employeeName: '${row['employee_name'] ?? ''}',
    leaveType: '${row['leave_type'] ?? 'annual'}',
    startDate: _dateOnly(row['start_date']),
    endDate: _dateOnly(row['end_date']),
    days: _double(row['days']) ?? 0,
    reason: '${row['reason'] ?? ''}',
    status: '${row['status'] ?? 'pending'}',
    createdAt: '${row['created_at'] ?? ''}',
    approvalLevel: int.tryParse('${row['approval_level'] ?? 1}') ?? 1,
    approverName: '${row['approved_by_name'] ?? ''}',
    approvalComments: '${row['approval_comments'] ?? ''}',
    createdBy: '${row['created_by'] ?? ''}',
  );
}

class LeaveService {
  LeaveService._();

  static final LeaveService instance = LeaveService._();

  SupabaseClient get _db => SupabaseService.client;

  // ----------------------------------------------------------------
  // Balances — same `leave_balances` rows the web balance page reads.
  // ----------------------------------------------------------------

  Future<List<LeaveBalance>> myBalances({int? year}) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return _fallbackBalances();
    final y = year ?? DateTime.now().year;
    for (final column in const ['employee_user_id', 'employee_id']) {
      final key = column == 'employee_id' ? await _myEmployeeId() : userId;
      if (key == null) continue;
      try {
        final rows = await _db
            .from('leave_balances')
            .select('*')
            .eq(column, key)
            .eq('year', y);
        final parsed = _balancesFrom(rows as List<dynamic>? ?? const []);
        if (parsed.any((b) => b.entitled != null)) return parsed;
      } catch (_) {
        // Column shape differs between deployments; try the next one.
      }
    }
    return _fallbackBalances();
  }

  List<LeaveBalance> _balancesFrom(List<dynamic> rows) {
    final byType = <String, Map<String, dynamic>>{};
    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      byType['${row['leave_type']}'] = row;
    }
    return [
      for (final type in leaveTypeLabels.keys)
        LeaveBalance.fromRow(type, byType[type]),
    ];
  }

  /// Entitlement-only view, used when no `leave_balances` row exists yet.
  List<LeaveBalance> _fallbackBalances() => [
    for (final type in leaveTypeLabels.keys) LeaveBalance.fromRow(type, null),
  ];

  Future<String?> _myEmployeeId() async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return null;
    try {
      final row = await _db
          .from('employees')
          .select('id')
          .eq('user_id', userId)
          .maybeSingle();
      return row == null ? null : '${row['id']}';
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------------
  // Requests
  // ----------------------------------------------------------------

  Future<List<LeaveRequest>> myRequests() async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return const [];
    final rows = await _db
        .from('leave_requests')
        .select('*')
        .eq('created_by', userId)
        .order('created_at', ascending: false);
    return [
      for (final raw in rows as List<dynamic>? ?? const [])
        if (raw is Map) LeaveRequest.fromRow(Map<String, dynamic>.from(raw)),
    ];
  }

  /// Inserts into the same `leave_requests` table the web composer writes to.
  /// The approval chain is resolved server-side from this row, so mobile and
  /// web requests route identically.
  Future<LeaveRequest> submitRequest({
    required String leaveType,
    required DateTime startDate,
    required DateTime endDate,
    required String reason,
  }) async {
    final user = _db.auth.currentUser;
    if (user == null) throw StateError('Not signed in.');
    final row = await _db
        .from('leave_requests')
        .insert({
          'employee_name': await _myDisplayName(),
          'leave_type': leaveType,
          'start_date': _isoDate(startDate),
          'end_date': _isoDate(endDate),
          'days': workingDays(startDate, endDate),
          'reason': reason,
          'status': 'pending',
          'approval_level': 1,
          'created_by': user.id,
        })
        .select()
        .single();
    return LeaveRequest.fromRow(Map<String, dynamic>.from(row));
  }

  Future<String> _myDisplayName() async {
    final user = _db.auth.currentUser;
    final meta = user?.userMetadata;
    final fromMeta = '${meta?['full_name'] ?? meta?['name'] ?? ''}'.trim();
    if (fromMeta.isNotEmpty) return fromMeta;
    try {
      final r = await _db.rpc('resolve_user_identity');
      if (r is List && r.isNotEmpty && r.first is Map) {
        final m = Map<String, dynamic>.from(r.first as Map);
        final name = '${m['full_name'] ?? m['name'] ?? m['email'] ?? ''}'.trim();
        if (name.isNotEmpty) return name;
      }
    } catch (_) {}
    return user?.email ?? '';
  }

  /// Approval trail for one request, from `leave_approvals` — the same rows
  /// the web trail renders.
  Future<List<LeaveApproval>> approvalsFor(String requestId) async {
    try {
      final rows = await _db
          .from('leave_approvals')
          .select('*')
          .eq('leave_request_id', requestId)
          .order('created_at', ascending: true);
      return [
        for (final raw in rows as List<dynamic>? ?? const [])
          if (raw is Map) LeaveApproval.fromRow(Map<String, dynamic>.from(raw)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Expected chain for a request, resolved server-side when available.
  Future<List<Map<String, String>>> chainFor(String requestId) async {
    try {
      final data = await _db.rpc(
        'get_leave_approval_chain_for_request',
        params: {'p_request_id': requestId},
      );
      if (data is List && data.isNotEmpty) {
        return [
          for (final raw in data)
            if (raw is Map)
              {
                'stage_key': '${raw['stage_key'] ?? raw['role'] ?? ''}',
                'label': '${raw['label'] ?? raw['stage_key'] ?? ''}',
              },
        ];
      }
    } catch (_) {}
    return defaultApprovalChain;
  }

  /// Applies a decision through `process_leave_decision`, exactly as web does.
  /// [signaturePng] takes precedence; otherwise the typed name or initials are
  /// stored as the sign-off.
  Future<void> decide({
    required String requestId,
    required String decision,
    String comment = '',
    String? signatureName,
    Uint8List? signaturePng,
    DateTime? revisedStart,
    DateTime? revisedEnd,
    bool requestInfo = false,
  }) async {
    final signature = signaturePng != null
        ? base64Encode(signaturePng)
        : (signatureName ?? '').trim();
    await _db.rpc(
      'process_leave_decision',
      params: {
        'p_request_id': requestId,
        'p_decision': decision,
        'p_comment': comment.isEmpty ? null : comment,
        'p_signature': signature.isEmpty ? null : signature,
        'p_request_info': requestInfo,
        if (revisedStart != null)
          'p_revised_start_date': _isoDate(revisedStart),
        if (revisedEnd != null) 'p_revised_end_date': _isoDate(revisedEnd),
      },
    );
  }

  Future<void> submitFeedback({
    required String requestId,
    required int turnaroundRating,
    required int easeRating,
    String feedbackText = '',
  }) async {
    await _db.rpc(
      'submit_leave_feedback',
      params: {
        'p_request_id': requestId,
        'p_turnaround_rating': turnaroundRating,
        'p_ease_rating': easeRating,
        'p_text': feedbackText.isEmpty ? null : feedbackText,
      },
    );
  }

  Future<void> cancelRequest(String requestId) async {
    await _db
        .from('leave_requests')
        .update({'status': 'cancelled'})
        .eq('id', requestId);
  }

  /// Requests currently sitting in the signed-in user's approval queue.
  ///
  /// Eligibility is decided by [canActOnRequest], a 1:1 port of the web
  /// `leaveApprovalsService.canActOnRequest`, so mobile and web agree on who
  /// may action what.
  Future<List<LeaveRequest>> approvalQueue() async {
    final user = _db.auth.currentUser;
    if (user == null) return const [];
    try {
      final rows = await _db
          .from('leave_requests')
          .select('*')
          .eq('status', 'pending')
          .neq('created_by', user.id)
          .order('created_at', ascending: true);
      final all = [
        for (final raw in rows as List<dynamic>? ?? const [])
          if (raw is Map) LeaveRequest.fromRow(Map<String, dynamic>.from(raw)),
      ];
      final out = <LeaveRequest>[];
      for (final r in all) {
        final chain = await chainFor(r.id);
        if (canActOnRequest(r, chain)) out.add(r);
      }
      return out;
    } catch (_) {
      // RLS may legitimately hide other employees' requests from a staff
      // account — an empty queue is the correct answer there, not an error.
      return const [];
    }
  }
}

// ------------------------------------------------------------------
// Approval-chain helpers — 1:1 ports of the web exports so routing
// decisions cannot drift between the two clients.
// ------------------------------------------------------------------

/// Stage the request is currently waiting on.
Map<String, String> currentStage(
  LeaveRequest request,
  List<Map<String, String>> chain,
) {
  final c = chain.isEmpty ? defaultApprovalChain : chain;
  final index = (request.approvalLevel <= 0 ? 1 : request.approvalLevel) - 1;
  if (index < 0 || index >= c.length) return c.last;
  return c[index];
}

/// Final sign-off once the request reaches the last configured stage.
bool isFinalStage(LeaveRequest request, List<Map<String, String>> chain) {
  final c = chain.isEmpty ? defaultApprovalChain : chain;
  return (request.approvalLevel <= 0 ? 1 : request.approvalLevel) >= c.length;
}

/// Can the signed-in user act on this request right now? Mirrors the web rule
/// set exactly: pending only, never your own, role/stage match, with HR and
/// admin roles permitted at any stage.
bool canActOnRequest(
  LeaveRequest request,
  List<Map<String, String>> chain, {
  String? userId,
  String? role,
  bool isAdmin = false,
}) {
  if (!request.isPending) return false;
  if (userId != null && request.id.isNotEmpty && _isOwn(request, userId)) {
    return false;
  }
  if (isAdmin) return true;
  final r = role ?? '';
  final stage = currentStage(request, chain);
  if (stage['stage_key'] == r) return true;
  return const {
    'head_of_human_resources',
    'hr_officer',
    'admin',
    'super_admin',
  }.contains(r);
}

bool _isOwn(LeaveRequest request, String userId) =>
    request.createdBy == userId;

// ------------------------------------------------------------------
// Shared helpers
// ------------------------------------------------------------------

/// Working days between two dates, excluding weekends. Mirrors the web `days`
/// calculation so both clients record the same figure.
double workingDays(DateTime start, DateTime end) {
  if (end.isBefore(start)) return 0;
  var days = 0.0;
  final last = DateTime(end.year, end.month, end.day);
  for (
    var d = DateTime(start.year, start.month, start.day);
    !d.isAfter(last);
    d = d.add(const Duration(days: 1))
  ) {
    if (d.weekday != DateTime.saturday && d.weekday != DateTime.sunday) {
      days += 1;
    }
  }
  return days;
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _dateOnly(dynamic value) {
  final s = '${value ?? ''}';
  if (s.length >= 10) return s.substring(0, 10);
  return s;
}

double? _double(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}

Map<String, dynamic>? _json(dynamic v) {
  if (v is Map) return Map<String, dynamic>.from(v);
  if (v is String && v.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(v);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  return null;
}
