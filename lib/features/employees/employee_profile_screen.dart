import 'package:flutter/material.dart';

import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';

class EmployeeProfileScreen extends StatefulWidget {
  const EmployeeProfileScreen({super.key, required this.employeeId});

  final String employeeId;

  @override
  State<EmployeeProfileScreen> createState() => _EmployeeProfileScreenState();
}

class _EmployeeProfileScreenState extends State<EmployeeProfileScreen> {
  Map<String, dynamic>? _employee;
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
      final res = await SupabaseService.client
          .from('employees')
          .select()
          .eq('id', widget.employeeId)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _employee = res is Map ? Map<String, dynamic>.from(res as Map) : null;
        if (_employee == null) _error = 'Employee record not found.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _s(String key, [String fallback = '—']) {
    final v = _employee?[key];
    if (v == null) return fallback;
    final s = v.toString().trim();
    return s.isEmpty ? fallback : s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: 'Employee'),
      body: _loading
          ? const PageLoadingView(label: 'Loading employee…')
          : _error != null
          ? PageErrorView(message: _error!, onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          AvatarCircle(
                            name: _s('full_name', 'Employee'),
                            size: 72,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _s('full_name', 'Employee'),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            _s('email'),
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary(context),
                            ),
                          ),
                          const SizedBox(height: 8),
                          StatusBadge(
                            label: _s('employment_status', _s('status')),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'Employment details',
                    children: [
                      _Row(label: 'Department', value: _s('department')),
                      _Row(label: 'Designation', value: _s('position')),
                      _Row(label: 'Employee no.', value: _s('employee_number')),
                      _Row(label: 'Staff ID', value: _s('staff_id')),
                      _Row(label: 'Employee code', value: _s('employee_code')),
                      _Row(label: 'Branch', value: _s('branch')),
                      _Row(label: 'Area', value: _s('area')),
                      _Row(label: 'Job level', value: _s('job_level')),
                      _Row(
                        label: 'Confirmation',
                        value: _s('confirmation_status'),
                      ),
                      _Row(
                        label: 'Joined',
                        value: _employee?['joined_date'] == null
                            ? '—'
                            : Fmt.dateShort('${_employee!['joined_date']}'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'Personal',
                    children: [
                      _Row(label: 'Phone', value: _s('phone')),
                      _Row(label: 'Gender', value: _s('gender')),
                      _Row(label: 'Date of birth', value: _s('date_of_birth')),
                      _Row(label: 'Address', value: _s('address')),
                      _Row(label: 'Bank', value: _s('bank_name')),
                      _Row(label: 'Account no.', value: _s('account_number')),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary(context)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.slate900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
