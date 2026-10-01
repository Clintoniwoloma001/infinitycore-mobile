// ============================================================================
// Director executive intelligence — service
// ============================================================================
// The mobile Director experience consumes the SAME backend RPC as the web
// Director dashboard: get_director_executive_snapshot / get_director_employee_detail.
//
// That is deliberate and is the whole parity guarantee. Tenure, KPI
// completion, target completion, attendance rate and department completion are
// all computed once, server-side. This file re-formats those numbers for
// display and never recomputes one of them, so the two clients cannot drift
// apart and disagree about the same employee, branch or period.
//
// No service-role key, no secret, no direct table access: everything goes
// through the same RLS-protected, role-gated RPCs the web uses.
import '../../core/services/supabase_service.dart';

class DirectorException implements Exception {
  final String message;
  const DirectorException(this.message);
  @override
  String toString() => message;
}

class DirectorPeriod {
  final DateTime from;
  final DateTime to;
  final String label;
  const DirectorPeriod(this.from, this.to, this.label);

  static String toIso(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year.toString().padLeft(4, '0')}-$m-$day';
  }

  /// Periods mirror the web dashboard exactly.
  static DirectorPeriod today() {
    final n = DateTime.now();
    return DirectorPeriod(n, n, 'Today');
  }

  /// Never let a period run past today.
  ///
  /// `get_director_executive_snapshot` rejects any range whose end date is in
  /// the future (`v_end > current_date` -> 'Invalid executive reporting
  /// period'), so a naive "this month = 1st to the last day of the month"
  /// fails on every day except the last one. The server's own default is
  /// `coalesce(p_end_date, current_date)`, which confirms that month-to-date is
  /// the intended meaning: there is no data for a future date to return.
  static DateTime _notAfterToday(DateTime end) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return end.isAfter(today) ? today : end;
  }

  static DirectorPeriod thisWeek() {
    final n = DateTime.now();
    final start = DateTime(
      n.year,
      n.month,
      n.day,
    ).subtract(Duration(days: n.weekday - 1));
    return DirectorPeriod(
      start,
      _notAfterToday(start.add(const Duration(days: 6))),
      'This week',
    );
  }

  static DirectorPeriod thisMonth() {
    final n = DateTime.now();
    return DirectorPeriod(
      DateTime(n.year, n.month),
      _notAfterToday(DateTime(n.year, n.month + 1, 0)),
      'This month',
    );
  }

  static DirectorPeriod thisQuarter() {
    final n = DateTime.now();
    final q = ((n.month - 1) ~/ 3) * 3 + 1;
    return DirectorPeriod(
      DateTime(n.year, q),
      _notAfterToday(DateTime(n.year, q + 3, 0)),
      'This quarter',
    );
  }

  /// A custom range is clamped for the same reason: an end date after today is
  /// guaranteed to be rejected, and there are no records for it to return.
  static DirectorPeriod custom(DateTime from, DateTime to) =>
      DirectorPeriod(from, _notAfterToday(to), 'Custom');
}

/// Thin typed view over the RPC payload. Fields are read defensively because a
/// partially-populated snapshot must render, not crash.
class DirectorSnapshot {
  final Map<String, dynamic> raw;
  const DirectorSnapshot(this.raw);

  Map<String, dynamic> get summary => asMap(raw['summary']);
  List<Map<String, dynamic>> get departments => asList(raw['departments']);
  List<Map<String, dynamic>> get staff => asList(raw['staff']);
  List<Map<String, dynamic>> get branches => asList(raw['branches']);
  List<Map<String, dynamic>> get areas => asList(raw['areas']);
  List<Map<String, dynamic>> get leave => asList(raw['leave']);
  List<Map<String, dynamic>> get roles => asList(raw['roles']);
  Map<String, dynamic> get trend => asMap(raw['trend']);
  Map<String, dynamic> get loans => asMap(raw['loans']);
  Map<String, dynamic> get filters => asMap(raw['filters']);
}

Map<String, dynamic> asMap(Object? v) =>
    v is Map<String, dynamic> ? v : <String, dynamic>{};

List<Map<String, dynamic>> asList(Object? v) {
  if (v is! List) return const [];
  return v.whereType<Map<String, dynamic>>().toList(growable: false);
}

/// Org-wide attendance totals for one reporting window.
///
/// The server's `summary.absent` is NOT an absence count. It is
/// `SUM(expected_days) - SUM(attendance_present)` across the whole roster, and
/// `expected_days` is a fixed 20 per employee that does NOT scale with the
/// requested window. On the 211-person production roster that surfaced as
/// "Absent 4220" (= 211 x 20) for a single day.
///
/// 4220 is therefore an attendance-DAY count, and showing it next to a label
/// like "Absent" invited the reading "4220 people are absent", which is
/// nonsense for a 211-person roster. Two defensible fixes exist: label it as
/// days ("4220 expected days across 211 staff"), or count PEOPLE. This class
/// implements the second, because "how many of my staff are absent today?" is
/// the question an executive is actually asking, and a headcount is
/// unambiguous - it can never exceed the size of the roster.
///
/// Both bases are computed so a caller can show whichever the screen needs.
/// `presentDays`/`absentDays` remain available for a day-weighted view.
class AttendanceTotals {
  const AttendanceTotals({
    required this.totalStaff,
    required this.presentStaff,
    required this.absentStaff,
    required this.expectedDays,
    required this.presentDays,
    required this.absentDays,
    required this.rate,
  });

