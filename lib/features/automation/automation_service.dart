// ============================================================================
// Automation Command Centre — service
// ============================================================================
// Reads the SAME backend as the web Automation Command Centre:
// the `get_automation_portfolio()` RPC (web: src/services/auditService.js).
//
// This is a TRACKER, not a report, and the data model is not duplicated here.
// Every percentage is DERIVED server-side from that department's real
// automation_items rows (live = 1.0, in progress = 0.5, not started = 0), and
// there is no stored percentage anywhere. So mobile shows exactly what web
// shows, because both are reading the same derived numbers.
//
// READ-ONLY ON MOBILE, BY DESIGN
// Status editing is a web capability and stays there. The server agrees: the
// sibling `set_automation_item_status` RPC refuses callers without
// `automation.portfolio.manage` (verified live — it raises
// AUTOMATION_FORBIDDEN). Editing a cross-department tracking register is a
// deliberate, auditable act; it does not belong in a pocket workflow. This
// client therefore has no write path at all rather than a write path that
// quietly fails on most accounts.
//
// No service-role key, no secret, no direct table access.
import '../../core/services/supabase_service.dart';

class AutomationException implements Exception {
  final String message;
  const AutomationException(this.message);
  @override
  String toString() => message;
}

/// Lifecycle status of a tracked automation item.
///
/// Mirrors the web `AUTOMATION_STATUS` and the database CHECK constraint.
enum AutomationStatus {
  notStarted('not_started', 'Not started'),
  inProgress('in_progress', 'In progress'),
  live('live', 'Live');

  const AutomationStatus(this.wire, this.label);

  /// The value as stored in the database.
  final String wire;
  final String label;

  static AutomationStatus parse(Object? v) {
    final s = v?.toString();
    for (final status in AutomationStatus.values) {
      if (status.wire == s) return status;
    }
    return AutomationStatus.notStarted;
  }
}

