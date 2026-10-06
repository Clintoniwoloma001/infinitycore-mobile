import '../../core/services/supabase_service.dart';

/// MPR performance models and the client for the two server RPCs added in
/// migration 20261101000008.
///
/// THE ONE RULE THIS FILE ENFORCES
/// An MPR score is only ever produced for a person whose disbursement, PAR and
/// caseload are ALL measured. The server (`compute_mpr_score`) already refuses
/// to return a total/grade unless `complete` is true, and this client refuses
/// to invent one. An unmeasured employee appears as "Unmeasured — excluded
/// from ranking", never as a score of 0 and never in a Drag list.
///
/// This matters because these figures are used to appraise real bank staff. A
/// fabricated zero would silently drag somebody down a leaderboard because
/// nobody had entered their numbers yet.
///
/// Grade colours mirror the spec and the SQL `mpr_grade_for_score()` table,
/// which the web `mprEngine.js` also mirrors. The server sends `grade_hex`
/// through; [MprGrade.hex] is only a fallback for when it does not.
enum MprGrade {
  a('A', 'Exceptional', 0xFF10B981),
  b('B', 'Very good', 0xFF059669),
  c('C', 'Acceptable', 0xFFF59E0B),
  d('D', 'Needs improvement', 0xFFF97316),
  e('E', 'Unsatisfactory', 0xFFEF4444);

  const MprGrade(this.letter, this.rating, this.hex);

  final String letter;
  final String rating;
  final int hex;

  /// Resolves the server's grade letter, or null when absent/unrecognised.
  static MprGrade? fromLetter(String? letter) {
    if (letter == null) return null;
    for (final g in MprGrade.values) {
      if (g.letter == letter.trim().toUpperCase()) return g;
    }
    return null;
  }
}

/// One person's MPR evaluation for one period.
class StaffMprSummary {
  const StaffMprSummary({
    required this.employeeId,
    required this.employeeName,
    required this.branchName,
    required this.periodLabel,
    required this.complete,
    required this.missing,
    this.total,
    this.subtotal,
    this.grade,
    this.gradeRating = '',
    this.parPercent,
    this.atRiskPrincipal,
    this.disbursementScore,
    this.parScore,
    this.caseloadScore,
    this.bankParRatio,
  });

  factory StaffMprSummary.fromJson(Map<String, dynamic> j) {
    final letter = (j['grade'] ?? '').toString();
    return StaffMprSummary(
      employeeId: (j['employee_id'] ?? '').toString(),
      employeeName: (j['employee_name'] ?? '').toString(),
      branchName: (j['branch_name'] ?? '').toString(),
      periodLabel: (j['period_label'] ?? '').toString(),
      complete: j['complete'] == true,
      missing: [
        for (final m in (j['missing'] as List? ?? const [])) '$m'.toString(),
      ],
      total: (j['total'] as num?)?.toDouble(),
      subtotal: (j['subtotal'] as num?)?.toDouble(),
      grade: MprGrade.fromLetter(letter.isEmpty ? null : letter),
      gradeRating: (j['grade_rating'] ?? '').toString(),
      parPercent: (j['par_percent'] as num?)?.toDouble(),
      atRiskPrincipal: (j['at_risk_principal'] as num?)?.toDouble(),
      disbursementScore: (j['disbursement_score'] as num?)?.toDouble(),
      parScore: (j['par_score'] as num?)?.toDouble(),
      caseloadScore: (j['caseload_score'] as num?)?.toDouble(),
      bankParRatio: (j['bank_par_ratio'] as num?)?.toDouble(),
    );
  }

  final String employeeId;
  final String employeeName;
  final String branchName;
  final String periodLabel;

  /// True only when all three metrics are measured.
  final bool complete;

  /// Which metrics are missing, e.g. `['par', 'caseload']`.
  final List<String> missing;

