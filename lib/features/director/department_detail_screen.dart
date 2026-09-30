// Department intelligence: a department's own figures, then its staff.
// The figures come from the same server snapshot as the dashboard; the staff
// list is loaded on demand rather than shipped with the dashboard payload.
import 'package:flutter/material.dart';

import 'director_service.dart';
import 'director_widgets.dart';
import 'employee_profile_screen.dart';
import '../../core/theme/app_theme.dart';

class DepartmentDetailScreen extends StatefulWidget {
  const DepartmentDetailScreen({
    super.key,
    required this.department,
    required this.raw,
  });

  final String department;
  final Map<String, dynamic> raw;

  @override
  State<DepartmentDetailScreen> createState() => _DepartmentDetailScreenState();
}

class _DepartmentDetailScreenState extends State<DepartmentDetailScreen> {
  List<Map<String, dynamic>> _staff = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await DirectorService.instance.snapshot(
        department: widget.department,
      );
      if (!mounted) return;
      setState(() {
        _staff = snap.staff
            .where(
              (p) =>
                  (text(p['department']) ?? '').toLowerCase() ==
                  widget.department.toLowerCase(),
            )
            .toList();
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
    final r = widget.raw;
    return Scaffold(
      appBar: AppBar(title: Text(widget.department)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          MetricStrip(
            tiles: [
              MetricTile(label: 'Staff', value: fmtInt(r['staff_count'])),
              MetricTile(label: 'On leave', value: fmtInt(r['on_leave'])),
              MetricTile(label: 'Absent', value: fmtInt(r['absent'])),
              MetricTile(
                label: 'Attendance',
                value: fmtPct(r['attendance_rate']),
              ),
              MetricTile(label: 'KPI', value: fmtPct(r['kpi_completion'])),
              MetricTile(
                label: 'Targets',
                value: fmtPct(r['target_completion']),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const SectionHeader(title: 'STAFF'),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C)),
            )
          else if (_staff.isEmpty)
            Text(
              'No staff reported for this department.',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            )
          else
            ..._staff.map(
              (p) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  text(p['full_name']) ?? 'Unnamed',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  [
                    text(p['position']),
                    text(p['branch_name']),
                    // Tenure is server-computed, so it matches the web exactly.
                    tenureLabel(p),
                  ].whereType<String>().join(' · '),
                  style: const TextStyle(fontSize: 10),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      fmtPct(p['attendance_rate']) ?? '--',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      fmtPct(p['kpi_completion']) ?? '--',
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFF009944),
                      ),
                    ),
                  ],
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => EmployeeProfileScreen(
                      employeeId: text(p['employee_id']) ?? text(p['id']) ?? '',
                      fallbackName: text(p['full_name']),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