/// Loose int coercion for JSONB numerics, which PostgREST may hand back as
/// int, double or string depending on the column type.
int _int(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

double? _doubleOrNull(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// One department's row in the automation portfolio.
///
/// [completionPct] arrives pre-computed. It is deliberately NOT recomputed on
/// the client: the weighting rule is a business decision that lives in one
/// place, the database, and duplicating it here is exactly how two platforms
/// end up showing different percentages for the same department.
class AutomationDepartment {
  const AutomationDepartment(this.raw);

  final Map<String, dynamic> raw;

  String get key => raw['department']?.toString() ?? '';
  String get label => raw['label']?.toString() ?? key;
  String get description => raw['description']?.toString() ?? '';

  int get total => _int(raw['total']);
  int get live => _int(raw['live']);
  int get inProgress => _int(raw['in_progress']);
  int get notStarted => _int(raw['not_started']);

  /// Null when the server sent no percentage, so "not measured" never renders
  /// as 0%.
  double? get completionPct => _doubleOrNull(raw['completion_pct']);

  bool get isConfigurable => raw['is_configurable'] == true;
  int get displayOrder => _int(raw['display_order']);
}

/// One tracked automation line item.
class AutomationItem {
  const AutomationItem(this.raw);

  final Map<String, dynamic> raw;

  String get key => raw['item_key']?.toString() ?? '';
  String get label => raw['label']?.toString() ?? '';
  String get description => raw['description']?.toString() ?? '';
  String get department => raw['department']?.toString() ?? '';
  AutomationStatus get status => AutomationStatus.parse(raw['status']);

  DateTime? get liveAt {
    final v = raw['live_at']?.toString();
    if (v == null || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toLocal();
  }
}

/// One automation-sourced task assigned to a person.
///
/// This is what an executive raises against the automation specialist. It comes
/// from `work_tasks` filtered to `source = 'automation_centre'`, so it is
/// deliberately separate from the ACC's own portfolio percentages.
class AutomationTask {
  const AutomationTask(this.raw);

  final Map<String, dynamic> raw;

  String get id => raw['id']?.toString() ?? '';
  String get title => raw['title']?.toString() ?? '';
  String get description => raw['description']?.toString() ?? '';
  String get department => raw['department']?.toString() ?? '';
  String get status => raw['status']?.toString() ?? 'open';
  String get assigneeUserId => raw['assigned_to_user_id']?.toString() ?? '';
  String get automationItemId => raw['automation_item_id']?.toString() ?? '';

  DateTime? get dueDate {
    final v = raw['due_date']?.toString();
    if (v == null || v.isEmpty) return null;
    return DateTime.tryParse(v);
  }

  /// Null rather than 0 when the server sent nothing, so "not reported" never
  /// renders as "no progress".
  double? get progressPct => _doubleOrNull(raw['progress_pct']);

  bool get isOverdue {
    final due = dueDate;
    if (due == null) return false;
    final terminal = const {'completed', 'cancelled', 'closed'};
    if (terminal.contains(status.toLowerCase())) return false;
    return due.isBefore(DateTime.now());
  }

  bool get isOpen => !const {
    'completed',
    'cancelled',
    'closed',
  }.contains(status.toLowerCase());
}

/// The full portfolio payload.
class AutomationPortfolio {
  const AutomationPortfolio({
    required this.departments,
    required this.items,
    required this.activeWorkflows,
    required this.totalItems,
    required this.totalLive,
  });

  final List<AutomationDepartment> departments;
  final List<AutomationItem> items;
  final List<AutomationItem> activeWorkflows;
  final int totalItems;
  final int totalLive;

  /// Items belonging to [department], in the order the server returned them.
  List<AutomationItem> itemsFor(String department) =>
      items.where((i) => i.department == department).toList(growable: false);

  /// Items for a department, resolved against the human label when the raw key
  /// is all that is available.
  List<AutomationItem> itemsForDepartment(AutomationDepartment d) =>
      itemsFor(d.key.isNotEmpty ? d.key : d.label);
}

class AutomationService {
  const AutomationService._();

  static final AutomationService instance = AutomationService._();

  /// The automation portfolio. Same RPC, same derived percentages as web.
  Future<AutomationPortfolio> portfolio() async {
    final res = await SupabaseService.client.rpc('get_automation_portfolio');

    if (res is Map<String, dynamic> && res['ok'] == false) {
      throw AutomationException(
        '${res['message'] ?? 'Unable to load the automation portfolio'}',
      );
    }
    if (res is! Map) {
      throw const AutomationException(
        'The server returned an unexpected response.',
      );
    }

    final map = Map<String, dynamic>.from(res);
    final totals = map['totals'] is Map
        ? Map<String, dynamic>.from(map['totals'] as Map)
        : <String, dynamic>{};

    List<Map<String, dynamic>> rows(Object? v) {
      if (v is! List) return const [];
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }

    return AutomationPortfolio(
      departments: rows(map['departments'])
          .map(AutomationDepartment.new)
          .toList(growable: false),
      items: rows(map['items']).map(AutomationItem.new).toList(growable: false),
      activeWorkflows: rows(map['active_workflows'])
          .map(AutomationItem.new)
          .toList(growable: false),
      totalItems: _int(totals['items']),
      totalLive: _int(totals['live']),
    );
  }

  // --------------------------------------------------------------------------
  // MY WORK
  // --------------------------------------------------------------------------

  /// Whether the signed-in account may raise an automation task against someone.
  ///
  /// Read from the server's `can_assign_automation_task()` rather than a local
  /// role list, so the menu can never offer an action the RPC would refuse.
  /// A failed read is treated as "cannot", which fails closed.
  Future<bool> canAssign() async {
    try {
      final res = await SupabaseService.client.rpc('can_assign_automation_task');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  /// Automation tasks assigned to the signed-in person.
  ///
  /// Scoped on the server to `source = 'automation_centre'`, so this is the
  /// automation specialist's own queue and never another team's work.
  Future<List<AutomationTask>> myWork() async {
    final res = await SupabaseService.client.rpc('get_my_automation_work');
    if (res is Map<String, dynamic> && res['ok'] == false) {
      throw AutomationException(
        '${res['message'] ?? 'Unable to load your automation work'}',
      );
    }
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((e) => AutomationTask(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  // --------------------------------------------------------------------------
  // ASSIGNMENT
  // --------------------------------------------------------------------------

  /// Raise an automation task against a department or item.
  ///
  /// Goes through `assign_automation_work_task`, which is the ONLY path that can
  /// create an automation-sourced task. The general `create_work_task_with_steps`
  /// RPC is deliberately not used: widening it would hand these roles the
  /// ability to create any task for any person.
  ///
  /// [assigneeUserId] defaults to the caller, which is how a specialist raises
  /// their OWN work — the server allows that for every signed-in account.
  Future<void> assignWorkTask({
    required String department,
    required String label,
    String? description,
    String? assigneeUserId,
    DateTime? dueDate,
    int slaReviewHours = 48,
    String? automationItemId,
  }) async {
    if (department.trim().isEmpty) {
      throw const AutomationException('Choose a department.');
    }
    if (label.trim().isEmpty) {
      throw const AutomationException('Enter a task title.');
    }

    final res = await SupabaseService.client.rpc(
      'assign_automation_work_task',
      params: {
        'p_department': department.trim(),
        'p_label': label.trim(),
        'p_description': (description ?? '').trim().isEmpty
            ? null
            : description!.trim(),
        'p_assignee_user_id': assigneeUserId,
        'p_due_date': dueDate == null
            ? null
            : '${dueDate.year.toString().padLeft(4, '0')}-'
                  '${dueDate.month.toString().padLeft(2, '0')}-'
                  '${dueDate.day.toString().padLeft(2, '0')}',
        'p_sla_review_hours': slaReviewHours,
        'p_automation_item_id': automationItemId,
      },
    );

    if (res is Map<String, dynamic> && res['ok'] == false) {
      throw AutomationException(
        '${res['message'] ?? 'The server refused this assignment'}',
      );
    }
  }
}
