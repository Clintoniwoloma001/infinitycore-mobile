import 'package:flutter/material.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/biometrics.dart';
import '../../core/services/mobile_session_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/reminder_service.dart';
import '../../core/security/location_integrity.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/attendance_history_card.dart';
import '../../shared/widgets/common.dart';
import '../../features/scanner/terminal_scanner_screen.dart';
import 'attendance_service.dart';
import 'qr_terminal.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  final _service = AttendanceService.instance;

  EmployeeRef? _employee;
  AttendanceRecord? _today;
  List<AttendanceRecord> _history = [];
  List<BranchGeofence> _geofences = [];
  PositionFix? _position;
  String? _geoStatus = 'idle'; // idle | checking | ok | denied
  String? _error;
  bool _loading = true;
  bool _busy = false;
  String? _terminalId;
  String? _terminalName;

  @override
  void initState() {
    super.initState();
    NotificationService.quickActionChanged.addListener(_consumeQuickAction);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeQuickAction());
    _load();
  }

  @override
  void dispose() {
    NotificationService.quickActionChanged.removeListener(_consumeQuickAction);
    super.dispose();
  }

  void _consumeQuickAction() {
    if (!mounted) return;
    final action = NotificationService.takePendingQuickAction();
    if (action == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (action) {
        case NotificationQuickAction.clockIn:
          _clockIn();
        case NotificationQuickAction.clockOut:
          _clockOut();
      }
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final employee = await _service.getMyEmployee();
      final geofences = await _service.listGeofences().catchError(
        (_) => <BranchGeofence>[],
      );
      final today = employee == null
          ? null
          : await _service.getToday(employee.id);
      final history = employee == null
          ? <AttendanceRecord>[]
          : await _service.getHistory(employee.id, limit: 90);
      if (!mounted) return;
      setState(() {
        _employee = employee;
        _geofences = geofences;
        _today = today;
        _history = history;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Fetch a fresh fix through the same path used by both the preview button
  /// and clock actions. No cached value is consulted, so the first clock tap
  /// behaves exactly like a manual location refresh.
  Future<({PositionFix position, GeoCheck check})>
  _fetchCurrentLocation() async {
    if (!mounted) {
      throw StateError('Attendance screen is no longer available.');
    }
    setState(() => _geoStatus = 'checking');
    try {
      final position = await _service.currentLocation();
      final check = GeoCheck.evaluate(position.lat, position.lng, _geofences);
      if (mounted) {
        setState(() {
          _position = position;
          _geoStatus = 'ok';
        });
      }
      return (position: position, check: check);
    } catch (_) {
      if (mounted) setState(() => _geoStatus = 'denied');
      rethrow;
    }
  }

  Future<GeoCheck> _checkLocation() async {
    final result = await _fetchCurrentLocation();
    return result.check;
  }

  /// Gate a clock action behind the device's native biometric system when the
  /// device actually has usable biometric hardware. Devices without biometrics
  /// (or with failed/spoilt biometric firmware) still record attendance the
  /// normal way — location, branch, employee status and every other server
  /// check stay fully enforced. Returns if the action may proceed and whether
  /// a biometric assertion was actually performed.
  Future<({bool allow, bool biometricUsed})> _verifyIdentity() async {
    final session = MobileSessionService.instance;
    debugPrint(
      'Attendance._verifyIdentity: enforced=${session.enforced} biometricEnabled=${session.biometricEnabled}',
    );
    final usable = await biometricService.isUsable();
    debugPrint('Attendance._verifyIdentity: biometricUsable=$usable');
    if (session.enforced == true && usable && !session.biometricEnabled) {
      if (!mounted) return (allow: false, biometricUsed: false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.fingerprint, color: AppColors.green),
          title: const Text('Biometric attendance required'),
          content: const Text(
            'This device must be biometrically authorized before you can record '
            'attendance. Go to Profile → Biometric attendance to set it up.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Got it'),
            ),
          ],
        ),
      );
      return (allow: false, biometricUsed: false);
    }

    // No usable biometrics on this device — attendance proceeds through the
    // location / branch / employee-validity path. The server trusts the
    // device capability report (`biometric_capability = 'none'`) and still
    // enforces every geofence and identity check.
    if (!usable) {
      debugPrint(
        'Attendance._verifyIdentity: no biometrics on device; proceeding via geofence',
      );
      return (allow: true, biometricUsed: false);
    }

    final ok = await biometricService.authenticate(
      reason: 'Confirm your identity to record attendance',
    );
    debugPrint('Attendance._verifyIdentity: authenticate result=$ok');
    if (!ok) {
      // Record the failure on the server so MOBILE_BIOMETRIC_FAILURE is
      // audited. The result only — the OS never exposes the biometric.
      if (session.enforced == true) {
        try {
          await session.authenticateBiometric(false);
        } catch (_) {}
      }
      if (mounted)
        _fail(StateError('Identity not confirmed. Clock action cancelled.'));
      return (allow: false, biometricUsed: false);
    }

    if (session.enforced == true) {
      try {
        final serverOk = await session.authenticateBiometric(true);
        if (!serverOk) {
          if (mounted)
            _fail(
              StateError('Could not refresh biometric session on the server.'),
            );
          return (allow: false, biometricUsed: false);
        }
      } catch (e) {
        if (mounted) _fail(e);
        return (allow: false, biometricUsed: false);
      }
    }

    return (allow: true, biometricUsed: true);
  }

  Future<void> _clockIn() async {
    debugPrint(
      'Attendance._clockIn: busy=$_busy employee=${_employee == null} terminal=$_terminalId',
    );
    if (_busy || _employee == null) return;
    final verified = await _verifyIdentity();
    debugPrint(
      'Attendance._clockIn: verified=${verified.allow} biometricUsed=${verified.biometricUsed}',
    );
    if (!verified.allow) return;
    setState(() => _busy = true);
    try {
      final location = await _fetchCurrentLocation();
      final result = await _service.clockIn(
        location.position,
        biometricUsed: verified.biometricUsed,
        terminalId: _terminalId,
      );
      final record = await _service.getToday(_employee!.id);
      if (!mounted) return;
      setState(() {
        _today = record ?? _today;
        _position = location.position;
      });
      await NotificationService.instance.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: 'Clocked In',
        body: (result['late_minutes'] ?? 0) > 0
            ? 'You clocked in ${result['late_minutes']} minutes late today.'
            : 'You are clocked in. Have a productive day!',
        route: '/home',
      );
      _success('Clocked in. Have a productive day!');
      _load();
      await ReminderService.instance.sync();
    } catch (e) {
      debugPrint('Attendance._clockIn: error=${e.runtimeType}: $e');
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clockOut() async {
    final today = _today;
    if (_busy || today == null || !today.isClockedIn) return;
    final verified = await _verifyIdentity();
    if (!verified.allow) return;
    setState(() => _busy = true);
    try {
      final location = await _fetchCurrentLocation();
      final result = await _service.clockOut(
        today.id,
        geo: location.position,
        biometricUsed: verified.biometricUsed,
        terminalId: _terminalId,
      );
      if (!mounted) return;
      setState(() => _position = location.position);
      await NotificationService.instance.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: 'Clocked Out',
        body: 'You worked ${result['work_hours'] ?? '—'} hours today.',
        route: '/home',
      );
      _success('Clocked out. See you next time!');
      _load();
      await ReminderService.instance.sync();
    } catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openScanner() async {
    if (_busy) return;
    final result = await Navigator.of(context).push<TerminalScanResult>(
      MaterialPageRoute(builder: (_) => const TerminalScannerScreen()),
    );
    if (result == null || !mounted) return;
    if (result.terminal.terminalId == null) {
      _fail(StateError('The terminal could not be identified.'));
      return;
    }
    setState(() {
      _terminalId = result.terminal.terminalId;
      _terminalName = result.terminal.terminalName;
    });
    final name = result.terminal.terminalName?.isNotEmpty == true
        ? result.terminal.terminalName
        : 'Attendance terminal';
    _success(
      'Terminal selected: $name. Clock in or out to record attendance at this terminal.',
    );
  }

  void _clearTerminal() {
    setState(() {
      _terminalId = null;
      _terminalName = null;
    });
  }

  void _success(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.green,
      ),
    );
  }

  void _fail(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AttendanceService.normalizeError(e)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.rose,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final employee = _employee;
    if (_loading && _today == null) {
      return const PageLoadingView(label: 'Loading attendance…');
    }
    if (_error != null && employee == null && _today == null) {
      return PageErrorView(message: _error!, onRetry: _load);
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (employee == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No employee record is linked to this account yet. Contact HR '
                    'to link your profile before clocking in.',
                    style: TextStyle(color: AppColors.textSecondary(context)),
                  ),
                ),
              ),
            )
          else ...[
            const SizedBox(height: 4),
            _SessionBanner(),
            if (_position != null) ...[
              const SizedBox(height: 12),
              _LocationBanner(position: _position!),
            ],
            if (_today != null && _today!.clockIn != null) ...[
              const SizedBox(height: 12),
              _ServerLocationCard(record: _today!),
            ],
            const SizedBox(height: 12),
            _ClockCard(
              employee: employee,
              today: _today,
              busy: _busy,
              geoStatus: _geoStatus!,
              onClockIn: _clockIn,
              onClockOut: _clockOut,
              onRefreshLocation: _checkLocation,
            ),
            const SizedBox(height: 12),
            _QrTerminalEntry(
              terminalName: _terminalName,
              busy: _busy,
              onScan: _openScanner,
              onClear: _clearTerminal,
            ),
            const SizedBox(height: 12),
            AttendanceHistoryCard(records: _history, maxRows: 12),
          ],
        ],
      ),
    );
  }
}

