import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/biometrics.dart';
import '../../core/services/device_identity.dart';
import '../../core/services/employee_photo.dart';
import '../../core/services/mobile_session_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import '../attendance/attendance_service.dart';

/// Employee + account screen. Rendered inside the home shell as the Profile
/// tab; the router also mounts it standalone behind a scaffold.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  EmployeeRef? _employee;
  String? _photoUrl;
  int? _phoneYears;
  bool _signingOut = false;
  List<SupervisorRef> _supervisors = const [];

  @override
  void initState() {
    super.initState();
    MobileSessionService.instance.addListener(_onSession);
    _load();
  }

  @override
  void dispose() {
    MobileSessionService.instance.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final employee = await AttendanceService.instance
        .getMyEmployee()
        .catchError((_) => null);
    String? photo;
    if (employee != null) {
      photo = await _photoFor(employee.id);
    }
    List<SupervisorRef> supervisors = const [];
    if (employee != null) {
      supervisors = await AttendanceService.instance
          .getMySupervisor(employeeId: employee.id)
          .catchError((_) => const <SupervisorRef>[]);
    }
    if (mounted) {
      setState(() {
        _employee = employee;
        _photoUrl = photo;
        _phoneYears = employee?.joinedYear;
        _supervisors = supervisors;
      });
    }
  }

  Future<String?> _photoFor(String employeeId) =>
      EmployeePhoto.signedUrlFor(employeeId);

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    try {
      await AuthService.instance.signOut();
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  Future<void> _toggleBiometrics(bool value) async {
    try {
      if (value) {
        final can = await biometricService.isUsable();
        if (!can) {
          if (mounted) {
            _showError(
              'This device has no usable biometric method. You can still '
              'record attendance normally using the attendance location check.',
            );
          }
          return;
        }

        final ok = await biometricService.authenticate(
          reason: 'Enable biometric attendance for InfinityCore',
        );
        if (!ok) {
          if (mounted) {
            _showError('Biometric verification failed or was cancelled.');
          }
          return;
        }

        await MobileSessionService.instance.linkBiometric();
        await MobileSessionService.instance.authenticateBiometric(true);
        await AuthService.instance.setBiometricEnabled(true);
        if (mounted) {
          _showMessage(
            'Your device\u2019s biometric authentication is enabled for '
            'InfinityCore attendance.',
          );
        }
      } else {
        await AuthService.instance.setBiometricEnabled(false);
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) _showError('Could not update biometric setting: $e');
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  void _showError(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.rose,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final profile = auth.access.profile;
    final status = profile.status;
    final statusColor = status == 'active' ? AppColors.green : AppColors.amber;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _identityCard(
            profile: profile,
            status: status,
            statusColor: statusColor,
          ),
          const SizedBox(height: 12),
          if (_employee != null) _employeeCard(_employee!),
          const SizedBox(height: 12),
          const _AppearanceSection(),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Security',
            children: [
              _biometricSection(),
              const Divider(height: 1),
              _sessionTile(),
              const Divider(height: 1),
              _deviceTile(),
              if (_canManageDevices) ...[
                const Divider(height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices_outlined, size: 20),
                  title: const Text(
                    'Bound app devices',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    'Manage authorized mobile devices',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => context.go('/bound-devices'),
                ),
              ],
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Sign out',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.rose,
                  ),
                ),
                subtitle: Text(
                  'End your InfinityCore session on this device',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary(context),
                  ),
                ),
                trailing: _signingOut
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.logout, size: 18),
                onTap: _signingOut ? null : _signOut,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _proofTile(),
        ],
      ),
    );
  }

  Widget _identityCard({
    required Profile profile,
    required String status,
    required Color statusColor,
  }) {
    final name = _employee?.fullName.isNotEmpty == true
        ? _employee!.fullName
        : profile.fullName.isNotEmpty
        ? profile.fullName
        : 'InfinityCore member';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _avatar(name),
            const SizedBox(height: 12),
            Text(
              name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            if (profile.email.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                profile.email,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                StatusBadge(label: AppRoles.label(profile.role)),
                StatusBadge(label: status, color: statusColor),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(String name) {
    final photo = _photoUrl;
    if (photo == null || photo.isEmpty) {
      return AvatarCircle(name: name, size: 80);
    }
    return ClipOval(
      child: Image.network(
        photo,
        width: 80,
        height: 80,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => AvatarCircle(name: name, size: 80),
      ),
    );
  }

  Widget _employeeCard(EmployeeRef e) {
    return SectionCard(
      title: 'Employment',
      children: [
        InfoRow(label: 'Employee ID', value: e.displayId),
        InfoRow(
          label: 'Position',
          value: e.position.isEmpty ? 'Not recorded' : e.position,
        ),
        InfoRow(
          label: 'Department',
          value: e.department.isEmpty ? 'Not recorded' : e.department,
        ),
        InfoRow(
          label: 'Branch',
          value: e.branchName.isNotEmpty
              ? e.branchName
              : (e.branch.isEmpty ? '—' : e.branch),
        ),
        if (_supervisors.isNotEmpty) ...[
          const Divider(height: 16),
          for (final sup in _supervisors) ...[
            _supervisorRow(sup),
            const SizedBox(height: 8),
          ],
        ],
        InfoRow(label: 'Area', value: e.area.isEmpty ? '—' : e.area),
        InfoRow(
          label: 'Manager',
          value: e.managerName.isEmpty ? '—' : e.managerName,
        ),
        InfoRow(label: 'Phone', value: e.phone.isEmpty ? '—' : e.phone),
        InfoRow(
          label: 'Joined',
          value: _phoneYears == null ? '—' : '$_phoneYears',
        ),
      ],
    );
  }

  bool get _canManageDevices {
    final role = AuthService.instance.profile?.role ?? '';
    return role == AppRoles.superAdmin || role == AppRoles.headOfHumanResources;
  }

  Widget _supervisorRow(SupervisorRef sup) {
    final role = sup.supervisorTitle.isNotEmpty
        ? sup.supervisorTitle
        : sup.supervisorPosition.isNotEmpty
        ? sup.supervisorPosition
        : '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(Icons.supervisor_account_outlined, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sup.supervisorName.isEmpty
                    ? (sup.level == 1 ? 'Supervisor' : 'Line manager')
                    : sup.supervisorName,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (role.isNotEmpty)
                Text(
                  '$role${sup.supervisorDepartment.isNotEmpty ? ' · ${sup.supervisorDepartment}' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary(context),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Profile → Biometric → Link Biometric entry point.
  ///
  /// The switch links a successful native biometric assertion to this
  /// authorized device/account. Only the assertion result reaches the server;
  /// the operating system owns the biometric and InfinityCore never receives
  /// a template, image, fingerprint, or Face ID data.
  Widget _biometricSection() {
    final session = MobileSessionService.instance;
    final enabled = AuthService.instance.biometricEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.fingerprint, size: 20, color: AppColors.green),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Biometric Attendance',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
            StatusBadge(
              label: enabled ? 'Enabled' : 'Not configured',
              color: enabled ? AppColors.green : AppColors.amber,
            ),
          ],
        ),
        if (enabled) ...[
          const SizedBox(height: 10),
          FutureBuilder<Map<String, dynamic>>(
            future: DeviceIdentity.instance.describe(),
            builder: (context, snap) {
              final v = snap.data ?? const <String, dynamic>{};
              final model = v['deviceModel'] ?? '';
              final platform = v['platform'] ?? '';
              final os = v['osVersion'] ?? '';
              final device = [
                if (model.isNotEmpty) model,
                if (platform.isNotEmpty) Fmt.titleCase('$platform'),
                if (os.isNotEmpty) 'OS $os',
              ].join(' · ');
              final method =
                  (session.capability != null && session.capability!.isNotEmpty)
                  ? 'Native device biometric (${session.capability})'
                  : 'Native device biometric';
              return Column(
                children: [
                  InfoRow(label: 'Status', value: 'Enabled'),
                  InfoRow(
                    label: 'Device',
                    value: device.isEmpty ? 'This device' : device,
                  ),
                  InfoRow(label: 'Method', value: method),
                  InfoRow(
                    label: 'Linked',
                    value: Fmt.dateShort(session.linkedAt),
                  ),
                  InfoRow(
                    label: 'Last authentication',
                    value: Fmt.dateTimeShort(session.lastAuthenticatedAt),
                  ),
                  if (session.lastAttendanceAt != null)
                    InfoRow(
                      label: 'Last attendance',
                      value: Fmt.dateTimeShort(session.lastAttendanceAt),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Link Biometric',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            _biometricSubtitle,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary(context),
            ),
          ),
          value: enabled,
          activeTrackColor: AppColors.green,
          onChanged: (v) => _toggleBiometrics(v),
        ),
      ],
    );
  }

  String get _biometricSubtitle {
    if (AuthService.instance.biometricEnabled) {
      return 'Your device\u2019s biometric authentication is enabled for '
          'InfinityCore attendance.';
    }
    return 'Optional on this device — use Face ID / fingerprint to secure '
        'attendance, or rely on the normal attendance location check.';
  }

  Widget _sessionTile() {
    final session = MobileSessionService.instance;
    final label = switch (session.enforced) {
      true => 'Device session active',
      false => 'Server session management unavailable',
      null => 'Checking mobile session…',
    };
    final subtitle = session.blockedReason != null
        ? session.blockedReason!
        : session.sessionId != null
        ? 'Session ${session.sessionId!.substring(0, 8)}'
        : 'One active device per account, enforced by the server';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        session.blockedReason != null
            ? Icons.warning_amber_rounded
            : Icons.shield_outlined,
        size: 20,
        color: session.blockedReason != null ? AppColors.amber : null,
      ),
      title: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 11, color: AppColors.textSecondary(context)),
      ),
    );
  }

  Widget _deviceTile() {
    return FutureBuilder<Map<String, dynamic>>(
      future: DeviceIdentity.instance.describe(),
      builder: (context, snap) {
        final v = snap.data ?? const <String, dynamic>{};
        final platform = v['platform'] ?? '';
        final version = v['appVersion'] ?? '';
        final model = v['deviceModel'] ?? '';
        final os = v['osVersion'] ?? '';
        final rows = [
          if (model.isNotEmpty) model,
          if (platform.isNotEmpty) Fmt.titleCase('$platform'),
          if (os.isNotEmpty) 'OS $os',
          if (version.isNotEmpty) 'v$version',
        ];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.phone_android, size: 20),
          title: const Text(
            'Device',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            rows.isEmpty ? 'This device' : rows.join(' · '),
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary(context),
            ),
          ),
        );
      },
    );
  }

  Widget _proofTile() {
    return SectionCard(
      title: 'Device-bound attendance',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.gps_fixed, size: 16, color: AppColors.green),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Clock actions require this authorized device, a successful '
                'native biometric assertion, and GPS coordinates. The server '
                'validates device binding, geofence and one-device-per-user '
                'policy before recording attendance. No fingerprint or Face ID '
                'data is ever sent to InfinityCore.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        final mode = ThemeController.instance.mode;
        return SectionCard(
          title: 'Appearance',
          children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto_outlined, size: 16),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (sel) =>
                    ThemeController.instance.setMode(sel.first),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              mode == ThemeMode.dark
                  ? 'Dark theme active on this device.'
                  : mode == ThemeMode.light
                  ? 'Light theme active on this device.'
                  : 'Follows the system appearance setting.',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
        );
      },
    );
  }
}
