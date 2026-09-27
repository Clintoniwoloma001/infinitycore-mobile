import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../diagnostics/auth_trace.dart';
import '../services/auth_service.dart';
import 'auth_gate.dart';
import '../../features/auth/activation_screen.dart';
import '../../features/auth/blocked_screen.dart';
import '../../features/auth/lock_screen.dart';
import '../../features/auth/login_screen.dart';
import '../../features/admin/bound_devices_screen.dart';
import '../../features/auth/splash_screen.dart';
import '../../features/attendance/attendance_management_screen.dart';
import '../../features/attendance/public_terminal_screen.dart';
import '../../features/dashboard/home_shell.dart';
import '../../features/messages/announcements_screen.dart';
import '../../features/messages/chat_screen.dart';
import '../../features/messages/comm_admin_screen.dart';
import '../../features/messages/conversation_screen.dart';
import '../../features/messages/messages_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/sara/sara_screen.dart';

/// Global messenger so background services (notifications, sync) can surface
/// SnackBars without a BuildContext.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

final GoRouter appRouter = GoRouter(
  initialLocation: '/splash',
  refreshListenable: AuthService.instance,
  redirect: (context, state) {
    final auth = AuthService.instance;
    return _redirectDecision(auth, state.matchedLocation, state.uri);
  },
  routes: [
    GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
    GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
    GoRoute(
      path: '/activate-account',
      builder: (_, _) => const ActivationScreen(),
    ),
    GoRoute(path: '/blocked', builder: (_, _) => const BlockedScreen()),
    GoRoute(path: '/lock', builder: (_, _) => const LockScreen()),
    GoRoute(
      path: '/attendance-terminal',
      builder: (_, state) => PublicAttendanceTerminalScreen(
        initialToken: state.uri.queryParameters['token'],
      ),
    ),
    GoRoute(path: '/home', builder: (_, _) => const HomeShell()),
    GoRoute(
      path: '/attendance-management',
      builder: (_, _) => const AttendanceManagementScreen(),
    ),
    GoRoute(
      path: '/profile',
      builder: (context, _) => Scaffold(
        appBar: shellAppBar(context, title: 'Profile'),
        body: const ProfileScreen(),
      ),
    ),
    GoRoute(
      path: '/bound-devices',
      builder: (_, _) => const BoundDevicesScreen(),
    ),
    // Header destinations. Both screens already existed but were unreachable
    // because no route was registered for them — the bell and the SARA bubble
    // now land here instead of on a dead end.
    GoRoute(
      path: '/notifications',
      builder: (context, _) => Scaffold(
        appBar: shellAppBar(context, title: 'Notifications'),
        body: const NotificationsScreen(),
      ),
    ),
    GoRoute(
      path: '/sara',
      builder: (context, _) => Scaffold(
        appBar: shellAppBar(context, title: 'SARA'),
        body: const SaraScreen(),
      ),
    ),

    // ----------------------------------------------------------------
    // Messaging. These routes were previously pushed by MessagesScreen but
    // never registered, so the whole module was unreachable. Ordering matters:
    // the static children below are declared before the `:threadId` parameter
    // route so `channel`, `group` and `announcements` are not swallowed by it.
    // ----------------------------------------------------------------
    GoRoute(path: '/messages', builder: (_, _) => const MessagesScreen()),
    GoRoute(
      path: '/messages/announcements',
      builder: (_, _) => const AnnouncementsScreen(),
    ),
    GoRoute(
      path: '/messages/channel/:id',
      builder: (_, state) => ConversationScreen(
        kind: ConversationKind.channel,
        id: state.pathParameters['id'] ?? '',
      ),
    ),
    GoRoute(
      path: '/messages/group/:id',
      builder: (_, state) => ConversationScreen(
        kind: ConversationKind.group,
        id: state.pathParameters['id'] ?? '',
      ),
    ),
    GoRoute(
      path: '/messages/:threadId',
      builder: (_, state) =>
          ChatScreen(threadId: state.pathParameters['threadId'] ?? ''),
    ),

    // Comm Admin. The navigation gate lives in `auth_gate.dart`; the data
    // itself is protected server-side by `is_communication_admin()` and the
    // RLS/RPC policies, so this is convenience rather than the security
    // boundary.
    GoRoute(path: '/comm-admin', builder: (_, _) => const CommAdminScreen()),
  ],
);

String? _redirectDecision(AuthService auth, String loc, Uri uri) {
  // Delegates to the pure, unit-tested guard in `auth_gate.dart`. Every
  // decision is logged with the exact state it came from, so any future
  // bounce-back can be attributed to a specific gate read rather than inferred
  // from screen flips.
  final decision = redirectDecision(auth, loc, uri);
  AuthTrace.log(
    'router.redirect',
    'loc=$loc -> ${decision ?? 'null (hold)'} | status=${auth.status.name} '
        'isAuthenticated=${auth.isAuthenticated} '
        'isResolved=${auth.isResolved} blocked=${auth.blockedByStatus} '
        'manageRole=${auth.canManageAttendanceRole} '
        'biometric=${auth.biometricEnabled}',
  );
  return decision;
}

/// Helpers reused by the auth layer.
void showSnack(String message, {bool isError = false}) {
  final messenger = rootScaffoldMessengerKey.currentState;
  messenger?.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: isError ? const Color(0xFFB42318) : null,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
