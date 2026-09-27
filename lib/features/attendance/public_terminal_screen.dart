import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import 'attendance_service.dart';

/// Public QR attendance terminal.
///
/// Mirrors `AttendanceTerminal.jsx`: with a token the flow is intentionally
/// anonymous — no InfinityCore login, no private employee data. Identity is
/// resolved server-side by employee number, location is captured and
/// validated by the server (geofence + sister-branch rules), and the
/// authoritative clocking is done by RPC. Without a token the screen behaves
/// as an authenticated terminal tied to an attendance device.
class PublicAttendanceTerminalScreen extends StatefulWidget {
  const PublicAttendanceTerminalScreen({super.key, this.initialToken});

  final String? initialToken;

  @override
  State<PublicAttendanceTerminalScreen> createState() =>
      _PublicAttendanceTerminalScreenState();
}

class _PublicAttendanceTerminalScreenState
    extends State<PublicAttendanceTerminalScreen> {
  final _service = AttendanceService.instance;
  final _idController = TextEditingController();

  late final bool publicMode = widget.initialToken?.isNotEmpty == true;
  String get _token => widget.initialToken ?? '';

  List<Map<String, dynamic>> _devices = [];
  String? _selectedDeviceId;

  Map<String, dynamic>? _confirmed;
  Map<String, dynamic>? _locationCheck;
  String? _result;
  String? _error;
  bool _busy = false;
  String _geoStatus = 'idle';

  @override
  void initState() {
    super.initState();
    if (!publicMode) _loadDevices();
  }

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      final res = await SupabaseService.client
          .from('attendance_devices')
          .select('id, device_name, status, active, branch_id')
          .eq('device_type', 'attendance_terminal')
          .order('created_at');
      if (mounted) {
        setState(() {
          _devices = (res as List<dynamic>? ?? [])
              .whereType<Map<String, dynamic>>()
              .where((d) => d['status'] == 'active')
              .toList();
        });
      }
    } catch (_) {}
  }

  String _greeting() {
    try {
      tzdata.initializeTimeZones();
      final loc = tz.getLocation('Africa/Lagos');
      final now = tz.TZDateTime.now(loc);
      final h = now.hour;
      if (h < 12) return 'Good morning';
      if (h < 17) return 'Good afternoon';
      return 'Good evening';
    } catch (_) {
      final h = DateTime.now().hour;
      if (h < 12) return 'Good morning';
      if (h < 17) return 'Good afternoon';
      return 'Good evening';
    }
  }

  String _nowTime() {
    try {
      tzdata.initializeTimeZones();
      final loc = tz.getLocation('Africa/Lagos');
      final now = tz.TZDateTime.now(loc);
      return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    } catch (_) {
      final now = DateTime.now();
      return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _verifyEmployee() async {
    final id = _idController.text.trim();
    if (id.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _confirmed = null;
      _locationCheck = null;
    });
    try {
      if (publicMode) {
        final lookup = await _service.validatePublicTerminalEmployee(
          _token,
          id,
        );
        if (lookup['valid'] != true) {
          setState(
            () => _error = '${lookup['error'] ?? 'Employee ID not found.'}',
          );
          return;
        }
        final confirmed = {
          'employee_number': id,
          'employee_name': lookup['employee_name'],
          'next_action': lookup['next_action'],
          'public': true,
        };
        setState(() => _confirmed = confirmed);
        final position = await _service.currentLocation();
        final checked = await _service.validatePublicTerminalLocation(
          token: _token,
          employeeIdentifier: id,
          eventType: 'CLOCK_IN',
          geo: position,
        );
        setState(() {
          _locationCheck = checked;
          _geoStatus = 'ok';
        });
      } else {
        final lookup = await SupabaseService.client.rpc(
          'lookup_employee_by_identifier',
          params: {'p_identifier': id},
        );
        final found = lookup;
        if (found == null || (found is Map && found['employee'] == null)) {
          setState(
            () => _error = 'Employee ID not found. Please check and retry.',
          );
          return;
        }
        final employee = found is Map ? found['employee'] : found;
        setState(() => _confirmed = {'employee': employee, 'public': false});
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AttendanceService.normalizeError(e);
          _geoStatus = 'denied';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleClock(String eventType) async {
    if (_confirmed == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      if (publicMode) {
        final id = '${_confirmed!['employee_number']}';
        final position = await _service.currentLocation();
        final checked = await _service.validatePublicTerminalLocation(
          token: _token,
          employeeIdentifier: id,
          eventType: eventType,
          geo: position,
        );
        setState(() => _locationCheck = checked);
        final data = await _service.clockPublicTerminal(
          token: _token,
          employeeIdentifier: id,
          eventType: eventType,
          geo: position,
        );
        setState(() {
          _result =
              '${data['employee_name'] ?? _confirmed!['employee_name'] ?? 'Attendance recorded'}';
          _confirmed = null;
          _locationCheck = null;
          _idController.clear();
        });
      } else {
        final employee = _confirmed!['employee'] as Map? ?? const {};
        final deviceId = _selectedDeviceId;
        if (deviceId == null) {
          setState(() => _error = 'Select an attendance device first.');
          return;
        }
        final position = await _service.currentLocation();
        try {
          final res = await SupabaseService.client.rpc(
            'ingest_attendance_event',
            params: {
              'p_device_id': deviceId,
              'p_external_user_id': '${employee['employee_number'] ?? ''}',
              'p_event_type': eventType,
              'p_verification_method': 'DEVICE_AUTHENTICATION',
              'p_employee_id': employee['id'],
              'p_metadata': {
                'latitude': position.lat,
                'longitude': position.lng,
                'accuracy': position.accuracy,
                'captured_at': DateTime.now().millisecondsSinceEpoch,
                'location_source': 'mobile_geolocation',
              },
            },
          );
          final data = res is Map ? Map<String, dynamic>.from(res) : {};
          setState(() {
            _result =
                '${data['employee_name'] ?? data['message'] ?? 'Attendance recorded'}';
            _confirmed = null;
            _idController.clear();
          });
        } on PostgrestException catch (e) {
          setState(() => _error = e.message);
          return;
        }
      }
      if (mounted) _success();
    } catch (e) {
      if (mounted) setState(() => _error = AttendanceService.normalizeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _success() {
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _result != null) setState(() => _result = null);
    });
  }

  String get _nextAction => '${_confirmed?['next_action'] ?? ''}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E293B),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          publicMode ? 'QR Attendance Terminal' : 'Attendance Terminal',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: publicMode ? null : BackButton(color: Colors.white70),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(child: _clockBlock()),
            if (!publicMode && _devices.isNotEmpty) ...[
              const SizedBox(height: 16),
              _deviceSelector(),
            ],
            const SizedBox(height: 16),
            if (_result != null) _resultCard(),
            if (_error != null) _errorCard(),
            if (_confirmed != null && _result == null) _confirmCard(),
            if (_confirmed == null && _result == null) _inputCard(),
            const SizedBox(height: 16),
            Text(
              publicMode
                  ? 'Public QR terminal · location required · no InfinityCore '
                        'login or private employee data is required.'
                  : 'Authenticated terminal · employee identity resolved by '
                        'employee number · location captured.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }

  Widget _clockBlock() {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.green,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.fingerprint, color: Colors.white, size: 32),
        ),
        const SizedBox(height: 10),
        const Text(
          'InfinityCore',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _nowTime(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _deviceSelector() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Select terminal device',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
          const SizedBox(height: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedDeviceId,
              dropdownColor: const Color(0xFF334155),
              items: _devices
                  .map(
                    (d) => DropdownMenuItem(
                      value: '${d['id']}',
                      child: Text(
                        '${d['device_name'] ?? 'Device'}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() {
                _selectedDeviceId = v;
                _confirmed = null;
              }),
              hint: const Text(
                'Choose device',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.green,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          const Icon(Icons.check_circle, color: Colors.white, size: 44),
          const SizedBox(height: 8),
          Text(
            _greeting(),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          Text(
            _result!,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _errorCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.rose.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.rose.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cancel, color: AppColors.rose),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _confirmCard() {
    final c = _confirmed!;
    final name =
        '${c['employee_name'] ?? c['full_name'] ?? 'Employee number verified'}';
    final number = '${c['employee_number'] ?? '—'}';
    final complete = _nextAction == 'COMPLETE';
    final locationValid = _locationCheck?['valid'] == true;
    final locationName = '${_locationCheck?['actual_location_name'] ?? ''}';

    return LightPanel(
      padding: const EdgeInsets.all(18),
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Confirm your identity',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Colors.grey.shade500,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _confirmed = null;
                  _locationCheck = null;
                  _error = null;
                  _geoStatus = 'idle';
                }),
                child: const Text('Cancel'),
              ),
            ],
          ),
          Row(
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
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      number,
                      style: const TextStyle(
                        color: AppColors.green,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (publicMode) ...[
            const SizedBox(height: 12),
            LightPanel(
              padding: const EdgeInsets.all(12),
              color: const Color(0xFFF8FAFC),
              radius: 12,
              border: const Color(0xFFE2E8F0),
              child: Row(
                children: [
                  Icon(
                    _geoStatus == 'denied'
                        ? Icons.location_off
                        : locationValid
                        ? Icons.check_circle
                        : Icons.location_on,
                    size: 18,
                    color: _geoStatus == 'denied'
                        ? AppColors.rose
                        : locationValid
                        ? AppColors.green
                        : AppColors.textTertiary(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _geoStatus == 'denied'
                          ? 'Location is required to clock in or out.'
                          : _geoStatus == 'checking'
                          ? 'Checking location…'
                          : locationValid
                          ? 'Location verified — ${locationName.isNotEmpty ? locationName : 'approved attendance location'}'
                          : 'Location not yet verified.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            if (locationValid) ...[
              const SizedBox(height: 8),
              Text(
                _distanceNote(),
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary(context)),
              ),
            ],
          ],
          const SizedBox(height: 14),
          if (complete)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Text(
                  'Attendance complete for today',
                  style: TextStyle(
                    color: AppColors.greenDark,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (publicMode && !locationValid)
                        ? null
                        : _busy
                        ? null
                        : () => _handleClock('CLOCK_IN'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.green,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    icon: const Icon(Icons.login),
                    label: const Text('Clock In'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (publicMode && !locationValid)
                        ? null
                        : _busy
                        ? null
                        : () => _handleClock('CLOCK_OUT'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.rose,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    icon: const Icon(Icons.logout),
                    label: const Text('Clock Out'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _distanceNote() {
    final check = _locationCheck;
    final assigned = '${check?['assigned_branch_name'] ?? ''}';
    final location = '${check?['actual_location_name'] ?? ''}';
    final distance = check?['distance'];
    final differs = check?['location_difference'] == true;
    if (differs) {
      return 'Clocking from $location. Assigned branch: ${assigned.isEmpty ? 'different branch' : assigned}.'
          '${distance != null ? ' Distance: ${(distance as num).round()}m.' : ''}';
    }
    return 'Clock-in location matches your assigned branch.'
        '${distance != null ? ' Distance: ${(distance as num).round()}m.' : ''}';
  }

  Widget _inputCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            publicMode
                ? 'Enter your Employee Number or Email'
                : 'Enter your Employee ID or PIN',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _idController,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              hintText: 'Enter ID…',
              hintStyle: const TextStyle(color: Colors.white30),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.08),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: 0.2),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.green),
              ),
            ),
            onSubmitted: (_) => _busy ? null : _verifyEmployee(),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy || _idController.text.trim().isEmpty
                ? null
                : _verifyEmployee,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            icon: const Icon(Icons.shield_outlined),
            label: Text(_busy ? 'Verifying…' : 'Verify ID'),
          ),
        ],
      ),
    );
  }
}
