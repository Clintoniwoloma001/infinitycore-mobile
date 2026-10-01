import '../../shared/models/models.dart';

/// The period a staff analytics query covers.
///
/// HR needs the same attendance numbers expressed at several granularities, so
/// the period is modelled explicitly rather than as a loose date pair. Every
/// variant resolves to an inclusive [start]..[end] window, which is what the
/// server RPC expects.
enum AnalyticsPeriodType {
  day,
  week,
  month,
  quarter,
  year,
  custom,
}

/// How an attendance scorecard is scored.
///
/// The weights sum to 100, so the composite percentage is directly readable as
/// "this person scored 87% overall".
enum AttendanceMetricKind {
  attendance('Attendance', 30),
  punctuality('Punctuality', 25),
  hours('Hours worked', 25),
  geofence('Location compliance', 20);

  final String label;
  final double weight;

  const AttendanceMetricKind(this.label, this.weight);

  static double get totalWeight =>
      AttendanceMetricKind.values.fold(0.0, (sum, k) => sum + k.weight);
}

/// One employee's full attendance picture for a period.
class StaffAttendanceMetrics {
  final String employeeId;
  final String employeeName;
  final String employeeNumber;
  final String position;
  final String department;
  final String branchId;
  final String branchName;

  final int records;
  final int daysPresent;
  final int daysAbsent;
  final int lateDays;
  final int onTimeDays;
  final int geofenceViolations;
  final int incompleteDays;
  final double totalHours;
  final double averageHoursPerPresentDay;
  final int totalLateMinutes;

  /// Composite score, 0-100.
  final double score;

  final Map<AttendanceMetricKind, double> breakdown;

  const StaffAttendanceMetrics({
    required this.employeeId,
    this.employeeName = '',
    this.employeeNumber = '',
    this.position = '',
    this.department = '',
    this.branchId = '',
    this.branchName = '',
    this.records = 0,
    this.daysPresent = 0,
    this.daysAbsent = 0,
    this.lateDays = 0,
    this.onTimeDays = 0,
    this.geofenceViolations = 0,
    this.incompleteDays = 0,
    this.totalHours = 0,
    this.averageHoursPerPresentDay = 0,
    this.totalLateMinutes = 0,
    this.score = 0,
    this.breakdown = const {},
  });

  bool get hasData => records > 0;

  /// Sub-score for [kind], 0-100. 0 when there is nothing to score.
  double scoreFor(AttendanceMetricKind kind) =>
      breakdown[kind] ?? (hasData ? score : 0);

