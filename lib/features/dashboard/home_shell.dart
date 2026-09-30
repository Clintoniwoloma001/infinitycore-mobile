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
import '../messages/urgent_ack_service.dart';
import '../sara/sara_mark.dart';
import 'app_menu.dart';
import 'host_fab.dart';

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

  /// Slot the active tab publishes its own compose button into.
  final ValueNotifier<Widget?> _hostFab = ValueNotifier<Widget?>(null);

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
    // Drop the tab's button and stop pointing at a disposed notifier, so a late
    // publish from a torn-down tab cannot write to freed state.
    _hostFab.value = null;
    if (HostFabScope.current == _hostFab) HostFabScope.detach();
    _hostFab.dispose();
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
      (t) =>
          t.label.toLowerCase() == wanted ||
          t.label.toLowerCase().startsWith(wanted),
    );
    if (i >= 0 && i != _index) {
      // The outgoing tab may own the compose button. Clear it so the incoming
      // tab starts from a clean slot instead of inheriting a stale one.
      _hostFab.value = null;
      setState(() => _index = i);
    }
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
      // The scope lets the visible tab publish its own compose button into the
      // FAB slot below, so the tab's action and the SARA mark stack instead of
      // fighting for the same corner.
      body: HostFabScope(
        notifier: _hostFab,
        child: IndexedStack(
          index: index,
          children: [for (final t in tabs) t.screen],
        ),
      ),
      // SARA stays one tap away from every tab as a chat bubble.
      //
      // A screen-hosted FAB is rendered BELOW the SARA mark rather than
      // underneath it. Messages, and any future tab with its own compose
      // action, publishes one through [HostFabScope]; both are painted in this
      // single Scaffold slot so the two can never overlap. Positioning the
      // compose button inside its own screen's Stack could not achieve that:
      // the shell's FAB floats above the whole body, so it always sat on top of
      // (and swallowed the tap of) the screen's own button.
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ValueListenableBuilder<Widget?>(
            valueListenable: HostFabScope.current,
            builder: (context, hostFab, _) =>
                hostFab ?? const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'sara_fab',
            onPressed: () => context.push('/sara'),
            backgroundColor: AppColors.brandTint(context, AppColors.orange),
            foregroundColor: AppColors.accent(context),
            tooltip: 'Ask SARA',
            elevation: 2,
            child: const SaraMark(size: 26),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        backgroundColor: AppColors.surface(context),
        indicatorColor: AppColors.accent(context).withValues(alpha: 0.14),
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final t in tabs)
            NavigationDestination(
              // A pending mandatory acknowledgment is a compliance obligation,
              // not a nicety, so it gets a persistent dot on the tab rather than
              // only living inside the Messages screen the user may not open.
              icon: _badgeFor(t.label, Icon(t.icon), t.label == 'Messages'),
              selectedIcon: _badgeFor(
                t.label,
                Icon(t.selectedIcon, color: AppColors.accent(context)),
                t.label == 'Messages',
              ),
              label: t.label,
            ),
        ],
      ),
    );
  }

  /// Wraps a navigation icon with the outstanding-acknowledgment dot when the
  /// destination is Messages and the user owes a confirmation.
  static Widget _badgeFor(String label, Widget icon, bool isMessages) {
    if (!isMessages) return icon;
    return ValueListenableBuilder<List<PendingAck>>(
      valueListenable: UrgentAckService.instance.pending,
      builder: (context, items, child) => items.isEmpty
          ? child!
          : Badge.count(
              count: items.length,
              backgroundColor: AppColors.rose,
              child: child,
            ),
      child: icon,
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
