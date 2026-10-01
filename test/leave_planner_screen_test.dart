import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/leave/leave_planner_screen.dart';

/// Render tests for the Leave Schedule Planner screen.
///
/// The screen cannot be driven against the real `get_leave_planner` RPC in a
/// unit test, so these pin the two things that CAN be checked hermetically:
/// that it lays out without overflowing on a real handset, and that its
/// formatting helpers are stable. A widget test that overflows is the same class
/// of bug as the app-menu sheet regression, so it is worth pinning here too.
void main() {
  // iPhone 15 Pro logical size.
  const handset = Size(393, 852);

  Future<void> pumpPlanner(WidgetTester tester) async {
    tester.view.physicalSize = handset;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LeavePlannerScreen()),
      ),
    );
    // Let the RPC failure settle into the error/empty state.
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  testWidgets('lays out on a handset without overflowing', (tester) async {
    await pumpPlanner(tester);

    // No render overflow at 393x852 - the width the heatmap wrap and the day
    // rows have to survive.
    expect(tester.takeException(), isNull);
  });

  testWidgets('survives a landscape / narrow window too', (tester) async {
    tester.view.physicalSize = const Size(320, 568); // smallest phone we support
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LeavePlannerScreen()),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
  });

  group('month names', () {
    test('every month resolves to its own name', () {
      const expected = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      for (var m = 1; m <= 12; m++) {
        expect(monthName(DateTime(2026, m)), expected[m - 1]);
      }
    });

    test('January is Jan and not an out-of-range lookup', () {
      // Guards the off-by-one that turns January into "null" or wraps to Dec.
      expect(monthName(DateTime(2026, 1)), 'Jan');
      expect(monthName(DateTime(2026, 12)), 'Dec');
    });
  });
}