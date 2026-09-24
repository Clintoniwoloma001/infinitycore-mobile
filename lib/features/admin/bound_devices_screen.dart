import 'package:flutter/material.dart';

import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';

/// Super Admin / Head of HR screen for managing authorized mobile devices.
///
/// Filtering, unbinding and summary are server-authorized (the RPCs re-check
/// `current_role()`), so a hidden menu item is never the only line of defense.
class BoundDevicesScreen extends StatefulWidget {
  const BoundDevicesScreen({super.key});

  @override
  State<BoundDevicesScreen> createState() => _BoundDevicesScreenState();
}

class _BoundDevicesScreenState extends State<BoundDevicesScreen> {
  List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic> _summary = const {};
  bool _loading = true;
  String? _error;
  String _query = '';
  String _platformFilter = '';
  String _statusFilter = '';
  String _biometricFilter = '';

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
      final params = <String, dynamic>{
        'p_search': _query.trim().isEmpty ? '' : _query.trim(),
      };
      if (_platformFilter.isNotEmpty) params['p_platform'] = _platformFilter;
      if (_statusFilter.isNotEmpty) params['p_status'] = _statusFilter;
      if (_biometricFilter.isNotEmpty) {
        params['p_biometric_status'] = _biometricFilter;
      }

      final summaryRaw = await SupabaseService.client.rpc(
        'mobile_device_management_summary',
      );

