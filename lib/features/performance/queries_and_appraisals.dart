// ============================================================================
// Performance — QUERIES and APPRAISALS
//
// Both read RLS-protected tables directly. The one thing worth saying out loud:
// `employee_queries` has no owner-name column, so a query raised by an employee
// whose record has since been removed must still render. These models therefore
// never assume a name is present — they show the raw employee id, which is ugly
// but honest, rather than blank or "Unknown".
// ============================================================================

/// Lifecycle of an employee query (question raised against HR).
enum QueryStatus {
  open,
  inProgress,
  resolved,
  closed;

  static QueryStatus parse(Object? v) {
    switch (v?.toString().toLowerCase().replaceAll(RegExp(r'[\s_-]'), '')) {
      case 'inprogress':
        return QueryStatus.inProgress;
      case 'resolved':
        return QueryStatus.resolved;
      case 'closed':
        return QueryStatus.closed;
      case 'open':
        return QueryStatus.open;
      default:
        return QueryStatus.open;
    }
  }

  bool get isOpen => this == QueryStatus.open;
  bool get isResolved =>
      this == QueryStatus.resolved || this == QueryStatus.closed;
}

/// One query raised by an employee.
class EmployeeQuery {
  const EmployeeQuery({
    required this.id,
    required this.employeeId,
    required this.subject,
    required this.category,
    required this.description,
    required this.status,
    required this.priority,
    required this.resolution,
    required this.createdAt,
    required this.resolvedAt,
  });

  factory EmployeeQuery.fromRow(Map<String, dynamic> r) => EmployeeQuery(
    id: r['id']?.toString() ?? '',
    employeeId: r['employee_id']?.toString() ?? '',
    subject: r['subject']?.toString() ?? '',
    category: r['category']?.toString() ?? 'general',
    description: r['description']?.toString() ?? '',
    status: QueryStatus.parse(r['status']),
    priority: r['priority']?.toString() ?? 'normal',
    resolution: r['resolution']?.toString() ?? '',
    createdAt: DateTime.tryParse(r['created_at']?.toString() ?? ''),
    resolvedAt: DateTime.tryParse(r['resolved_at']?.toString() ?? ''),
  );

  final String id;
  final String employeeId;
  final String subject;
  final String category;
  final String description;
  final QueryStatus status;
  final String priority;
  final String resolution;
  final DateTime? createdAt;
  final DateTime? resolvedAt;

  bool get isUrgent =>
      priority.toLowerCase() == 'urgent' || priority.toLowerCase() == 'high';

  /// Days a query has been open. Null once resolved, because an elapsed-time
  /// figure on a closed query reads as age rather than as delay.
  int? daysOpen({DateTime? asOf}) {
    if (status.isResolved) return null;
    final created = createdAt;
    if (created == null) return null;
    final now = asOf ?? DateTime.now();
    return now.difference(created).inDays;
  }

  /// The text shown when an employee id cannot be resolved to a name. Short and
  /// deliberately ugly: this is an orphan record, and dressing it up as
  /// "Unknown employee" would imply there is a person behind it we lost.
  String displayEmployee(String? resolvedName) {
    final n = resolvedName?.trim();
    if (n != null && n.isNotEmpty) return n;
    if (employeeId.length <= 8) return employeeId;
    return '${employeeId.substring(0, 8)}…';
  }
}

/// One completed appraisal.
class Appraisal {
  const Appraisal({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.appraisalType,
    required this.workPeriod,
    required this.quarter,
    required this.appraisalYear,
    required this.reviewer,
    required this.overallRating,
    required this.strengths,
    required this.areasForImprovement,
    required this.status,
    required this.appraisalDate,
  });

  factory Appraisal.fromRow(Map<String, dynamic> r) => Appraisal(
    id: r['id']?.toString() ?? '',
    employeeId: r['employee_id']?.toString() ?? '',
    employeeName: r['employee_name']?.toString() ?? '',
    appraisalType: r['appraisal_type']?.toString() ?? 'quarterly',
    workPeriod: r['work_period']?.toString() ?? '',
    quarter: r['quarter']?.toString() ?? '',
    appraisalYear: (r['appraisal_year'] as num?)?.toInt(),
    reviewer: r['reviewer']?.toString() ?? '',
    overallRating: r['overall_rating']?.toString() ?? '',
    strengths: r['strengths']?.toString() ?? '',
    areasForImprovement: r['areas_for_improvement']?.toString() ?? '',
    status: r['status']?.toString() ?? 'draft',
    appraisalDate: DateTime.tryParse(r['appraisal_date']?.toString() ?? ''),
  );

  final String id;
  final String? employeeId;
  final String employeeName;
  final String appraisalType;
  final String workPeriod;
  final String quarter;
  final int? appraisalYear;
  final String reviewer;
  final String overallRating;
  final String strengths;
  final String areasForImprovement;
  final String status;
  final DateTime? appraisalDate;

  bool get isDraft => status.toLowerCase() == 'draft';

  /// "Q2 2025", falling back to whatever work_period holds. Never blank: an
  /// appraisal with no legible period is still a real appraisal.
  String get periodLabel {
    if (quarter.isNotEmpty && appraisalYear != null) {
      return '$quarter ${appraisalYear!}';
    }
    if (workPeriod.isNotEmpty) return workPeriod;
    if (appraisalYear != null) return '${appraisalYear!}';
    return 'Unspecified period';
  }
}
