// ============================================================================
// Branch Deep-Dive — non-UUID branch id guard (regression)
// ============================================================================
// The Deep-Dive RPC takes `p_branch_id uuid`. The Branch Performance screen's
// rows used to carry id = branch NAME (the snapshot groups them by name), so
// tapping a branch sent e.g. "Head Office" to Postgres, which answered
// `invalid input syntax for type uuid: "Head Office"` — shown to the user as
// "Unable to load branch attribution" with the raw engine error underneath.
//
// After the fix the performance screen resolves the name to a UUID first, and
// this screen independently refuses to call the RPC with a non-UUID, so no
// code path can leak that Postgres error again.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/performance/branch_deep_dive_screen.dart';

void main() {
  testWidgets(
    'a name-valued branch id explains itself and never reaches the RPC',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BranchDeepDiveScreen(
            branchId: 'Head Office',
            branchName: 'Head Office',
            periodLabel: '2026-10',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Unable to load branch attribution.'), findsOneWidget);
      expect(
        find.textContaining('not linked to a branch record'),
        findsOneWidget,
        reason:
            'the screen must explain the missing branch record in plain '
            'language rather than surface a raw uuid parse error',
      );
      expect(
        find.textContaining('invalid input syntax'),
        findsNothing,
        reason: 'the raw Postgres error must never reach the user',
      );
    },
  );

  testWidgets('a real uuid passes the guard and proceeds to load', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BranchDeepDiveScreen(
          branchId: '0b6f2a1e-9c3d-4f21-8a77-2f5f1c9d4e10',
          branchName: 'Head Office',
          periodLabel: '2026-10',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The guard must not reject a valid id: the load is attempted (and in the
    // bare test environment fails at the uninitialised Supabase client), so
    // the guard's own message must NOT be what the user sees.
    expect(
      find.textContaining('not linked to a branch record'),
      findsNothing,
      reason: 'a valid UUID must proceed to the actual load attempt',
    );
    expect(find.text('Unable to load branch attribution.'), findsOneWidget);
  });
}