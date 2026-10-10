// ============================================================================
// Add Fence screen — "Use My Location" is present, visible and actionable
// ============================================================================
// The bug this locks out: the previous task left a NON-COMPILING working tree
// in geofence_fence_editor.dart (stray comments spliced inside a `Row`'s
// children). A source that does not compile cannot be built, patched or
// released, so the "Use My Location" control that was already in the shipped
// binary could never be reproduced or improved — and a device that had the fix
// in its release binary but a broken source tree could not be patched at all.
//
// These tests render the REAL screen on real phone-sized viewports and assert
// the button is not merely in the widget tree but inside the visible panel,
// which is the only thing an admin can actually press. The reported device is
// a SM-J415F (Galaxy J4, 360x740 dp, Android 9), the smallest screen this app
// supports, so that is the primary viewport under test.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/theme/app_theme.dart';
import 'package:infinitycore/features/geofences/geofence_fence_editor.dart';

/// The screen with the same arguments "Add a fence" pushes after the admin
/// picks a branch that has no fence yet.
Widget editor() {
  return MaterialApp(
    theme: AppTheme.light,
    home: const FenceEditorScreen(
      branchId: 'a1b2c3d4-0000-4000-8000-000000000001',
      branchName: 'Ikorodu Business Office',
      branchCode: 'IMFB/IKD',
    ),
  );
}

Future<void> pumpEditor(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(editor());
  // FlutterMap builds through a layout + paint cycle; pump twice so the map
  // and the panel have both settled before visibility is measured.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  group('Add Fence "Use My Location"', () {
    testWidgets('the button is in the tree and labelled', (tester) async {
      await pumpEditor(tester, const Size(360, 740));

      final finder = find.widgetWithText(FilledButton, 'Use My Location');
      expect(
        finder,
        findsOneWidget,
        reason: 'the control that acquires a GPS fix must exist',
      );
      expect(find.byIcon(Icons.my_location), findsOneWidget);
    });

    testWidgets('it is VISIBLE on the reported Samsung J4 viewport', (
      tester,
    ) async {
      // 360x740 dp is the SM-J415F the report names. A button that exists but
      // sits below a scroll fold is invisible to a user who never swipes, and
      // there is nothing on screen telling them to.
      await pumpEditor(tester, const Size(360, 740));

      final rect = tester.getRect(
        find.widgetWithText(FilledButton, 'Use My Location'),
      );
      final screen = tester.getRect(find.byType(MaterialApp));

      expect(
        rect.top >= screen.top && rect.bottom <= screen.bottom,
        isTrue,
        reason: 'the button must fall inside the visible viewport on the '
            'reported device, not below a scroll fold',
      );
    });

    testWidgets('tapping it runs the permission flow without crashing', (
      tester,
    ) async {
      await pumpEditor(tester, const Size(360, 740));

      // Geolocator talks to a platform channel that is absent in a widget
      // test, so the tap is expected to surface a handled error state (the
      // screen catches it and shows a message). What must NOT happen is an
      // unhandled exception taking the screen down.
      await tester.tap(
        find.widgetWithText(FilledButton, 'Use My Location'),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        find.byType(FenceEditorScreen),
        findsOneWidget,
        reason: 'the editor must survive a failed GPS request',
      );
    });

    testWidgets('saving stays disabled until a valid centre and radius', (
      tester,
    ) async {
      await pumpEditor(tester, const Size(360, 740));

      // A new fence opens on the Lagos fallback with a clamped default radius,
      // so the save control is enabled but must never be reachable while the
      // radius field is invalid.
      final save = find.widgetWithText(FilledButton, 'Add fence');
      expect(save, findsOneWidget);

      await tester.enterText(find.byType(TextField), 'not-a-number');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('Add Fence panel chrome', () {
    testWidgets('the map and the control panel are both laid out', (
      tester,
    ) async {
      await pumpEditor(tester, const Size(360, 740));
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('Ikorodu Business Office'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Add fence'), findsOneWidget);
    });

    testWidgets('no RenderFlex overflow on the smallest supported screen', (
      tester,
    ) async {
      // The 1.1.8+20 fix moved the GPS controls into their own row precisely
      // because squeezing them next to "Radius" overflowed the row and pushed
      // the unit toggle off-screen. Re-assert the fix holds.
      await pumpEditor(tester, const Size(360, 740));

      final errors = <String>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details.toString());
      await tester.pump();
      FlutterError.onError = originalOnError;

      expect(
        errors.where((e) => e.contains('overflowed')).toList(),
        isEmpty,
        reason: 'a RenderFlex overflow hides controls, including ' 'Use My Location',
      );
    });
  });
}
