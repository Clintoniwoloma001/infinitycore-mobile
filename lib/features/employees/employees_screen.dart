import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';

class EmployeesScreen extends StatefulWidget {
  const EmployeesScreen({super.key});

  @override
  State<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends State<EmployeesScreen> {
  List<Map<String, dynamic>> _employees = [];
  bool _loading = true;
  String? _error;
  final _query = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await SupabaseService.client
          .from('employees')
          .select(
            'id, full_name, email, department, position, branch, employment_status, employee_number, staff_id, status',
          )
          .order('full_name')
          .limit(500);
      if (!mounted) return;
      setState(
        () => _employees = (res as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return _employees;
    return _employees.where((e) {
      final hay = <String>[
        '${e['full_name'] ?? ''}',
        '${e['department'] ?? ''}',
        '${e['position'] ?? ''}',
        '${e['employee_number'] ?? ''}',
        '${e['staff_id'] ?? ''}',
        '${e['branch'] ?? ''}',
      ].join().toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: 'Employees'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _query,
              onChanged: (v) => setState(() => _filter = v),
              decoration: InputDecoration(
                hintText: 'Search by name, department or ID…',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: AppColors.surface(context),
                isDense: true,
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: AppColors.textTertiary(context),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border(context)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.green),
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const PageLoadingView(label: 'Loading employees…')
                : _error != null && _employees.isEmpty
                ? PageErrorView(message: _error!, onRetry: _load)
                : _filtered.isEmpty
                ? const PageEmptyView(
                    title: 'No employees found',
                    description: 'Adjust your search to see results.',
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      itemCount: _filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final e = _filtered[i];
                        return _EmployeeTile(employee: e);
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmployeeTile extends StatelessWidget {
  const _EmployeeTile({required this.employee});

  final Map<String, dynamic> employee;

  @override
  Widget build(BuildContext context) {
    final name = '${employee['full_name'] ?? 'Employee'}';
    final department = '${employee['department'] ?? '—'}';
    final position = '${employee['position'] ?? '—'}';
    final id = '${employee['employee_number'] ?? employee['staff_id'] ?? '—'}';
    final status =
        '${employee['employment_status'] ?? employee['status'] ?? 'active'}';
    final statusColor = status == 'active'
        ? AppColors.green
        : (status == 'suspended' ? AppColors.rose : AppColors.amber);

    return Material(
      // Theme-aware: a fixed white sheet left a column of bright blocks in
      // dark mode.
      color: AppColors.surface(context),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => context.go('/employees/${employee['id']}'),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              AvatarCircle(name: name, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '$position · $department',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary(context),
                      ),
                    ),
                    Text(
                      id,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.green,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              StatusBadge(label: status, color: statusColor),
            ],
          ),
        ),
      ),
    );
  }
}
