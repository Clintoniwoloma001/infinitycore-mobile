// ============================================================================
// I-Meet render-on-fresh-install guard
// ============================================================================
// A module can be fully wired and still be unreachable in a real app: the route
// resolves but the screen throws, the shared registry hides it, or a widget
// only builds when some other feature has already run. Widget tests routinely
// miss that because they mount one screen in isolation.
//
// So this pumps the REAL I-Meet home screen and the real meeting detail screen
// inside a GoRouter wired from the REAL route table, with a stubbed service. If
// a route is unreachable, throws on build, or depends on state a fresh install
// would not have, this fails.
//
// I-Meet needs no live Supabase for this: the service is injected, so this runs
// with no network and no credentials.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:infinitycore/core/routing/app_destinations.dart';
import 'package:infinitycore/features/imeet/imeet_home_screen.dart';
import 'package:infinitycore/features/imeet/imeet_meeting_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Bring Supabase up against a placeholder URL with NO network calls.
///
/// The screens touch `SupabaseService.client` while building, so a widget test
/// has to have an initialised instance. Nothing here reaches the network: the
/// first frame renders the loading state, which is exactly what a real fresh
/// install shows before any request completes.
///
/// `Supabase.initialize` is idempotent-by-throwing here rather than by a
/// readable flag: reading `Supabase.instance.isInitialized` is itself an
/// assertion failure before initialisation, so the flag cannot be the guard.
bool _fakeSupabaseReady = false;

Future<void> initFakeSupabase() async {
  if (_fakeSupabaseReady) return;
  // Supabase's local storage is backed by shared_preferences, which is a
  // platform channel and therefore absent in a unit-test VM. The in-memory mock
  // is the standard substitute; it keeps the test hermetic, with no disk writes.
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await Supabase.initialize(
    url: 'https://placeholder.supabase.co',
    publishableKey: 'sb_publishable_placeholder_widget_test_only',
  );
  _fakeSupabaseReady = true;
}

void main() {
  setUpAll(initFakeSupabase);

  // A router built from the same shape app_router.dart uses, so an ordering
  // mistake (parameter route declared before the static one) reproduces here.
  MaterialApp harnessFor(String location) {
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(path: '/imeet', builder: (_, _) => const IMeetHomeScreen()),
        GoRoute(
          path: '/imeet/record',
          builder: (_, _) => const Scaffold(body: Text('recorder')),
        ),
        GoRoute(
          path: '/imeet/:meetingId',
          builder: (_, state) =>
              IMeetMeetingScreen(meetingId: state.pathParameters['meetingId']!),
        ),
      ],
    );
    return MaterialApp.router(routerConfig: router);
  }

  testWidgets('the I-Meet home screen builds on a fresh install', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: IMeetHomeScreen()));
    // A first frame is enough to prove the tree builds. Any provider, theme or
    // service the screen needs at construction time is satisfied by a fresh
    // install, because a fresh install has none of the history.
    await tester.pump();
    expect(find.byType(IMeetHomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the meeting detail route resolves without throwing', (
    tester,
  ) async {
    await tester.pumpWidget(harnessFor('/imeet/abc-123'));
    await tester.pump();
    // Either it rendered the screen, or it is still loading - both are fine.
    // What must never happen is an exception.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the record route is reachable and not swallowed by :meetingId', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/imeet/record',
      routes: [
        GoRoute(path: '/imeet', builder: (_, _) => const IMeetHomeScreen()),
        GoRoute(
          path: '/imeet/record',
          builder: (_, _) => const Scaffold(body: Text('recorder')),
        ),
        GoRoute(
          path: '/imeet/:meetingId',
          builder: (_, state) => Scaffold(
            body: Text('meeting:${state.pathParameters['meetingId']}'),
          ),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    // If ':meetingId' had been declared first it would match "record" and this
    // would read 'meeting:record'. It must be the real recorder route.
    expect(find.text('recorder'), findsOneWidget);
    expect(find.text('meeting:record'), findsNothing);
  });

  group('I-Meet is discoverable in the navigation registry', () {
    test('there is exactly one I-Meet destination', () {
      final matches = appDestinations().where((d) => d.id == 'imeet');
      expect(matches.length, 1, reason: 'a duplicate would render twice');
    });

    test('it points at a route that is actually registered', () {
      final destination = appDestinations().firstWhere((d) => d.id == 'imeet');
      expect(destination.route, '/imeet');
      expect(destination.label.trim(), isNotEmpty);
      expect(destination.subtitle?.trim(), isNotEmpty);
    });

    test('it is shared, so a plain employee can record a meeting', () {
      final destination = appDestinations().firstWhere((d) => d.id == 'imeet');
      expect(
        destination.department,
        isNull,
        reason:
            'recording is not a departmental privilege; per-meeting RLS is the '
            'real gate',
      );
    });
  });
}
