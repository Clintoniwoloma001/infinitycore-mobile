// Tests for the Query/Appraisal models. These exist mostly to pin down what
// happens to records that are incomplete in production — which is most of them.

import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/performance/queries_and_appraisals.dart';

void main() {
  group('QueryStatus', () {
    test('parses the shapes the database actually stores', () {
      // Postgres may store 'in_progress' or 'In Progress'; both must land on
      // inProgress rather than silently falling back to open.
      expect(QueryStatus.parse('in_progress'), QueryStatus.inProgress);
      expect(QueryStatus.parse('In Progress'), QueryStatus.inProgress);
      expect(QueryStatus.parse('inprogress'), QueryStatus.inProgress);
      expect(QueryStatus.parse('open'), QueryStatus.open);
      expect(QueryStatus.parse('resolved'), QueryStatus.resolved);
      expect(QueryStatus.parse('closed'), QueryStatus.closed);
    });

    test('an unknown status defaults to open rather than vanishing', () {
      // Assuming 'closed' would hide a query nobody answered.
      expect(QueryStatus.parse('escalated'), QueryStatus.open);
      expect(QueryStatus.parse(null), QueryStatus.open);
    });

    test('resolved and closed both count as resolved', () {
      expect(QueryStatus.resolved.isResolved, isTrue);
      expect(QueryStatus.closed.isResolved, isTrue);
      expect(QueryStatus.open.isResolved, isFalse);
      expect(QueryStatus.inProgress.isResolved, isFalse);
    });
  });

  group('EmployeeQuery', () {
    EmployeeQuery q({
      String status = 'open',
      String createdAt = '2025-01-01T00:00:00Z',
      String priority = 'normal',
    }) => EmployeeQuery.fromRow({
      'id': 'q1',
      'employee_id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      'subject': 'Leave balance',
      'category': 'leave',
      'description': 'How many days remain?',
      'status': status,
      'priority': priority,
      'created_at': createdAt,
    });

    test('an open query reports how long it has waited', () {
      final query = q(createdAt: DateTime(2025, 1, 1, 12).toIso8601String());
      // Midday start so the local/UTC offset cannot round 10 days down to 9.
      expect(query.daysOpen(asOf: DateTime(2025, 1, 11, 12)), 10);
    });

    test('a resolved query reports no waiting time', () {
      // Elapsed time on a closed query reads as age, not as delay.
      final query = q(status: 'resolved');
      expect(query.daysOpen(asOf: DateTime(2026, 1, 1)), isNull);
    });

    test('high and urgent priorities are both flagged', () {
      expect(q(priority: 'urgent').isUrgent, isTrue);
      expect(q(priority: 'High').isUrgent, isTrue);
      expect(q(priority: 'normal').isUrgent, isFalse);
    });

    test('an unresolvable employee still shows something identifying', () {
      final query = q();
      expect(query.displayEmployee('Adebayo Okafor'), 'Adebayo Okafor');
      // Not a name we do not have. A short id beats a blank row, and beats
      // "Unknown" which would wrongly imply a person we merely lost.
      expect(query.displayEmployee(null), startsWith('aaaaaaaa'));
      expect(query.displayEmployee('  '), startsWith('aaaaaaaa'));
    });

    test('a resolved query keeps its resolution text', () {
      final query = EmployeeQuery.fromRow({
        'id': 'q2',
        'employee_id': 'e',
        'subject': 'S',
        'status': 'resolved',
        'resolution': '12 days remaining',
        'resolved_at': '2025-02-01T00:00:00Z',
      });
      expect(query.resolution, '12 days remaining');
      expect(query.resolvedAt, isNotNull);
    });
  });

  group('Appraisal', () {
    Appraisal a({String? quarter, int? year, String? workPeriod}) =>
        Appraisal.fromRow({
          'id': 'a1',
          'employee_id': 'e1',
          'employee_name': 'Chioma Nwosu',
          'quarter': quarter,
          'appraisal_year': year,
          'work_period': workPeriod,
          'status': 'final',
        });

    test('quarter and year together make the period label', () {
      expect(a(quarter: 'Q2', year: 2025).periodLabel, 'Q2 2025');
    });

    test('falls back to the work period when there is no quarter', () {
      expect(a(workPeriod: 'H1 2025').periodLabel, 'H1 2025');
    });

    test('never renders a blank period', () {
      // An appraisal with no legible period is still a real appraisal.
      expect(a().periodLabel, 'Unspecified period');
      expect(a(year: 2025).periodLabel, '2025');
    });

    test('a draft is distinguishable from a final appraisal', () {
      expect(Appraisal.fromRow({'id': 'x', 'status': 'draft'}).isDraft, isTrue);
      expect(
        Appraisal.fromRow({'id': 'x', 'status': 'final'}).isDraft,
        isFalse,
      );
    });

    test('a row of nulls parses without throwing', () {
      // Sparse rows are normal once a staff member leaves.
      final appraisal = Appraisal.fromRow({'id': 'a', 'appraisal_year': null});
      expect(appraisal.employeeName, '');
      expect(appraisal.appraisalYear, isNull);
      expect(appraisal.quarter, '');
    });
  });
}