  final double? total;
  final double? subtotal;
  final MprGrade? grade;
  final String gradeRating;
  final double? parPercent;
  final double? atRiskPrincipal;
  final double? disbursementScore;
  final double? parScore;
  final double? caseloadScore;

  /// The ORGANISATION-WIDE PAR benchmark. Not this person's PAR, and not
  /// their branch's — the snapshot table has no branch dimension.
  final double? bankParRatio;

  /// The score to display. Null whenever incomplete, so a UI cannot
  /// accidentally render a partial score as if it were final.
  double? get displayScore => complete ? total : null;

  /// Badge copy. Incomplete people get the explicit exclusion wording the
  /// spec asks for rather than a blank or a zero.
  String get badgeLabel {
    if (!complete) return 'Unmeasured — excluded from ranking';
    final g = grade;
    if (g == null) return 'Graded $displayScore';
    return '${g.letter} · ${gradeRating.isEmpty ? g.rating : gradeRating}';
  }

  /// Human-readable reason the score is absent.
  String get missingLabel {
    if (missing.isEmpty) return 'Awaiting measurement';
    final pretty = missing.map((m) {
      switch (m) {
        case 'disbursement':
          return 'disbursement';
        case 'par':
          return 'PAR';
        case 'caseload':
          return 'caseload';
        default:
          return m;
      }
    }).toList();
    if (pretty.length == 1) return 'Not measured: ${pretty.first}';
    return 'Not measured: ${pretty.take(pretty.length - 1).join(', ')} '
        'and ${pretty.last}';
  }
}

/// One row of the branch ranking. Every row here is already `complete` on the
/// server; unmeasured staff never reach this list at all.
class RankedStaff {
  const RankedStaff({
    required this.employeeId,
    required this.employeeName,
    required this.total,
    this.parPercent,
    this.atRiskPrincipal,
    this.passWatchPrincipal,
    this.disbursementActual,
    this.disbursementTarget,
    this.caseloadActual,
    this.grade,
    this.gradeRating = '',
    this.shareOfBranchMprPct,
  });

  factory RankedStaff.fromJson(Map<String, dynamic> j) {
    final letter = (j['grade'] ?? '').toString();
    return RankedStaff(
      employeeId: (j['id'] ?? '').toString(),
      employeeName: (j['full_name'] ?? '').toString(),
      total: (j['total'] as num?)?.toDouble() ?? 0,
      parPercent: (j['par_percent'] as num?)?.toDouble(),
      atRiskPrincipal: (j['at_risk_principal'] as num?)?.toDouble(),
      passWatchPrincipal: (j['pass_watch_principal'] as num?)?.toDouble(),
      disbursementActual: (j['disbursement_actual'] as num?)?.toDouble(),
      disbursementTarget: (j['disbursement_target'] as num?)?.toDouble(),
      caseloadActual: (j['caseload_actual'] as num?)?.toDouble(),
      grade: MprGrade.fromLetter(letter.isEmpty ? null : letter),
      gradeRating: (j['grade_rating'] ?? '').toString(),
      shareOfBranchMprPct: (j['share_of_branch_mpr_pct'] as num?)?.toDouble(),
    );
  }

  final String employeeId;
  final String employeeName;
  final double total;
  final double? parPercent;
  final double? atRiskPrincipal;
  final double? passWatchPrincipal;
  final double? disbursementActual;
  final double? disbursementTarget;
  final double? caseloadActual;
  final MprGrade? grade;
  final String gradeRating;

  /// Share of the SUM of measured staff totals, 0..100.
  final double? shareOfBranchMprPct;