class _SessionBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final enforced = MobileSessionService.instance.enforced;
    if (enforced == false) return const SizedBox.shrink();
    if (enforced == null) return const SizedBox.shrink();
    assert(enforced == true);
    return const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(Icons.shield, size: 16, color: AppColors.green),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Device checks active: your session is bound to this phone.',
              style: TextStyle(fontSize: 12, color: AppColors.greenDark),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClockCard extends StatelessWidget {
  const _ClockCard({
    required this.employee,
    required this.today,
    required this.busy,
    required this.geoStatus,
    required this.onClockIn,
    required this.onClockOut,
    required this.onRefreshLocation,
  });

  final EmployeeRef employee;
  final AttendanceRecord? today;
  final bool busy;
  final String geoStatus;
  final VoidCallback onClockIn;
  final VoidCallback onClockOut;
  final Future<GeoCheck> Function() onRefreshLocation;

  @override
  Widget build(BuildContext context) {
    final isClockedIn = today?.isClockedIn ?? false;
    final clockInAt = today?.clockIn;
    final lateMinutes = today?.lateMinutes ?? 0;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AvatarCircle(name: employee.fullName, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        employee.fullName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${employee.position} · ${employee.department}',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                StatusBadge(
                  label: isClockedIn ? 'Clocked in' : 'Not clocked in',
                  color: isClockedIn ? AppColors.green : AppColors.amber,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _TodayStatus(clockIn: clockInAt, clockOut: today?.clockOut),
            if (clockInAt != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.schedule, size: 16, color: AppColors.green),
                  const SizedBox(width: 6),
                  Text(
                    'Clocked in at ${Fmt.clock(clockInAt)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (today!.clockOut != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      '· out at ${Fmt.clock(today!.clockOut)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                  if (lateMinutes > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      '· ${Fmt.lateDuration(lateMinutes)} late',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.amber,
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy || isClockedIn ? null : onClockIn,
                    icon: const Icon(Icons.login),
                    label: const Text('Clock In'),
                    style: FilledButton.styleFrom(
                      backgroundColor: isClockedIn
                          ? Colors.black26
                          : AppColors.green,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy || !isClockedIn ? null : onClockOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('Clock Out'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.rose,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: busy ? null : () => onRefreshLocation(),
                  tooltip: 'Refresh location',
                  icon: const Icon(Icons.my_location, size: 18),
                ),
              ],
            ),
            if (geoStatus == 'checking')
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Checking location…', style: TextStyle(fontSize: 12)),
                  ],
                ),
              )
            else if (geoStatus == 'denied')
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Location is required to clock in or out. Grant location '
                  'permission in system settings.',
                  style: TextStyle(fontSize: 12, color: AppColors.rose),
                ),
              )
            else
              _SecurityStatusLines(geoStatus: geoStatus),
          ],
        ),
      ),
    );
  }
}

