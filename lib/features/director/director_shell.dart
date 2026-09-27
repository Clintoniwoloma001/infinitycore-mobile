// Director navigation: a small, purpose-built bottom bar rather than a copy of
// the full web navigation. Four executive destinations.
import 'package:flutter/material.dart';

import 'director_home_screen.dart';
import 'leave_overview_screen.dart';
import 'role_performance_screen.dart';
import 'attendance_overview_screen.dart';
import 'employee_profile_screen.dart';

class DirectorShell extends StatefulWidget {
  const DirectorShell({super.key});

  @override
  State<DirectorShell> createState() => DirectorShellState();
}

class DirectorShellState extends State<DirectorShell> {
  int _index = 0;

  void goTo(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  void openProfile(Map<String, dynamic> person) {
    final id = person['employee_id'] ?? person['id'];
    if (id == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmployeeProfileScreen(
          employeeId: id.toString(),
          fallbackName: person['full_name']?.toString(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      DirectorHomeScreen(onOpenProfile: openProfile),
      const LeaveOverviewScreen(),
      const RolePerformanceScreen(),
      const AttendanceOverviewScreen(),
    ];

    return Scaffold(
      // IndexedStack keeps each tab's scroll position and loaded state, so
      // switching tabs does not re-query the server.
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: goTo,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.beach_access_outlined),
            selectedIcon: Icon(Icons.beach_access),
            label: 'Leave',
          ),
          NavigationDestination(
            icon: Icon(Icons.track_changes_outlined),
            selectedIcon: Icon(Icons.track_changes),
            label: 'Targets',
          ),
          NavigationDestination(
            icon: Icon(Icons.schedule_outlined),
            selectedIcon: Icon(Icons.schedule),
            label: 'Attendance',
          ),
        ],
      ),
    );
  }
}