  /// Plain-language root cause for a drag row, derived from what is actually
  /// present in the row rather than invented.
  ///
  /// Ordering is deliberate: non-performing exposure is the most serious and
  /// is checked first, then a disbursement shortfall, then a thinning
  /// caseload. Returns null when nothing stands out, so the UI omits the
  /// callout rather than showing a generic one.
  String? get rootCause {
    final par = parPercent;
    final atRisk = atRiskPrincipal ?? 0;
    if (par != null && par > 5.0) {
      final pw = passWatchPrincipal;
      return pw != null && pw > 0
          ? 'High delinquency — ${par.toStringAsFixed(1)}% PAR with '
                '${_money(pw)} in 1–30 day Pass & Watch'
          : 'High delinquency — ${par.toStringAsFixed(1)}% PAR '
                '(${_money(atRisk)} at risk)';
    }
    final actual = disbursementActual;
    final target = disbursementTarget;
    if (actual != null && target != null && target > 0 && actual < target) {
      final gap = ((target - actual) / target) * 100;
      return 'Missed disbursement — ${_money(actual)} of '
          '${_money(target)} (${gap.toStringAsFixed(0)}% short)';
    }
    final cases = caseloadActual;
    if (cases != null && cases <= 0) {
      return 'Caseload decay — no active clients recorded';
    }
    return null;
  }

  /// Boost copy for a soaring row.
  String? get boostNote {
    final share = shareOfBranchMprPct;
    if (share == null || share <= 0) return null;
    final actual = disbursementActual;
    return actual != null
        ? 'Drives ${share.toStringAsFixed(1)}% of measured branch MPR with '
              '${_money(actual)} disbursed'
        : 'Drives ${share.toStringAsFixed(1)}% of measured branch MPR';
  }

  /// ₦ with thousands separators, or a dash when the figure is unknown.
  static String _money(double? v) {
    if (v == null) return '—';
    final n = v.round().abs();
    final s = n.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (m) => '${m[1]},',
    );
    final sign = v < 0 ? '-' : '';
    return '$sign₦$s';
  }
}

/// A branch's Drag 5 / Soaring 5 ranking, plus the coverage that makes the
/// ranking honest.
class BranchAttribution {
  const BranchAttribution({
    required this.branchId,
    required this.branchName,
    required this.periodLabel,
    required this.headcount,
    required this.measuredCount,
    required this.coveragePct,
    required this.ranked,
  });

  factory BranchAttribution.fromJson(Map<String, dynamic> j) {
    final raw = j['staff'];
    final rows = raw is List
        ? raw
              .whereType<Map>()
              .map((e) => RankedStaff.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
        : const <RankedStaff>[];
    return BranchAttribution(
      branchId: (j['branch_id'] ?? '').toString(),
      branchName: (j['branch_name'] ?? '').toString(),
      periodLabel: (j['period_label'] ?? '').toString(),
      headcount: (j['headcount'] as num?)?.toInt() ?? 0,
      measuredCount: (j['measured_count'] as num?)?.toInt() ?? 0,
      coveragePct: (j['coverage_pct'] as num?)?.toDouble(),
      // The server returns ascending order; reverse once here so both the
      // Soaring and Drag views read off the same sorted list.
      ranked: rows.reversed.toList(growable: false),
    );
  }

  final String branchId;
  final String branchName;
  final String periodLabel;

  /// Everyone on the branch's books.
  final int headcount;

  /// How many of them actually have all three metrics measured.
  final int measuredCount;

  final double? coveragePct;

  /// Best score first.
  final List<RankedStaff> ranked;

  /// The top five. May be shorter than five, or empty — that is a real
  /// finding, not something to pad.
  List<RankedStaff> get soaring5 => ranked.take(5).toList(growable: false);

  /// The bottom five, worst first.
  List<RankedStaff> get drag5 =>
      ranked.reversed.take(5).toList(growable: false);

  bool get isEmpty => ranked.isEmpty;

  /// How many of the branch have no score at all. Surfaced prominently so the
  /// ranking is never read as covering the whole branch.
  int get unmeasuredCount => (headcount - measuredCount).clamp(0, headcount);

  /// "12 of 34 staff measured" — the coverage banner copy.
  String get coverageLabel => '$measuredCount of $headcount staff measured';
}

/// Client for the server-authoritative MPR RPCs.
///
/// Both calls return the server's own verdict; nothing is scored on the
/// device. The server decides `complete`, the grade band and the ranking, so
/// mobile, web and the database can never disagree about a person's MPR.
class MprService {
  const MprService._();