  /// Builds one person's metrics from their raw attendance rows.
  ///
  /// Rows are de-duplicated by date first, so a corrected clock-in that wrote a
  /// second row for the same day cannot inflate the day count. Every rate is
  /// guarded against a zero denominator: an employee with no records scores 0
  /// and is never credited with a perfect rate.
  factory StaffAttendanceMetrics.fromRows(
    List<AttendanceManagementRow> rows, {
    required AnalyticsPeriod period,
  }) {
    // Identity comes from the first row so a mid-period department change does
    // not produce a card describing an inconsistent mix of both.
    final sample = rows.isEmpty ? null : rows.first;

    final byDate = <String, AttendanceManagementRow>{};
    for (final r in rows) {
      if (r.attendanceDate.length < 10) continue;
      final key = r.attendanceDate.substring(0, 10);
      final existing = byDate[key];
      // Prefer the row that actually has a clock-out: that is the completed
      // record, and an open duplicate must not replace it.
      if (existing == null ||
          (existing.clockOut == null && r.clockOut != null)) {
        byDate[key] = r;
      }
    }
    final daily = byDate.values.toList();

    var present = 0;
    var absent = 0;
    var late = 0;
    var onTime = 0;
    var outside = 0;
    var incomplete = 0;
    var hours = 0.0;
    var lateMinutes = 0;

    for (final r in daily) {
      final status = r.status.toLowerCase();
      final hasIn = r.clockIn != null;
      final hasOut = r.clockOut != null;
      final worked = r.workHours > 0;

      if (hasIn || worked) {
        present++;
      } else if (status == 'absent' || status == 'leave') {
        absent++;
      }
      if (hasIn && !hasOut) incomplete++;
      if (hasIn) {
        if (r.lateMinutes > 0) {
          late++;
          lateMinutes += r.lateMinutes;
        } else {
          onTime++;
        }
      }
      // Outside every registered geofence. Only counted when the row actually
      // captured a position - an unknown location is not a violation.
      if (hasIn &&
          (r.geofenceStatus.toLowerCase() == 'outside' ||
              r.locationStatus.toLowerCase() == 'outside')) {
        outside++;
      }
      hours += worked ? r.workHours : 0;
    }

    final recordCount = daily.length;
    final attendanceRate =
        recordCount == 0 ? 0.0 : (present / recordCount) * 100;
    final punctualityRate = present == 0 ? 0.0 : (onTime / present) * 100;
    // Benchmark of a full 8-hour day, capped so a long day cannot score above
    // 100 on its own.
    final hoursScore = present == 0
        ? 0.0
        : ((hours / (present * 8)) * 100).clamp(0.0, 100.0).toDouble();
    final geofenceRate = present == 0
        ? 0.0
        : (((present - outside) / present) * 100).clamp(0.0, 100.0).toDouble();

    final breakdown = <AttendanceMetricKind, double>{
      AttendanceMetricKind.attendance: attendanceRate,
      AttendanceMetricKind.punctuality: punctualityRate,
      AttendanceMetricKind.hours: hoursScore,
      AttendanceMetricKind.geofence: geofenceRate,
    };

    final score = AttendanceMetricKind.totalWeight == 0
        ? 0.0
        : breakdown.entries.fold<double>(
                0,
                (sum, e) => sum + e.value * e.key.weight,
              ) /
            AttendanceMetricKind.totalWeight;

    return StaffAttendanceMetrics(
      employeeId: sample?.employeeId ?? '',
      employeeName: sample?.employeeName ?? '',
      employeeNumber: sample?.employeeNumber ?? '',
      position: sample?.position ?? '',
      department: sample?.department ?? '',
      branchId: sample?.branchId ?? '',
      branchName: sample?.branchName ?? '',
      records: recordCount,
      daysPresent: present,
      daysAbsent: absent,
      lateDays: late,
      onTimeDays: onTime,
      geofenceViolations: outside,
      incompleteDays: incomplete,
      totalHours: hours,
      averageHoursPerPresentDay: present == 0 ? 0 : hours / present,
      totalLateMinutes: lateMinutes,
      score: score.clamp(0.0, 100.0).toDouble(),
      breakdown: breakdown,
    );
  }

  @override
  String toString() =>
      'StaffAttendanceMetrics($employeeName, '
      'score: ${score.toStringAsFixed(1)}, present: $daysPresent, late: $lateDays)';
}

/// An inclusive reporting window plus how it was chosen.
class AnalyticsPeriod {
  final AnalyticsPeriodType type;
  final DateTime start;
  final DateTime end;
  final String label;

  const AnalyticsPeriod({
    required this.type,
    required this.start,
    required this.end,
    required this.label,
  });

  bool contains(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    final from = DateTime(start.year, start.month, start.day);
    final to = DateTime(end.year, end.month, end.day);
    return !day.isBefore(from) && !day.isAfter(to);
  }

  int get dayCount => end.difference(start).inDays + 1;

