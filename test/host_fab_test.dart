import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/features/dashboard/host_fab.dart';

/// Regression tests for the SARA / compose-button collision.
///
/// The shell's SARA mark lives in the Scaffold's single `floatingActionButton`
/// slot, which paints above the entire body. The Messages tab therefore cannot
/// float its own button inside its layout: SARA covered it and swallowed its
/// taps. The tab now publishes into [HostFabScope] and the shell stacks both.
void main() {
  Widget composeButton() => FloatingActionButton.small(
    heroTag: 'new_chat',
    onPressed: () {},
    child: const Icon(Icons.edit),
  );

  /// Wraps [child] in the minimum app scaffolding a `Scaffold` needs.
  Widget app(ValueNotifier<Widget?> hostFab, Widget child) => MaterialApp(
    home: HostFabScope(notifier: hostFab, child: child),
  );

  testWidgets('a published button is readable through the scope', (tester) async {
    final hostFab = ValueNotifier<Widget?>(null);
    addTearDown(hostFab.dispose);

    await tester.pumpWidget(
      app(hostFab, const Scaffold(body: Center(child: Text('body')))),
    );
    expect(HostFabScope.current, same(hostFab));

    // Standalone publish, the way the shell listens for it.
    hostFab.value = composeButton();
    await tester.pump();
    expect(hostFab.value, isNotNull);
  });

  testWidgets('a publisher registers its button and clears it on dispose', (
    tester,
  ) async {
    final hostFab = ValueNotifier<Widget?>(null);
    addTearDown(hostFab.dispose);

    await tester.pumpWidget(
      app(hostFab, const Scaffold(body: SizedBox.shrink())),
    );
    // Register the publisher, as the Messages tab does.
    await tester.pumpWidget(
      app(hostFab, HostFabPublisher(builder: (_) => composeButton())),
    );
    await tester.pump();
    await tester.pump();
    expect(hostFab.value, isNotNull);

    // The tab is torn down; nothing may be left floating over the next one.
    await tester.pumpWidget(
      app(hostFab, const Scaffold(body: SizedBox.shrink())),
    );
    await tester.pump();
    expect(hostFab.value, isNull);
  });

  testWidgets('a null builder publishes nothing', (tester) async {
    // A standalone Messages route owns its own Scaffold, so it must not
    // contribute a second button to the shell.
    final hostFab = ValueNotifier<Widget?>(null);
    addTearDown(hostFab.dispose);

    await tester.pumpWidget(app(hostFab, HostFabPublisher(builder: (_) => null)));
    await tester.pump();
    await tester.pump();
    expect(hostFab.value, isNull);
  });

  testWidgets('the composed FAB column never overlaps its children', (
    tester,
  ) async {
    // The shell stacks the tab button above SARA in one Column. Two siblings in
    // a Column cannot share pixels, which is what makes the collision
    // structurally impossible rather than merely offset away.
    final hostFab = ValueNotifier<Widget?>(null);
    addTearDown(hostFab.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HostFabScope(
          notifier: hostFab,
          child: Scaffold(
            floatingActionButton: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ValueListenableBuilder<Widget?>(
                  valueListenable: hostFab,
                  builder: (_, fab, _) => fab ?? const SizedBox.shrink(),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'sara_fab',
                  onPressed: () {},
                  child: const Icon(Icons.chat_bubble_outline),
                ),
              ],
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    hostFab.value = composeButton();
    await tester.pump();
    await tester.pump();

    final compose = tester.getRect(find.byType(FloatingActionButton).first);
    final sara = tester.getRect(find.byType(FloatingActionButton).last);
    // No vertical overlap: the gap keeps the top of SARA below the compose
    // button, so both remain individually tappable.
    expect(sara.top, greaterThanOrEqualTo(compose.bottom));
  });
}
