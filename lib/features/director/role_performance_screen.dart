// Performance by business role: loan officers, branch managers, area managers.
// Reuses the existing KPI / target model through the director snapshot - no
// second, parallel target system is created here.
import 'package:flutter/material.dart';

import 'director_service.dart';
import 'director_widgets.dart';
import 'employee_profile_screen.dart';
import '../../core/theme/app_theme.dart';

class RolePerformanceScreen extends StatefulWidget {
  const RolePerformanceScreen({super.key});

  @override
  State<RolePerformanceScreen> createState() => _RolePerformanceScreenState();
}

class _RolePerformanceScreenState extends State<RolePerformanceScreen> {
  List<Map<String, dynamic>> _roles = const [];
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
        _roles = snap.roles;
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
      // No app bar: DirectorShell supplies it, together with the menu and
      // notification bell, so the executive can reach Profile, I-Meet,
      // Training and Automation. See director_shell.dart.
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : _roles.isEmpty
          ? Center(
              child: Text(
                'No target data recorded for this period.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary(context),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _roles.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) =>
                    _RoleCard(role: _roles[i], onOpen: _openPerson),
              ),
            ),
    );
  }

  void _openPerson(Map<String, dynamic> person) {
    final id = text(person['employee_id']);
    if (id == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmployeeProfileScreen(
          employeeId: id,
          fallbackName: text(person['full_name']),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.role, required this.onOpen});

  final Map<String, dynamic> role;
  final void Function(Map<String, dynamic>) onOpen;

  @override
  Widget build(BuildContext context) {
    final assigned = asDouble(role['target'] ?? role['assigned']);
    final actual = asDouble(role['actual'] ?? role['achieved']);
    final completion = asDouble(
      role['completion'] ?? role['target_completion'],
    );
    final remaining = (assigned != null && actual != null)
        ? assigned - actual
        : null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  text(role['role']) ?? text(role['name']) ?? 'Role',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                fmtPct(completion) ?? '--',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF009944),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                'Target ${compactMoney(assigned) ?? '--'}',
                style: const TextStyle(fontSize: 11),
              ),
              const Text('  ·  ', style: TextStyle(fontSize: 11)),
              Text(
                'Actual ${compactMoney(actual) ?? '--'}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          MetricBar(value: completion),
          if (remaining != null) ...[
            const SizedBox(height: 4),
            Text(
              'Remaining ${compactMoney(remaining)}',
              style: TextStyle(
                fontSize: 9,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
          // When the server supplied a person for this role, make it tappable so
          // the director can drill straight into the individual.
          if (text(role['employee_id']) != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => onOpen(role),
                child: const Text(
                  'View person',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