  /// Calendar quarter 1-4 for [d].
  ///
  /// Uses the 1-based month so Q1 is Jan-Mar. Guards the boundary: a
  /// zero-based month would shift every window by three months.
  static int quarterOf(DateTime d) => ((d.month - 1) ~/ 3) + 1;

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// Builds the canonical window for [type] around [anchor].
  ///
  /// [anchor] is any date inside the wanted period; only its month/quarter/year
  /// is read, so "September 2026" works whether the anchor is the 1st or the
  /// 30th. The day component is deliberately ignored — an end-of-month anchor
  /// must not clip the window.
  factory AnalyticsPeriod.of(
    AnalyticsPeriodType type,
    DateTime anchor, {
    DateTime? customStart,
    DateTime? customEnd,
  }) {
    DateTime at(DateTime d) => DateTime(d.year, d.month, d.day);

    switch (type) {
      case AnalyticsPeriodType.day:
        final d = at(anchor);
        return AnalyticsPeriod(
          type: type,
          start: d,
          end: d,
          label: _dayLabel(d),
        );
      case AnalyticsPeriodType.week:
        final d = at(anchor);
        // Monday-anchored week.
        final start = d.subtract(Duration(days: d.weekday - 1));
        final end = start.add(const Duration(days: 6));
        return AnalyticsPeriod(
          type: type,
          start: start,
          end: end,
          label: '${start.day}/${start.month} – ${end.day}/${end.month} ${end.year}',
        );
      case AnalyticsPeriodType.month:
        final start = DateTime(anchor.year, anchor.month, 1);
        // Month 13 rolls into January of the next year natively.
        final end = DateTime(anchor.year, anchor.month + 1, 0);
        return AnalyticsPeriod(
          type: type,
          start: start,
          end: end,
          label: '${_monthNames[anchor.month - 1]} ${anchor.year}',
        );
      case AnalyticsPeriodType.quarter:
        final q = quarterOf(anchor);
        final startMonth = (q - 1) * 3 + 1;
        final start = DateTime(anchor.year, startMonth, 1);
        final end = DateTime(anchor.year, startMonth + 3, 0);
        return AnalyticsPeriod(
          type: type,
          start: start,
          end: end,
          label: 'Q$q ${anchor.year}',
        );
      case AnalyticsPeriodType.year:
        return AnalyticsPeriod(
          type: type,
          start: DateTime(anchor.year, 1, 1),
          end: DateTime(anchor.year, 12, 31),
          label: '${anchor.year}',
        );
      case AnalyticsPeriodType.custom:
        final s = at(customStart ?? anchor);
        // A reversed range would silently return zero rows, so it is ordered
        // here rather than trusting the two pickers to agree.
        final e = at(customEnd ?? customStart ?? anchor);
        final (from, to) = s.isAfter(e) ? (e, s) : (s, e);
        return AnalyticsPeriod(
          type: type,
          start: from,
          end: to,
          label: '${from.day}/${from.month}/${from.year} – '
              '${to.day}/${to.month}/${to.year}',
        );
    }
  }

  static String _dayLabel(DateTime d) =>
      '${d.day} ${_monthNames[d.month - 1]} ${d.year}';
}

/// Aggregates every employee in a period and answers the HR questions:
/// per-person scorecards, 2-3 way comparison, and top-5 leaderboards.
class StaffAnalyticsReport {
  final AnalyticsPeriod period;
  final List<StaffAttendanceMetrics> all;

  const StaffAnalyticsReport({required this.period, this.all = const []});

  /// Builds a report from raw rows.
  ///
  /// Filtering happens on the row date, not on the range that was fetched, so a
  /// server that returns a slightly wider window cannot leak neighbouring days
  /// into the numbers.
  factory StaffAnalyticsReport.fromRows(
    List<AttendanceManagementRow> rows,
    AnalyticsPeriod period,
  ) {
    final inWindow = rows.where((r) {
      final date = DateTime.tryParse(r.attendanceDate);
      if (date == null) return false;
      return period.contains(date);
    }).toList();

    final grouped = <String, List<AttendanceManagementRow>>{};
    for (final r in inWindow) {
      final id = r.employeeId.isEmpty ? r.employeeName : r.employeeId;
      if (id.isEmpty) continue;
      grouped.putIfAbsent(id, () => []).add(r);
    }

    final metrics = grouped.values
        .map((rows) => StaffAttendanceMetrics.fromRows(rows, period: period))
        .toList()
      ..sort(Leaderboards.compareByScore);

    return StaffAnalyticsReport(period: period, all: metrics);
  }