  /// Everyone in the roster for this window, present or not. The denominator
  /// for every headcount below, so no figure can exceed it.
  final int totalStaff;

  /// STAFF (not days) with at least one present day in the window.
  final int presentStaff;

  /// STAFF who never registered attendance across the window.
  final int absentStaff;

  /// Attendance slots the roster was expected to fill in the window.
  final int expectedDays;

  /// Slots actually filled.
  final int presentDays;

  /// Slots left unfilled. Never negative, even if the server over-reports.
  final int absentDays;

  /// [presentDays] / [expectedDays] as a percentage. Zero when nothing was
  /// expected, so "no data" cannot render as a divide-by-zero.
  final double rate;

  static AttendanceTotals fromStaff(List<Map<String, dynamic>> staff) {
    var expected = 0;
    var present = 0;
    var presentStaff = 0;
    for (final p in staff) {
      expected += _asInt(p['expected_days']);
      final pDays = _asInt(p['attendance_present']);
      present += pDays;
      // A person counts as present if they worked at least one day in the
      // window. `> 0` rather than `== expected`, so a partly-attending person
      // is not counted as absent.
      if (pDays > 0) presentStaff++;
    }
    final total = staff.length;
    final absentStaff = (total - presentStaff).clamp(0, total);
    final absent = expected - present;
    return AttendanceTotals(
      totalStaff: total,
      presentStaff: presentStaff,
      absentStaff: absentStaff,
      expectedDays: expected,
      presentDays: present,
      absentDays: absent < 0 ? 0 : absent,
      rate: expected == 0 ? 0 : (present / expected) * 100,
    );
  }

  static int _asInt(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}'.trim()) ?? 0;
  }
}

class DirectorService {
  const DirectorService._();

  static final DirectorService instance = DirectorService._();

  /// The executive snapshot. Same RPC, same parameters, same numbers as web.
  Future<DirectorSnapshot> snapshot({
    DateTime? from,
    DateTime? to,
    String? department,
    String? area,
    String? role,
    String? employeeId,
  }) async {
    final res = await SupabaseService.client.rpc(
      'get_director_executive_snapshot',
      params: <String, dynamic>{
        if (from != null) 'p_start_date': DirectorPeriod.toIso(from),
        if (to != null) 'p_end_date': DirectorPeriod.toIso(to),
        if (department != null && department.isNotEmpty)
          'p_department': department,
        if (area != null && area.isNotEmpty) 'p_area': area,
        if (role != null && role.isNotEmpty) 'p_role': role,
        if (employeeId != null && employeeId.isNotEmpty)
          'p_employee_id': employeeId,
      },
    );
    if (res is Map<String, dynamic> && res['ok'] == false) {
      throw DirectorException(
        '${res['message'] ?? 'Unable to load executive data'}',
      );
    }
    if (res is! Map) {
      throw const DirectorException(
        'The server returned an unexpected response.',
      );
    }
    return DirectorSnapshot(Map<String, dynamic>.from(res));
  }

  /// Executive employee profile. The tenure, attendance, KPI and target figures
  /// here are computed server-side, so this screen cannot disagree with the web
  /// employee detail for the same person.
  Future<Map<String, dynamic>> employeeDetail(String employeeId) async {
    final res = await SupabaseService.client.rpc(
      'get_director_employee_detail',
      params: <String, dynamic>{'p_employee_id': employeeId},
    );
    if (res is Map<String, dynamic> && res['ok'] == false) {
      throw DirectorException('${res['message'] ?? 'Unable to load employee'}');
    }
    if (res is! Map) {
      throw const DirectorException(
        'The server returned an unexpected response.',
      );
    }
    return Map<String, dynamic>.from(res);
  }
}

// ---------------------------------------------------------------------------
// Presentation-only formatting. No business formula lives here: every number
// displayed has already been computed by the server.
int? asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

String? text(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

/// "12 years 4 months in the business".
///
/// Formatted ONLY from a tenure the server supplied. If the server sent none,
/// this returns null rather than deriving one from a join date this client has
/// not been given - which is what keeps web and mobile showing the same figure.
String? tenureLabel(Map<String, dynamic> person) {
  final years = asInt(person['tenure_years']);
  final months = asInt(person['tenure_months']);
  if (years == null && months == null) return text(person['tenure']);
  final y = years ?? 0;
  final m = months ?? 0;
  if (y <= 0 && m <= 0) return 'Less than a month in the business';
  final parts = <String>[];
  if (y > 0) parts.add('$y ${y == 1 ? 'year' : 'years'}');
  if (m > 0) parts.add('$m ${m == 1 ? 'month' : 'months'}');
  return '${parts.join(' ')} in the business';
}

/// Percentage that renders as null when the server sent nothing, so an absent
/// figure is never displayed as zero.
String? percent(Object? v, {int decimals = 0}) {
  final d = asDouble(v);
  if (d == null) return null;
  return '${d.toStringAsFixed(decimals)}%';
}

/// "₦42.0M" - compact money for scorecards. Returns null when there is no
/// figure, so a missing value is never rendered as ₦0.
String? compactMoney(Object? v) {
  final d = asDouble(v);
  if (d == null) return null;
  if (d.abs() >= 1000000) return '₦${(d / 1000000).toStringAsFixed(1)}M';
  if (d.abs() >= 1000) return '₦${(d / 1000).toStringAsFixed(1)}k';
  return '₦${d.toStringAsFixed(0)}';
}
