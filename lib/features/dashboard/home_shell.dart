import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/auth_trace.dart';
import '../../core/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_management_screen.dart';
import '../attendance/attendance_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../leave/leave_requests_screen.dart';
import '../messages/messages_screen.dart';
import 'app_menu.dart';

class _TabDef {
  const _TabDef(this.label, this.icon, this.selectedIcon, this.screen);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Lets non-tab code (e.g. a notification quick action) switch the active
  /// tab inside the shell. Newest request wins; null is ignored.
  static final ValueNotifier<String?> requestTab = ValueNotifier<String?>(null);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Direct evidence of when Home actually becomes the visible screen (and,
    // together with dispose(), of any bounce back to Login).
    AuthTrace.log('home', 'HomeShell initState — Home IS on screen');
    HomeShell.requestTab.addListener(_onTabRequest);
    _onTabRequest();
  }

  @override
  void dispose() {
    AuthTrace.log('home', 'HomeShell dispose — Home removed from tree');
    HomeShell.requestTab.removeListener(_onTabRequest);
    super.dispose();
  }

  void _onTabRequest() {
    final requested = HomeShell.requestTab.value;
    if (requested == null || !mounted) return;
    _goToTab(requested);
  }

  List<_TabDef> get _tabs {
    final canManage = AuthService.instance.canManageAttendanceRole;
    return [
      _TabDef(
        'Home',
        Icons.home_outlined,
        Icons.home,
        DashboardScreen(
          onGoToTab: _goToTab,
          onGoToManagement: canManage ? () => _goToTab('manage') : null,
        ),
      ),
      const _TabDef(
        'Attendance',
        Icons.schedule_outlined,
        Icons.schedule,
        AttendanceScreen(),
      ),
      // Messaging moved onto the bottom bar (previously reachable only from a
      // dashboard card), sitting before Leave Requests and Manage.
      const _TabDef(
        'Messages',
        Icons.forum_outlined,
        Icons.forum,
        MessagesScreen(embedded: true),
      ),
      const _TabDef(
        'Leave',
        Icons.event_note_outlined,
        Icons.event_note,
        LeaveRequestsScreen(),
      ),
      if (canManage)
        const _TabDef(
          'Manage',
          Icons.groups_outlined,
          Icons.groups,
          AttendanceManagementScreen(),
        ),
    ];
  }

  void _goToTab(String tab) {
    // Friendly aliases so callers can request the tab by screen intent.
    final wanted = switch (tab.toLowerCase()) {
      'leave' || 'leave requests' || 'leaverequests' => 'leave',
      'messages' || 'chat' => 'messages',
      _ => tab.toLowerCase(),
    };
    final i = _tabs.indexWhere(
      (t) => t.label.toLowerCase() == wanted ||
          t.label.toLowerCase().startsWith(wanted),
    );
    if (i >= 0) setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    final index = _index.clamp(0, tabs.length - 1);
    return Scaffold(
      appBar: shellAppBar(
        context,
        title: tabs[index].label,
        showBackButton: false,
        actionsExtra: appHeaderActions(context),
      ),
      body: IndexedStack(
        index: index,
        children: [for (final t in tabs) t.screen],
      ),
      // SARA stays one tap away from every tab as a chat bubble.
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/sara'),
        backgroundColor: AppColors.accent(context),
        foregroundColor: Colors.white,
        tooltip: 'Ask SARA',
        child: const Icon(Icons.chat_bubble_outline),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        backgroundColor: AppColors.surface(context),
        indicatorColor: AppColors.accent(context).withValues(alpha: 0.14),
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final t in tabs)
            NavigationDestination(
              icon: Icon(t.icon),
              selectedIcon: Icon(
                t.selectedIcon,
                color: AppColors.accent(context),
              ),
              label: t.label,
            ),
        ],
      ),
    );
  }
}

/// Standard shell app bar: title, brand underline accent, optional actions.
///
/// Every non-tab screen gets a leading back control. Detail screens are often
/// opened with `context.go(...)` (which replaces the stack instead of pushing
/// onto it), so when there is nothing to pop we fall back to `/home` — the
/// button always takes the user somewhere sensible.
AppBar shellAppBar(
  BuildContext context, {
  required String title,
  Widget? bottom,
  List<Widget>? actionsExtra,
  bool showBackButton = true,
}) {
  return AppBar(
    automaticallyImplyLeading: false,
    leading: showBackButton
        ? IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            tooltip: 'Back',
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/home');
              }
            },
          )
        : null,
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
    centerTitle: false,
    bottom: bottom == null
        ? PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.accent(context),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          )
        : null,
    actions: [...?actionsExtra],
  );
}