  /// Employees that actually have attendance in the period.
  List<StaffAttendanceMetrics> get scored =>
      all.where((m) => m.hasData).toList();

  StaffAttendanceMetrics? byId(String id) {
    for (final m in all) {
      if (m.employeeId == id) return m;
    }
    return null;
  }

  /// Distinct branches in the period, for the leaderboard grouping.
  List<String> get branches => _distinct((m) {
    final name = m.branchName.trim();
    return name.isEmpty ? m.branchId.trim() : name;
  });

  List<String> get departments =>
      _distinct((m) => m.department.trim());

  List<String> get positions => _distinct((m) => m.position.trim());

  List<String> _distinct(String Function(StaffAttendanceMetrics) key) {
    final seen = <String>{};
    for (final m in all) {
      final k = key(m);
      if (k.isNotEmpty) seen.add(k);
    }
    return seen.toList()..sort();
  }
}

/// How a leaderboard slices the workforce.
enum LeaderboardDimension {
  overall('Overall'),
  branch('By branch'),
  role('By role / position'),
  department('By department');

  final String label;

  const LeaderboardDimension(this.label);
}

/// A single row of a top-performers board.
class LeaderboardEntry {
  final StaffAttendanceMetrics metrics;
  final int rank;
  final String group;

  const LeaderboardEntry({
    required this.metrics,
    required this.rank,
    this.group = '',
  });
}

/// Builds the top-N leaderboards HR asked for.
class Leaderboards {
  const Leaderboards._();

  /// The group key for [m] under [dimension].
  ///
  /// Branch falls back to the id only when the display name is missing, so the
  /// same person cannot appear under two different keys in one board.
  static String keyOf(
    StaffAttendanceMetrics m,
    LeaderboardDimension dimension,
  ) => switch (dimension) {
    LeaderboardDimension.overall => '',
    LeaderboardDimension.branch => m.branchName.trim().isNotEmpty
        ? m.branchName.trim()
        : m.branchId.trim(),
    LeaderboardDimension.role => m.position.trim(),
    LeaderboardDimension.department => m.department.trim(),
  };

  /// Highest composite score first, then name for a stable order.
  static int compareByScore(
    StaffAttendanceMetrics a,
    StaffAttendanceMetrics b,
  ) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return a.employeeName.toLowerCase().compareTo(
      b.employeeName.toLowerCase(),
    );
  }

  /// The single best employee overall, or null when nobody has data.
  ///
  /// This is the "best 1 employee" HR asked to see pinned at the top.
  static StaffAttendanceMetrics? overallBest(
    List<StaffAttendanceMetrics> all,
  ) {
    final scored = all.where((m) => m.hasData).toList();
    if (scored.isEmpty) return null;
    return scored.reduce((a, b) => compareByScore(a, b) <= 0 ? a : b);
  }

  /// Top [limit] employees, highest score first.
  ///
  /// Employees without any attendance in the period are excluded rather than
  /// shown as 0% - they are "no data", which is a different statement.
  static List<LeaderboardEntry> top(
    List<StaffAttendanceMetrics> all, {
    int limit = 5,
  }) {
    final scored = all.where((m) => m.hasData).toList()..sort(compareByScore);
    final out = <LeaderboardEntry>[];
    for (var i = 0; i < scored.length && i < limit; i++) {
      out.add(
        LeaderboardEntry(
          metrics: scored[i],
          // Competition ranking: equal scores share a rank.
          rank: out.isNotEmpty && scored[i].score >= scored[i - 1].score
              ? out.last.rank
              : i + 1,
        ),
      );
    }
    return out;
  }

  /// Top performers within one slice - a branch, role, or department.
  ///
  /// Returns an empty list for an unknown group rather than silently falling
  /// back to the whole workforce, which would be a plausible-looking lie.
  static List<LeaderboardEntry> topIn(
    List<StaffAttendanceMetrics> all,
    LeaderboardDimension dimension,
    String group, {
    int limit = 5,
  }) {
    final needle = group.trim().toLowerCase();
    final filtered = all
        .where((m) => keyOf(m, dimension).toLowerCase() == needle)
        .toList();
    return [
      for (final e in top(filtered, limit: limit))
        LeaderboardEntry(metrics: e.metrics, rank: e.rank, group: group),
    ];
  }

  /// Every group in [dimension] with its own top performers.
  ///
  /// Groups whose members all lack attendance are omitted, so the section never
  /// shows an empty "Top 5".
  static Map<String, List<LeaderboardEntry>> byGroup(
    List<StaffAttendanceMetrics> all,
    LeaderboardDimension dimension, {
    int limit = 5,
  }) {
    final groups = <String, List<StaffAttendanceMetrics>>{};
    for (final m in all.where((m) => m.hasData)) {
      final key = keyOf(m, dimension);
      if (key.isEmpty) continue;
      groups.putIfAbsent(key, () => []).add(m);
    }
    return {
      for (final entry in groups.entries)
        entry.key: [
          for (final e in top(entry.value, limit: limit))
            LeaderboardEntry(
              metrics: e.metrics,
              rank: e.rank,
              group: entry.key,
            ),
        ],
    };
  }
}

