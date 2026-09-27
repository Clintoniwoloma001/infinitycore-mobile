// Attendance intelligence for the executive view.
//
// These figures come from the same verified attendance records the Attendance
// Management screen reads. Nothing here re-derives attendance: the server owns
// the arithmetic, this screen only displays it and lets the director drill into
// a person.
import 'package:flutter/material.dart';

import 'director_service.dart';
import 'director_widgets.dart';
import 'employee_profile_screen.dart';
import '../../core/theme/app_theme.dart';

class AttendanceOverviewScreen extends StatefulWidget {
  const AttendanceOverviewScreen({super.key});

  @override
  State<AttendanceOverviewScreen> createState() => _AttendanceOverviewScreenState();
}

class _AttendanceOverviewScreenState extends State<AttendanceOverviewScreen> {
  Map<String, dynamic> _summary = const {};
  List<Map<String, dynamic>> _staff = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final snap = await DirectorService.instance.snapshot();
      if (!mounted) return;
      setState(() {
        _summary = snap.summary;
        _staff = snap.staff;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Attendance')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      MetricStrip(
                        tiles: [
                          MetricTile(
                            label: 'Rate',
                            value: fmtPct(_summary['attendance_rate']),
                            icon: Icons.schedule_outlined,
                          ),
                          MetricTile(
                            label: 'Present',
                            value: fmtInt(_summary['present']),
                            icon: Icons.check_circle_outline,
                          ),
                          MetricTile(
                            label: 'Absent',
                            value: fmtInt(_summary['absent']),
                            icon: Icons.person_off_outlined,
                          ),
                          MetricTile(
                            label: 'Late',
                            value: fmtInt(_summary['late']),
                            icon: Icons.schedule_outlined,
                          ),
                          MetricTile(
                            label: 'Not clocked in',
                            value: fmtInt(_summary['not_clocked_in']),
                            icon: Icons.timer_off_outlined,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const SectionHeader(title: 'BY PERSON'),
                      if (_staff.isEmpty)
                        Text(
                          'No attendance reported for this period.',
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
                        )
                      else
                        ..._staff.take(20).map(
                          (p) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(
                              text(p['full_name']) ?? 'Unnamed',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              text(p['status']) ?? text(p['branch_name']) ?? '',
                              style: const TextStyle(fontSize: 10),
                            ),
                            trailing: Text(
                              fmtPct(p['attendance_rate']) ?? '--',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onTap: () {
                              final id = text(p['employee_id']) ?? text(p['id']);
                              if (id == null) return;
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmployeeProfileScreen(
                                    employeeId: id,
                                    fallbackName: text(p['full_name']),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}