      final data = await SupabaseService.client.rpc<List<dynamic>>(
        'mobile_list_authorized_devices',
        params: params,
      );
      if (!mounted) return;
      setState(() {
        _summary = summaryRaw is Map<String, dynamic>
            ? summaryRaw
            : <String, dynamic>{};
        _rows = data
            .map(
              (v) => v is Map<String, dynamic>
                  ? v
                  : Map<String, dynamic>.from(v as Map),
            )
            .toList();
      });
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unbind(Map<String, dynamic> row) async {
    final sessionId = row['session_id']?.toString() ?? '';
    if (sessionId.isEmpty) return;

    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(
          Icons.phonelink_erase_outlined,
          color: AppColors.amber,
        ),
        title: const Text('Unbind device?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Unbinding this device will revoke '
                '${row['employee_name'] ?? 'this employee'}\'s current mobile '
                'authorization. The employee will need to authorize their new '
                'device before using biometric attendance.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary(context),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  hintText: 'e.g. Lost phone, replacement device',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.amber),
            child: const Text('Unbind'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _loading = true);
    try {
      await SupabaseService.client.rpc<Map<String, dynamic>>(
        'mobile_admin_revoke_device',
        params: {
          'p_session_id': sessionId,
          'p_reason': controller.text.trim().isEmpty
              ? 'hr_admin_unbind'
              : controller.text.trim(),
        },
      );
      await _load();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not unbind device: $e'),
            backgroundColor: AppColors.rose,
          ),
        );
      }
    } finally {
      controller.dispose();
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _viewDetails(Map<String, dynamic> row) async {
    final revoked = row['status']?.toString() == 'revoked';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(row['employee_name']?.toString() ?? 'Device details'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InfoRow(
                label: 'Employee',
                value: row['employee_name']?.toString() ?? '—',
              ),
              InfoRow(
                label: 'Employee ID',
                value: row['employee_number']?.toString() ?? '—',
              ),
              InfoRow(label: 'Email', value: row['email']?.toString() ?? '—'),
              InfoRow(
                label: 'Department',
                value: row['department']?.toString() ?? '—',
              ),
              InfoRow(
                label: 'Branch',
                value: row['branch_name']?.toString() ?? '—',
              ),
              InfoRow(
                label: 'Device',
                value: row['device_model']?.toString() ?? '—',
              ),
              InfoRow(
                label: 'Platform',
                value: row['platform']?.toString() ?? '—',
              ),
              InfoRow(
                label: 'OS version',
                value: row['os_version']?.toString() ?? '—',
              ),
              InfoRow(
                label: 'App version',
                value: row['app_version']?.toString() ?? '—',
              ),
              InfoRow(
                label: 'Biometric',
                value: row['biometric_enabled'] == true
                    ? (row['biometric_capability']?.toString().isNotEmpty ==
                              true
                          ? row['biometric_capability'].toString()
                          : 'Enabled')
                    : 'Not configured',
              ),
              InfoRow(
                label: 'Linked',
                value: Fmt.dateTime(row['linked_at']?.toString()),
              ),
              InfoRow(
                label: 'Last biometric',
                value: Fmt.dateTime(row['last_authenticated_at']?.toString()),
              ),
              InfoRow(
                label: 'Last attendance',
                value: Fmt.dateTime(row['last_attendance_at']?.toString()),
              ),
              InfoRow(
                label: 'Last seen',
                value: Fmt.dateTime(row['last_seen_at']?.toString()),
              ),
              if (revoked) ...[
                InfoRow(
                  label: 'Revoked',
                  value: Fmt.dateTime(row['revoked_at']?.toString()),
                ),
                InfoRow(
                  label: 'Revoke reason',
                  value: row['revoked_reason']?.toString() ?? '—',
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  bool get _authorized {
    final role = AuthService.instance.profile?.role ?? '';
    return role == AppRoles.superAdmin || role == AppRoles.headOfHumanResources;
  }

  @override
  Widget build(BuildContext context) {
    if (!_authorized) {
      return Scaffold(
        appBar: shellAppBar(context, title: 'Bound app devices'),
        body: const PageErrorView(
          message: 'Not authorized',
          detail: 'Only Super Admin and Head of HR can manage bound devices.',
        ),
      );
    }

    return Scaffold(
      appBar: shellAppBar(context, title: 'Bound app devices'),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SummaryStrip(summary: _summary),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                labelText: 'Search employee, email or device',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
              onChanged: (v) => _query = v,
              onSubmitted: (_) => _load(),
            ),
            const SizedBox(height: 12),
            _FilterChips(
              title: 'Platform',
              options: const [
                ('All', ''),
                ('iOS', 'ios'),
                ('Android', 'android'),
                ('Other', 'other'),
              ],
              selected: _platformFilter,
              onChanged: (v) {
                _platformFilter = v;
                _load();
              },
            ),
            _FilterChips(
              title: 'Status',
              options: const [
                ('All', ''),
                ('Active', 'active'),
                ('Revoked', 'revoked'),
              ],
              selected: _statusFilter,
              onChanged: (v) {
                _statusFilter = v;
                _load();
              },
            ),
            _FilterChips(
              title: 'Biometric',
              options: const [
                ('All', ''),
                ('Enabled', 'enabled'),
                ('Awaiting setup', 'disabled'),
              ],
              selected: _biometricFilter,
              onChanged: (v) {
                _biometricFilter = v;
                _load();
              },
            ),
            const SizedBox(height: 12),
            Text(
              '${_rows.length} device${_rows.length == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 8),
            if (_loading && _rows.isEmpty)
              const PageLoadingView(label: 'Loading bound devices…')
            else if (_error != null && _rows.isEmpty)
              PageErrorView(message: _error!, onRetry: _load)
            else if (_rows.isEmpty)
              const PageEmptyView(
                title: 'No bound devices',
                description:
                    'Authorized mobile devices matching these filters '
                    'will appear here.',
              )
            else
              ..._rows.map(
                (r) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _DeviceRow(
                    row: r,
                    onUnbind: () => _unbind(r),
                    onView: () => _viewDetails(r),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final Map<String, dynamic> summary;

  @override
  Widget build(BuildContext context) {
    int n(String key) => int.tryParse(summary[key]?.toString() ?? '') ?? 0;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatCard(
                label: 'Bound devices',
                value: '${n('bound_devices')}',
                icon: Icons.phonelink_lock_outlined,
                accent: AppColors.green,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatCard(
                label: 'Biometric enabled',
                value: '${n('biometric_enabled')}',
                icon: Icons.fingerprint,
                accent: AppColors.blue,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: StatCard(
                label: 'Awaiting setup',
                value: '${n('awaiting_biometric_setup')}',
                icon: Icons.hourglass_top,
                accent: AppColors.amber,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatCard(
                label: 'Revoked',
                value: '${n('revoked_devices')}',
                icon: Icons.block,
                accent: AppColors.rose,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.title,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final String title;
  final List<(String, String)> options;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final (label, value) in options)
                ChoiceChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  selected: selected == value,
                  selectedColor: AppColors.green.withValues(alpha: 0.16),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: selected == value ? AppColors.greenDark : null,
                    fontWeight: selected == value
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                  side: BorderSide(
                    color: selected == value
                        ? AppColors.green
                        : AppColors.border(context),
                  ),
                  onSelected: (_) => onChanged(value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.row,
    required this.onUnbind,
    required this.onView,
  });

  final Map<String, dynamic> row;
  final VoidCallback onUnbind;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final status = (row['status'] ?? 'active').toString();
    final biometric = row['biometric_enabled'] == true;
    final statusColor = status == 'active' ? AppColors.green : AppColors.rose;
    final lastUsed =
        row['last_attendance_at']?.toString() ??
        row['last_authenticated_at']?.toString() ??
        row['last_seen_at']?.toString();

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AvatarCircle(
                  name: row['employee_name']?.toString() ?? 'Unknown',
                  size: 40,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row['employee_name']?.toString() ?? 'Unknown',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [
                          if (row['employee_number'] != null)
                            row['employee_number'].toString(),
                          if (row['email'] != null) row['email'].toString(),
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                StatusBadge(label: status, color: statusColor),
              ],
            ),
            const SizedBox(height: 10),
            _row('Employee ID', row['employee_number']?.toString() ?? '—'),
            _row('Account', row['email']?.toString() ?? '—'),
            _row('Branch', row['branch_name']?.toString() ?? '—'),
            _row('Department', row['department']?.toString() ?? '—'),
            _row('Device', row['device_model']?.toString() ?? '—'),
            _row('Platform', row['platform']?.toString() ?? '—'),
            _row('OS', row['os_version']?.toString() ?? '—'),
            _row('App', row['app_version']?.toString() ?? '—'),
            _row(
              'Biometric',
              biometric
                  ? (row['biometric_capability']?.toString().isNotEmpty == true
                        ? row['biometric_capability'].toString()
                        : 'Enabled')
                  : 'Not configured',
            ),
            _row('Linked', Fmt.dateTimeShort(row['linked_at']?.toString())),
            _row('Last used', Fmt.dateTimeShort(lastUsed)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onView,
                  icon: const Icon(Icons.info_outline, size: 18),
                  label: const Text('View'),
                ),
                if (status == 'active') ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: onUnbind,
                    icon: const Icon(Icons.phonelink_erase_outlined, size: 18),
                    label: const Text('Unbind'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.amber,
                      side: const BorderSide(color: AppColors.amber),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: const TextStyle(fontSize: 11)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