/// Side-by-side comparison of up to three employees.
///
/// Fixed at three because that is what HR asked for, and an unbounded "add
/// another" list becomes unreadable on a phone.
class StaffComparison {
  final List<StaffAttendanceMetrics> employees;
  final List<AttendanceMetricKind> metrics;

  const StaffComparison({required this.employees, this.metrics = const []});

  static const maxEmployees = 3;

  /// Metrics to render, honouring a caller-supplied subset.
  List<AttendanceMetricKind> get visibleMetrics =>
      metrics.isEmpty ? AttendanceMetricKind.values : metrics;

  bool get isEmpty => employees.isEmpty;

  bool get isFull => employees.length >= maxEmployees;

  /// The employee leading on [kind], or null when nobody has data.
  StaffAttendanceMetrics? leaderFor(AttendanceMetricKind kind) {
    final withData = employees.where((m) => m.hasData).toList();
    if (withData.isEmpty) return null;
    return withData.reduce(
      (a, b) => a.scoreFor(kind) >= b.scoreFor(kind) ? a : b,
    );
  }

  /// True when every compared employee ties on [kind], so the UI can say
  /// "level" instead of crowning an arbitrary winner.
  bool isTiedOn(AttendanceMetricKind kind) {
    final values = employees
        .where((m) => m.hasData)
        .map((m) => m.scoreFor(kind))
        .toList();
    if (values.length < 2) return false;
    final max = values.reduce((a, b) => a > b ? a : b);
    return values.every((v) => (v - max).abs() < 0.05);
  }

  /// Difference in points between the best and worst on [kind].
  ///
  /// 0 when fewer than two employees have data, so a single-employee comparison
  /// cannot show a meaningless "100 point gap".
  double spreadFor(AttendanceMetricKind kind) {
    final values = employees
        .where((m) => m.hasData)
        .map((m) => m.scoreFor(kind))
        .toList();
    if (values.length < 2) return 0;
    final max = values.reduce((a, b) => a > b ? a : b);
    final min = values.reduce((a, b) => a < b ? a : b);
    return max - min;
  }

  /// Adds [m] unless the comparison is full or already contains them.
  StaffComparison add(StaffAttendanceMetrics m) {
    if (isFull) return this;
    if (employees.any((e) => e.employeeId == m.employeeId)) return this;
    return StaffComparison(employees: [...employees, m], metrics: metrics);
  }

  StaffComparison removeAt(int index) {
    if (index < 0 || index >= employees.length) return this;
    final next = [...employees]..removeAt(index);
    return StaffComparison(employees: next, metrics: metrics);
  }
}