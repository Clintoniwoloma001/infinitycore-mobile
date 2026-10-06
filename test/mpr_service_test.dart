// Tests for the MPR models.
//
// The rule under test: an MPR score exists ONLY when all three metrics are
// measured. An unmeasured employee must be presented as unmeasured — never as
// a score of 0, and never in a Drag ranking. These tests pin that, because a
// fabricated zero would appraise a real member of staff on data nobody entered.

import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/performance/mpr_service.dart';

StaffMprSummary complete() => StaffMprSummary.fromJson({
  'employee_id': 'e1',
  'employee_name': 'Ada Okafor',
  'branch_name': 'Ikorodu',
  'period_label': '2026-Q1',
  'complete': true,
  'missing': <String>[],
  'total': 92.5,
  'subtotal': 92.5,
  'grade': 'A',
  'grade_rating': 'Exceptional',
  'par_percent': 2.4,
  'at_risk_principal': 1200000,
  'disbursement_score': 33.0,
  'par_score': 35.0,
  'caseload_score': 24.5,
  'bank_par_ratio': 4.9,
});

StaffMprSummary partial() => StaffMprSummary.fromJson({
  'employee_id': 'e2',
  'employee_name': 'Bayo Tunda',
  'branch_name': 'Ikorodu',
  'period_label': '2026-Q1',
  'complete': false,
  'missing': ['par', 'caseload'],
  'total': null,
  'subtotal': 35.0,
  'grade': null,
  'grade_rating': null,
  'par_percent': null,
});

