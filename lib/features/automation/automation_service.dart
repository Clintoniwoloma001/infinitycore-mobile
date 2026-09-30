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
}