  static final MprService instance = MprService._();

  /// MPR for one employee in one period.
  ///
  /// Throws [MprException] when the server reports a problem. A returned
  /// summary with `complete == false` is a SUCCESS, not a failure: it means the
  /// server answered honestly and the data is not there yet.
  Future<StaffMprSummary> summary({
    required String employeeId,
    required String periodLabel,
    String? branchId,
  }) async {
    final res = await SupabaseService.client.rpc(
      'rpc_get_staff_mpr_summary',
      params: {
        'p_employee_id': employeeId,
        'p_period_label': periodLabel,
        'p_branch_id': branchId,
      },
    );
    final j = _asMap(res);
    if (j['ok'] != true) {
      throw MprException('${j['message'] ?? 'Unable to load MPR summary'}');
    }
    return StaffMprSummary.fromJson(j);
  }

  /// Drag 5 / Soaring 5 for one branch in one period.
  Future<BranchAttribution> branchAttribution({
    required String branchId,
    required String periodLabel,
  }) async {
    final res = await SupabaseService.client.rpc(
      'rpc_get_branch_drag_and_soaring_staff',
      params: {'p_branch_id': branchId, 'p_period_label': periodLabel},
    );
    final j = _asMap(res);
    if (j['ok'] != true) {
      throw MprException(
        '${j['message'] ?? 'Unable to load branch attribution'}',
      );
    }
    return BranchAttribution.fromJson(j);
  }

  static Map<String, dynamic> _asMap(dynamic res) {
    if (res is Map) return Map<String, dynamic>.from(res);
    throw const MprException('The server returned an unexpected response.');
  }
}

/// True when [value] is a UUID — the shape `p_branch_id uuid` requires.
///
/// Postgres rejects anything else with `invalid input syntax for type uuid`,
/// a raw engine error that quotes the bad value (for example a branch NAME
/// where a branch UUID was expected) and reads like a crash to the user.
/// Callers validate first so that error can never reach a screen.
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}'
  r'-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

bool isUuid(String value) => _uuidPattern.hasMatch(value.trim());

class MprException implements Exception {
  const MprException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Maps a reporting window onto the `mpr_targets.period_label` key that MPR
/// actuals are stored under.
///
/// THE HONEST CAVEAT, and it matters: `period_label` is a free-text key that
/// HR/FINCON chooses when entering actuals. This derives the most likely
/// canonical form ('2026-05' for a month, '2026-Q2' for a quarter), but if the
/// bank entered its numbers under a different string the query simply returns
/// nothing. There is no server-side mapping table to consult, and inventing a
/// fallback that silently showed a neighbouring period's numbers would be worse
/// than showing an honest empty state — so the UI states the exact label it
/// queried and lets the user act on that.
class MprPeriod {
  const MprPeriod._();

  /// A month key for a window that sits inside one calendar month.
  static String? monthLabel(DateTime from, DateTime to) {
    if (from.year != to.year || from.month != to.month) return null;
    return '${from.year}-${from.month.toString().padLeft(2, '0')}';
  }

  /// A quarter key for a window that sits inside one calendar quarter.
  static String? quarterLabel(DateTime from, DateTime to) {
    if (from.year != to.year) return null;
    final qf = _quarter(from.month);
    final qt = _quarter(to.month);
    if (qf != qt) return null;
    return '${from.year}-Q$qf';
  }

  /// The best available key for a window, or null when it straddles a boundary
  /// and no single key can honestly represent it.
  static String? bestFor(DateTime from, DateTime to) =>
      monthLabel(from, to) ?? quarterLabel(from, to);

  static int _quarter(int month) => ((month - 1) ~/ 3) + 1;
}