void main() {
  group('grade resolution', () {
    test('letters map to the spec colours', () {
      expect(MprGrade.a.hex, 0xFF10B981);
      expect(MprGrade.b.hex, 0xFF059669);
      expect(MprGrade.c.hex, 0xFFF59E0B);
      expect(MprGrade.d.hex, 0xFFF97316);
      expect(MprGrade.e.hex, 0xFFEF4444);
    });

    test('parsing is case-insensitive and null-safe', () {
      expect(MprGrade.fromLetter('a'), MprGrade.a);
      expect(MprGrade.fromLetter(' C '), MprGrade.c);
      expect(MprGrade.fromLetter(null), isNull);
      expect(MprGrade.fromLetter(''), isNull);
      expect(
        MprGrade.fromLetter('Z'),
        isNull,
        reason: 'unknown is not a grade',
      );
    });
  });

  group('complete summary', () {
    test('exposes the total and grade', () {
      final s = complete();
      expect(s.complete, isTrue);
      expect(s.displayScore, 92.5);
      expect(s.grade, MprGrade.a);
      expect(s.badgeLabel, contains('A'));
      expect(s.badgeLabel, contains('Exceptional'));
    });

    test('bank PAR is org-wide context, not the employee figure', () {
      final s = complete();
      expect(s.bankParRatio, 4.9);
      expect(s.parPercent, 2.4);
      expect(s.parPercent, isNot(s.bankParRatio));
    });
  });

  group('incomplete summary', () {
    test('never exposes a score, even though a subtotal exists', () {
      final s = partial();
      expect(s.complete, isFalse);
      expect(s.subtotal, 35.0, reason: 'the subtotal is real data');
      expect(
        s.displayScore,
        isNull,
        reason: 'a partial score must never be displayed as final',
      );
    });

    test('badges it as unmeasured and excluded from ranking', () {
      final s = partial();
      expect(s.badgeLabel, 'Unmeasured — excluded from ranking');
      expect(s.grade, isNull);
    });

    test('names the missing metrics in plain language', () {
      expect(partial().missingLabel, contains('PAR'));
      expect(partial().missingLabel, contains('caseload'));
    });

    test('a single missing metric reads naturally', () {
      final s = StaffMprSummary.fromJson({
        'complete': false,
        'missing': ['par'],
      });
      expect(s.missingLabel, 'Not measured: PAR');
    });

    test('no missing list at all still explains itself', () {
      final s = StaffMprSummary.fromJson({'complete': false});
      expect(s.missingLabel, 'Awaiting measurement');
    });
  });
  group('branch attribution', () {
    BranchAttribution build(List<Map<String, dynamic>> staff) =>
        BranchAttribution.fromJson({
          'ok': true,
          'branch_id': 'b1',
          'branch_name': 'Ikorodu',
          'period_label': '2026-Q1',
          'headcount': 34,
          'measured_count': 12,
          'coverage_pct': 35.3,
          // The server returns ASCENDING order.
          'staff': staff,
        });

    Map<String, dynamic> row(String id, String name, double total) => {
      'id': id,
      'full_name': name,
      'total': total,
      'grade': 'A',
    };

    test('splits into soaring and drag from the same sorted list', () {
      final a = build([
        row('1', 'Worst', 30),
        row('2', 'Mid', 60),
        row('3', 'Best', 95),
      ]);

      expect(a.ranked.map((e) => e.employeeName).toList(), [
        'Best',
        'Mid',
        'Worst',
      ], reason: 'ranked is best-first for the Soaring view');
      expect(a.soaring5.map((e) => e.employeeName), ['Best', 'Mid', 'Worst']);
      expect(a.drag5.map((e) => e.employeeName), ['Worst', 'Mid', 'Best']);
    });

    test('never pads a short ranking to five', () {
      final a = build([row('1', 'Only', 50)]);
      expect(a.soaring5, hasLength(1));
      expect(a.drag5, hasLength(1));
    });

    test('an empty ranking stays empty rather than throwing', () {
      final a = build([]);
      expect(a.isEmpty, isTrue);
      expect(a.soaring5, isEmpty);
      expect(a.drag5, isEmpty);
    });

    test('reports coverage so the ranking is not read as the whole branch', () {
      final a = build([row('1', 'One', 90)]);
      expect(a.coverageLabel, '12 of 34 staff measured');
      expect(a.unmeasuredCount, 22);
    });
  });

  group('root-cause copy', () {
    test('high PAR leads, and names Pass & Watch when present', () {
      final r = RankedStaff.fromJson({
        'id': '1',
        'full_name': 'X',
        'total': 40,
        'par_percent': 12.5,
        'pass_watch_principal': 12500000,
      });
      expect(r.rootCause, contains('12.5% PAR'));
      expect(r.rootCause, contains('Pass & Watch'));
      expect(r.rootCause, contains('₦12,500,000'));
    });

    test('falls back to at-risk when Pass & Watch is absent', () {
      final r = RankedStaff.fromJson({
        'id': '1',
        'full_name': 'X',
        'total': 40,
        'par_percent': 9.0,
        'at_risk_principal': 3000000,
      });
      expect(r.rootCause, contains('at risk'));
    });

    test('a disbursement shortfall is reported as a percentage gap', () {
      final r = RankedStaff.fromJson({
        'id': '1',
        'full_name': 'X',
        'total': 40,
        'par_percent': 1.0,
        'disbursement_actual': 8600000,
        'disbursement_target': 10000000,
      });
      expect(r.rootCause, contains('14% short'));
    });

    test('an empty caseload is called out', () {
      final r = RankedStaff.fromJson({
        'id': '1',
        'full_name': 'X',
        'total': 40,
        'par_percent': 1.0,
        'caseload_actual': 0,
      });
      expect(r.rootCause, contains('Caseload decay'));
    });

    test('nothing stands out → no callout, so the UI omits it', () {
      final r = RankedStaff.fromJson({
        'id': '1',
        'full_name': 'X',
        'total': 40,
        'par_percent': 1.0,
        'caseload_actual': 25,
      });
      expect(r.rootCause, isNull);
    });

    test('PAR at or under 5% is not treated as high', () {
      final r = RankedStaff.fromJson({
        'id': '1',
        'full_name': 'X',
        'total': 90,
        'par_percent': 5.0,
        'caseload_actual': 20,
      });
      expect(r.rootCause, isNull);
    });
  });

  group('boost copy', () {
    test('states the share and the disbursement', () {
      final r = RankedStaff.fromJson({
        'id': '1',
        'full_name': 'X',
        'total': 90,
        'share_of_branch_mpr_pct': 22.5,
        'disbursement_actual': 15000000,
      });
      expect(r.boostNote, contains('22.5%'));
      expect(r.boostNote, contains('₦15,000,000'));
    });

    test('a zero share produces no boast', () {
      final r = RankedStaff.fromJson({
        'id': '1',
        'full_name': 'X',
        'total': 90,
        'share_of_branch_mpr_pct': 0,
      });
      expect(r.boostNote, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // REGRESSION: p_branch_id is a uuid. A branch NAME used to reach Postgres as
  // `invalid input syntax for type uuid: "Head Office"` and surface on screen
  // as "Unable to load branch attribution". Validation must happen first.
  // ---------------------------------------------------------------------------
  group('uuid validation guards the RPC contract', () {
    test('accepts a canonical uuid, in either case', () {
      expect(isUuid('0b6f2a1e-9c3d-4f21-8a77-2f5f1c9d4e10'), isTrue);
      expect(isUuid('0B6F2A1E-9C3D-4F21-8A77-2F5F1C9D4E10'), isTrue);
    });

    test('rejects a branch name — the exact failure the app used to hit', () {
      expect(isUuid('Head Office'), isFalse);
      expect(isUuid(''), isFalse);
      expect(isUuid('Unassigned'), isFalse);
    });

    test('rejects malformed uuids before Postgres can', () {
      expect(isUuid('0b6f2a1e-9c3d-4f21-8a77'), isFalse);
      expect(isUuid('not-a-uuid-but-hyphenated'), isFalse);
      expect(isUuid('12345678123412341234123412341234'), isFalse);
    });

    test('surrounding whitespace does not fail an otherwise valid uuid', () {
      expect(isUuid(' 0b6f2a1e-9c3d-4f21-8a77-2f5f1c9d4e10 '), isTrue);
    });
  });
}
