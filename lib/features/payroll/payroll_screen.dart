import 'package:flutter/material.dart';

import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';

class PayrollScreen extends StatefulWidget {
  const PayrollScreen({super.key});

  @override
  State<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends State<PayrollScreen> {
  List<Map<String, dynamic>> _records = [];
  String? _error;
  bool _loading = true;

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
      final user = SupabaseService.client.auth.currentUser;
      var employeeNumber = '';
      if (user != null) {
        final emp = await SupabaseService.client
            .from('employees')
            .select('employee_number, user_id, id')
            .eq('user_id', user.id)
            .limit(1)
            .maybeSingle();
        if (emp != null) {
          employeeNumber = '${emp['employee_number'] ?? ''}';
        }
      }
      final res = await SupabaseService.client
          .from('payroll_records')
          .select()
          .limit(12)
          .order('period_end', ascending: false);
      final rows = (res as List<dynamic>? ?? [])
          .where((r) {
            final m = r is Map ? r : const <String, dynamic>{};
            final no = '${m['employee_number'] ?? ''}';
            return no.isNotEmpty &&
                (no == employeeNumber || employeeNumber.isEmpty);
          })
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      if (!mounted) return;
      setState(() => _records = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: 'Payroll'),
      body: _loading
          ? const PageLoadingView(label: 'Loading payroll…')
          : _error != null
          ? PageErrorView(message: _error!, onRetry: _load)
          : _records.isEmpty
          ? const PageEmptyView(
              title: 'No payroll records',
              description: 'Payroll records will appear here once your payslips are generated.',
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: _records.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _PayslipCard(record: _records[i]),
              ),
            ),
    );
  }
}

class _PayslipCard extends StatelessWidget {
  const _PayslipCard({required this.record});

  final Map<String, dynamic> record;

  String _money(dynamic v) {
    final n = double.tryParse('${v ?? '0'}') ?? 0;
    return Fmt.money(n);
  }

  @override
  Widget build(BuildContext context) {
    final status = '${record['status'] ?? 'processed'}';
    final period = '${record['period_start'] ?? ''}'.isEmpty
        ? '${record['period'] ?? '—'}'
        : '${(record['period_start'] ?? '').toString().substring(0, 10)} — ${(record['period_end'] ?? '').toString().substring(0, 10)}';
    final net = _money(record['net_pay'] ?? record['gross_pay']);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Payslip',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        period,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusBadge(
                  label: status,
                  color: status == 'paid' ? AppColors.green : AppColors.amber,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _kv('Net pay', net)),
                if (record['gross_pay'] != null)
                  Expanded(child: _kv('Gross', _money(record['gross_pay']))),
                if (record['deductions'] != null)
                  Expanded(
                    child: _kv('Deductions', _money(record['deductions'])),
                  ),
              ],
            ),
            if (record['employee_number'] != null) ...[
              const SizedBox(height: 10),
              Text(
                'Employee: ${record['employee_number']}',
                style: const TextStyle(fontSize: 11, color: Colors.black38),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.black45),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.slate900,
          ),
        ),
      ],
    );
  }
}
