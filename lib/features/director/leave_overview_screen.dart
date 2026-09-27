// Leave intelligence: who is out, who is returning, and recent activity.
// Reads the same server snapshot as the dashboard.
import 'package:flutter/material.dart';

import 'director_service.dart';
import 'employee_profile_screen.dart';
import '../../core/theme/app_theme.dart';

class LeaveOverviewScreen extends StatefulWidget {
  const LeaveOverviewScreen({super.key});

  @override
  State<LeaveOverviewScreen> createState() => _LeaveOverviewScreenState();
}

class _LeaveOverviewScreenState extends State<LeaveOverviewScreen> {
  List<Map<String, dynamic>> _leave = const [];
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
        _leave = snap.leave;
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
      appBar: AppBar(title: const Text('Leave')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : _leave.isEmpty
                  ? Center(
                      child: Text(
                        'No leave recorded for this period.',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _leave.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final l = _leave[i];
                          final days = asInt(l['days_remaining'] ?? l['days']);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              text(l['full_name']) ?? text(l['employee_name']) ?? 'Employee',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              [
                                text(l['department']),
                                text(l['leave_type']),
                                'Resumes ${text(l['end_date']) ?? '--'}',
                              ].whereType<String>().join(' · '),
                              style: const TextStyle(fontSize: 10),
                            ),
                            trailing: days != null
                                ? Text(
                                    '$days d',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF009944),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                            onTap: () {
                              final id = text(l['employee_id']);
                              if (id == null) return;
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmployeeProfileScreen(
                                    employeeId: id,
                                    fallbackName: text(l['full_name']),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
    );
  }
}