class _QrTerminalEntry extends StatelessWidget {
  const _QrTerminalEntry({
    required this.terminalName,
    required this.busy,
    required this.onScan,
    required this.onClear,
  });

  final String? terminalName;
  final bool busy;
  final VoidCallback onScan;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final selected = terminalName != null;
    final accent = AppColors.accent(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.qr_code_scanner, size: 19, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selected ? 'Attendance terminal' : 'QR attendance terminal',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selected
                        ? terminalName!
                        : 'Scan a terminal QR to anchor your clock action.',
                    style: TextStyle(
                      fontSize: 12,
                      color: selected
                          ? AppColors.textPrimary(context)
                          : AppColors.textSecondary(context),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (selected)
              IconButton(
                onPressed: busy ? null : onClear,
                tooltip: 'Clear terminal',
                icon: const Icon(Icons.close, size: 18),
              ),
            OutlinedButton.icon(
              onPressed: busy ? null : onScan,
              icon: const Icon(Icons.qr_code_scanner, size: 16),
              label: Text(selected ? 'Scan again' : 'Scan QR'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodayStatus extends StatelessWidget {
  const _TodayStatus({this.clockIn, this.clockOut});

  final String? clockIn;
  final String? clockOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.isDark(context)
            ? AppColors.secondaryDark
            : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Today\u2019s Status',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          _line(context, 'Clock In', Fmt.clock(clockIn)),
          const SizedBox(height: 4),
          _line(context, 'Clock Out', Fmt.clock(clockOut)),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(
            '$label:',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary(context),
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary(context),
          ),
        ),
      ],
    );
  }
}

/// Biometric requirement + location availability lines shown under the
/// clock controls. Info only — the server remains the authority.
class _SecurityStatusLines extends StatelessWidget {
  const _SecurityStatusLines({this.geoStatus = 'idle'});

