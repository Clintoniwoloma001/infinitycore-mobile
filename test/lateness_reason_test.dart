import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/attendance/lateness_reason_modal.dart';
import 'package:infinitycore/features/attendance/lateness_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Wraps the modal in a minimal app. The modal's submit path reaches
/// Supabase, so the network-facing assertions stay in the migration's SQL
/// verification; these cover the VALIDATION rules the modal enforces itself.
Future<(BuildContext, GlobalKey<NavigatorState>)> _pumpModal(
  WidgetTester tester,
) async {
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => LatenessReasonModal.show(
                context,
                minutesLate: 12,
                clockedInAt: DateTime(2026, 10, 12, 9, 15),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (navigatorKey.currentContext!, navigatorKey);
}

void main() {
  setUpAll(() async {
    // Placeholder Supabase so the submit path reaches the real code (and then
    // fails on the network) instead of tripping the initialization assert.
    // Same pattern as smart_navigation_test.dart.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      publishableKey: 'sb_publishable_placeholder_widget_test_only',
    );
  });

  group('lateness window', () {
    test('today is a single local date', () {
      final w = latenessWindow(
        LatenessRange.today,
        now: DateTime(2026, 10, 12, 14, 30),
      );
      expect(w.from, DateTime(2026, 10, 12));
      expect(w.to, DateTime(2026, 10, 12));
    });

    test('week is Monday-start', () {
      // 2026-10-12 is a Monday; 2026-10-18 is the Sunday of that week.
      final monday = latenessWindow(
        LatenessRange.week,
        now: DateTime(2026, 10, 13),
      );
      expect(monday.from, DateTime(2026, 10, 12));
      expect(monday.to, DateTime(2026, 10, 13));
      final sunday = latenessWindow(
        LatenessRange.week,
        now: DateTime(2026, 10, 18),
      );
      expect(sunday.from, DateTime(2026, 10, 12));
      expect(sunday.to, DateTime(2026, 10, 18));
    });

    test('month starts on the 1st and ends today', () {
      final w = latenessWindow(
        LatenessRange.month,
        now: DateTime(2026, 10, 12),
      );
      expect(w.from, DateTime(2026, 10, 1));
      expect(w.to, DateTime(2026, 10, 12));
    });

    test('custom uses the picked range', () {
      final w = latenessWindow(
        LatenessRange.custom,
        customFrom: DateTime(2026, 9, 1),
        customTo: DateTime(2026, 9, 30),
        now: DateTime(2026, 10, 12),
      );
      expect(w.from, DateTime(2026, 9, 1));
      expect(w.to, DateTime(2026, 9, 30));
    });
  });

  group('lateness modal validation', () {
    testWidgets('submitting without a category shows an error', (tester) async {
      await _pumpModal(tester);
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(find.text('Please choose a reason.'), findsOneWidget);
      // Still open: the modal cannot be skipped.
      expect(find.text("You're late — why?"), findsOneWidget);
    });

    testWidgets('Others requires at least 5 characters of free text',
        (tester) async {
      await _pumpModal(tester);
      await tester.tap(find.text('Others'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Rain');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(
        find.text('Please describe the reason (at least 5 characters).'),
        findsOneWidget,
      );
      expect(find.text("You're late — why?"), findsOneWidget);

      // Five characters is enough: the submit proceeds (and, with no network,
      // queues locally) so the validation error is gone and the modal closes.
      await tester.enterText(find.byType(TextField), 'Rains');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(
        find.text('Please describe the reason (at least 5 characters).'),
        findsNothing,
      );
      expect(find.text("You're late — why?"), findsNothing);
    });

    testWidgets('a category other than Others submits without free text',
        (tester) async {
      await _pumpModal(tester);
      await tester.tap(find.text('Traffic'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      // No validation error is raised for Traffic without an explanation, and
      // the modal closes once the reason is submitted (or queued offline).
      expect(find.text('Please choose a reason.'), findsNothing);
      expect(
        find.text('Please describe the reason (at least 5 characters).'),
        findsNothing,
      );
      expect(find.text("You're late — why?"), findsNothing);
    });

    testWidgets('tapping the barrier does not dismiss the modal',
        (tester) async {
      await _pumpModal(tester);
      expect(find.text("You're late — why?"), findsOneWidget);
      // Tap outside the dialog (top-left corner of the barrier).
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text("You're late — why?"), findsOneWidget);
    });
  });
}