  final String geoStatus;

  @override
  Widget build(BuildContext context) {
    final session = MobileSessionService.instance;
    final enforced = session.enforced == true;
    final biometricOk = enforced
        ? session.biometricEnabled
        : AuthService.instance.biometricEnabled;
    final locationOk = geoStatus == 'ok';

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                biometricOk ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 14,
                color: biometricOk ? AppColors.green : AppColors.amber,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Biometric Authentication',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
              Text(
                biometricOk ? 'Enabled' : 'Not configured',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: biometricOk ? AppColors.green : AppColors.amber,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                locationOk ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 14,
                color: locationOk ? AppColors.green : AppColors.amber,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Location',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ),
              Text(
                locationOk
                    ? 'Available'
                    : geoStatus == 'denied'
                    ? 'Unavailable'
                    : '—',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: locationOk ? AppColors.green : AppColors.amber,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Server-verified location for today's record (from the CLOCK_IN event).
class _ServerLocationCard extends StatelessWidget {
  const _ServerLocationCard({required this.record});

  final AttendanceRecord record;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[];
    if (record.actualLocationName.isNotEmpty) {
      lines.add('Captured at ${record.actualLocationName}');
    }
    if (record.geofenceStatus.isNotEmpty) {
      lines.add('Geofence: ${Fmt.titleCase(record.geofenceStatus)}');
    }
    if (record.locationStatus.isNotEmpty) {
      lines.add(
        'Position: ${record.locationStatus == 'inside' ? 'Inside approved area' : Fmt.titleCase(record.locationStatus)}',
      );
    }
    if (record.clockInDistance != null) {
      lines.add('Distance: ${record.clockInDistance!.toStringAsFixed(0)} m');
    }
    if (record.clockInLat != null && record.clockInLng != null) {
      lines.add(
        '(${record.clockInLat!.toStringAsFixed(6)}, ${record.clockInLng!.toStringAsFixed(6)})',
      );
    }
    final inside = record.isInsideGeofence;
    final dark = AppColors.isDark(context);
    return Card(
      margin: EdgeInsets.zero,
      color: inside
          ? (dark ? SurfaceColors.successTintDark : const Color(0xFFF0FDF4))
          : (dark ? SurfaceColors.warningTintDark : const Color(0xFFFFF7ED)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: inside
              ? (dark
                    ? SurfaceColors.successBorderDark
                    : const Color(0xFFBBF7D0))
              : (dark
                    ? SurfaceColors.warningBorderDark
                    : const Color(0xFFFED7AA)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              inside ? Icons.verified_outlined : Icons.warning_amber_rounded,
              size: 18,
              color: inside ? AppColors.green : AppColors.amber,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    inside
                        ? 'Server location verified'
                        : 'Location flagged for review',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  for (final l in lines)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        l,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textPrimary(context),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationBanner extends StatelessWidget {
  const _LocationBanner({required this.position});

  final PositionFix position;

  @override
  Widget build(BuildContext context) {
    final emulatorDefault = LocationIntegrity.instance.looksLikeEmulatorDefault(
      position.lat,
      position.lng,
    );
    return Card(
      margin: EdgeInsets.zero,
      color: AppColors.isDark(context)
          ? AppColors.surfaceDark
          : const Color(0xFFEFF6FF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.isDark(context)
              ? AppColors.borderDark
              : const Color(0xFFBFDBFE),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              emulatorDefault ? Icons.gps_off : Icons.gps_fixed,
              size: 16,
              color: emulatorDefault ? AppColors.amber : AppColors.blue,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Current fix: ${position.lat.toStringAsFixed(6)}, '
                '${position.lng.toStringAsFixed(6)} '
                '(±${position.accuracy.toStringAsFixed(1)}m). '
                '${emulatorDefault ? 'This is the Android emulator\u2019s default Googleplex '
                          'location, not a real GPS fix. Set the device location '
                          '(emulator \u22EE \u2192 Location) or use a physical '
                          'device before clocking in.' : 'The server treats this as authoritative attendance '
                          'evidence.'}',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textPrimary(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
