import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/config/env.dart';
import '../../core/security/location_integrity.dart';
import '../../core/services/device_identity.dart';
import '../../core/services/supabase_service.dart';
import '../../shared/models/models.dart';
import 'qr_terminal.dart';

class PositionFix {
  final double lat;
  final double lng;
  final double accuracy;

  const PositionFix({
    required this.lat,
    required this.lng,
    required this.accuracy,
  });

  factory PositionFix.from(Position p) =>
      PositionFix(lat: p.latitude, lng: p.longitude, accuracy: p.accuracy);
}

/// Attendance engine client. Mirrors `attendanceService` +
/// `attendanceEngineService` from the web platform. All writes go through the
/// same server-authoritative RPCs; the server remains the source of truth for
/// identity, geofence and time validation.
class AttendanceService {
  AttendanceService._();
  static final AttendanceService instance = AttendanceService._();

  Future<void> ensureLocationPermission() async {
    var service = await Geolocator.isLocationServiceEnabled();
    if (!service) {
      throw StateError(
        'Location services are turned off. Enable location to clock in or out.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw StateError('Location permission is required for attendance.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw StateError(
        'Location permission is permanently denied. Enable it in Settings.',
      );
    }
  }

  Future<PositionFix> currentLocation() async {
    await ensureLocationPermission();
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return PositionFix.from(position);
  }

  Future<EmployeeRef?> getMyEmployee() async {
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return null;
    try {
      final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
        'mobile_get_my_employee',
      );
      if (data.isEmpty) return null;
      return EmployeeRef.fromJson(data);
    } on Exception catch (err) {
      if (!SupabaseService.rpcMissing(err)) rethrow;
    }
    // Migration not applied yet — fall back to the direct query (works for
    // HR roles under current RLS; employees get a friendly empty state).
    try {
      final data = await SupabaseService.client
          .from('employees')
          .select(
            '*, branches!branch_id(id, branch_name, latitude, longitude, geofence_radius, geofence_active)',
          )
          .eq('user_id', user.id)
          .limit(1)
          .maybeSingle();
      if (data == null) return null;
      return EmployeeRef.fromJson(data, withBranch: true);
    } on Exception {
      return null;
    }
  }

  /// Supervisor chain for the signed-in employee (from the HR org table,
  /// `employee_supervisors`). HR roles may pass a target employee id.
  Future<List<SupervisorRef>> getMySupervisor({String? employeeId}) async {
    try {
      final data = await SupabaseService.client.rpc<List<dynamic>>(
        'mobile_get_my_supervisor',
        params: {'p_employee_id': ?employeeId},
      );
      return data.map(SupervisorRef.fromJson).toList();
    } on Exception catch (e) {
      if (!SupabaseService.rpcMissing(e)) rethrow;
    }
    return const [];
  }

  Future<ReminderSettings> getReminderSettings() async {
    try {
      final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
        'mobile_reminder_settings_get',
      );
      return ReminderSettings.fromJson(data);
    } on Exception catch (e) {
      if (!SupabaseService.rpcMissing(e)) rethrow;
    }
    return const ReminderSettings();
  }

  /// HR-configurable clock-in / clock-out reminder schedule. Server enforces
  /// the role gate (super_admin, admin, head_of_human_resources,
  /// branch_manager) and HH:MM format.
  Future<ReminderSettings> setReminderSettings({
    required String clockInTime,
    required String clockOutTime,
    required int graceMinutes,
    required bool enabled,
  }) async {
    final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'mobile_reminder_settings_set',
      params: {
        'p_clock_in_time': clockInTime,
        'p_clock_out_time': clockOutTime,
        'p_grace_minutes': graceMinutes,
        'p_enabled': enabled,
      },
    );
    return ReminderSettings.fromJson(data);
  }

  Future<AttendanceRequirements> getAttendanceRequirements() async {
    final data = await SupabaseService.client.rpc(
      'get_attendance_requirements',
      params: const {},
    );
    return AttendanceRequirements.fromJson(data);
  }

  Future<String> _todayKey(String timezone) async {
    // Date in the configured app timezone, matching the web platform's
    // timeZoneDateKey so `attendance_date` filters align.
    try {
      tzdata.initializeTimeZones();
      final tzLoc = tz.getLocation(timezone);
      final now = tz.TZDateTime.now(tzLoc);
      return now.toIso8601String().substring(0, 10);
    } catch (_) {
      return DateTime.now().toIso8601String().substring(0, 10);
    }
  }

  Future<AttendanceRecord?> getToday(String employeeId) async {
    final req = await getAttendanceRequirements();
    final today = await _todayKey(req.appTimezone);
    final data = await SupabaseService.client
        .from('attendance_records')
        .select()
        .eq('employee_id', employeeId)
        .eq('attendance_date', today)
        .limit(1)
        .maybeSingle();
    if (data == null) return null;
    await _attachLocationEvents([data]);
    return AttendanceRecord.fromJson(data);
  }

  Future<List<AttendanceRecord>> getHistory(
    String employeeId, {
    int limit = 90,
  }) async {
    final res = await SupabaseService.client
        .from('attendance_records')
        .select()
        .eq('employee_id', employeeId)
        .order('attendance_date', ascending: false)
        .limit(limit);
    final rows = (res as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    await _attachLocationEvents(rows);
    return rows.map(AttendanceRecord.fromJson).toList();
  }

  /// Merge the actual captured location from the server-side CLOCK_IN event
  /// metadata onto each record row (mirrors web `attachLocationEvents`).
  Future<void> _attachLocationEvents(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    try {
      final ids = rows.map((r) => r['id']?.toString() ?? '').toList();
      final events = await SupabaseService.client
          .from('attendance_events')
          .select(
            'attendance_record_id, event_type, metadata, geofence_status, location_status',
          )
          .inFilter('attendance_record_id', ids)
          .eq('event_type', 'CLOCK_IN')
          .order('event_time', ascending: false);
      final byId = <String, Map<String, dynamic>>{};
      for (final e in (events as List<dynamic>? ?? [])) {
        final m = e as Map<String, dynamic>;
        final rid = m['attendance_record_id']?.toString() ?? '';
        if (rid.isNotEmpty && !byId.containsKey(rid)) byId[rid] = m;
      }
      for (final row in rows) {
        final rid = row['id']?.toString() ?? '';
        final ev = byId[rid];
        if (ev == null) continue;
        final meta = ev['metadata'];
        final metaMap = meta is Map<String, dynamic>
            ? meta
            : <String, dynamic>{};
        if ((row['actual_location_name'] ?? '').toString().isEmpty) {
          row['actual_location_name'] = metaMap['actual_location_name'] ?? '';
        }
        if ((row['geofence_status'] ?? '').toString().isEmpty &&
            (ev['geofence_status'] ?? '').toString().isNotEmpty) {
          row['geofence_status'] = ev['geofence_status'];
        }
        if ((row['location_status'] ?? '').toString().isEmpty &&
            (ev['location_status'] ?? '').toString().isNotEmpty) {
          row['location_status'] = ev['location_status'];
        }
      }
    } catch (_) {
      // Events are best-effort enrichment; missing events leave the row as-is.
    }
  }

  Future<List<BranchGeofence>> listGeofences() async {
    final res = await SupabaseService.client
        .from('attendance_geofences')
        .select()
        .order('created_at', ascending: false);
    final attendance = (res as List<dynamic>? ?? [])
        .map(BranchGeofence.fromJson)
        .toList();

    List<BranchGeofence> branch = [];
    try {
      final b = await SupabaseService.client
          .from('branches')
          .select(
            'id, branch_name, branch_code, latitude, longitude, geofence_radius, geofence_active, location, branch_name_as_location',
          );
      branch = (b as List<dynamic>? ?? [])
          .map(
            (v) => BranchGeofence.fromJson({
              ...(v as Map),
              'name': v['branch_name'],
              'id': 'branch-${v['id']}',
              'source': 'branch',
              'active': v['geofence_active'] != false,
              'radius_meters': v['geofence_radius'] ?? 150,
            }),
          )
          .where((g) => g.latitude != null && g.longitude != null)
          .toList();
    } catch (_) {}

    return [...attendance, ...branch];
  }

  Future<List<BranchGeofence>> listBranches() async {
    return listGeofences();
  }

  Future<Map<String, dynamic>> clockIn(
    PositionFix? geo, {
    double? lat,
    double? lng,
    double? accuracy,
    bool biometricUsed = false,
    String? terminalId,
  }) async {
    final coords =
        geo ??
        (lat != null && lng != null
            ? PositionFix(lat: lat, lng: lng, accuracy: accuracy ?? 0)
            : await currentLocation());

    final problem = await LocationIntegrity.instance.preflightCheck(
      requireGps: true,
    );
    if (problem != null) throw StateError(problem);

    final identity = await DeviceIdentity.instance.describe();
    final fingerprint = await DeviceIdentity.instance.fingerprint();
    try {
      final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
        'mobile_clock_in',
        params: {
          'p_lat': coords.lat,
          'p_lng': coords.lng,
          'p_accuracy': coords.accuracy,
          'p_device_fingerprint': fingerprint,
          'p_device_id': identity['deviceId'],
          'p_app_version': identity['appVersion'],
          'p_app_build': identity['appBuild'],
          'p_biometric_used': biometricUsed,
          if (terminalId != null && terminalId.isNotEmpty) ...{
            'p_terminal_id': terminalId,
            'p_entry_point': 'mobile_qr_terminal',
          },
        },
      );
      await logAction(
        action: 'ATTENDANCE_CLOCK_IN',
        entityType: 'AttendanceRecord',
        entityId: '${data['attendance_id'] ?? ''}',
        details: terminalId != null
            ? 'Clock in via mobile app (channel=qr_terminal)'
            : 'Clock in via mobile app (channel=mobile)',
      );
      return _mapData(data);
    } on Exception catch (e) {
      if (SupabaseService.rpcMissing(e)) {
        // Migration not applied — fall back to the web-role path the platform
        // already ships (still server-validated + device-day bound).
        try {
          final data = await SupabaseService.client.rpc(
            'clock_in_secure',
            params: {
              'p_lat': coords.lat,
              'p_lng': coords.lng,
              'p_accuracy': coords.accuracy,
              'p_device_fingerprint': fingerprint,
            },
          );
          await logAction(
            action: 'ATTENDANCE_CLOCK_IN',
            entityType: 'AttendanceRecord',
            entityId: '${data?['attendance_id'] ?? ''}',
            details: 'Clock in via mobile app (fallback channel=web)',
          );
          return _mapData(data);
        } on Exception catch (e2) {
          throw stateError(e2);
        }
      }
      throw stateError(e);
    }
  }

  Future<Map<String, dynamic>> clockOut(
    String attendanceId, {
    PositionFix? geo,
    bool biometricUsed = false,
    String? terminalId,
  }) async {
    final coords = geo ?? await currentLocation();

    final problem = await LocationIntegrity.instance.preflightCheck(
      requireGps: true,
    );
    if (problem != null) throw StateError(problem);

    final identity = await DeviceIdentity.instance.describe();
    final fingerprint = await DeviceIdentity.instance.fingerprint();
    try {
      final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
        'mobile_clock_out',
        params: {
          'p_attendance_id': attendanceId,
          'p_lat': coords.lat,
          'p_lng': coords.lng,
          'p_accuracy': coords.accuracy,
          'p_device_fingerprint': fingerprint,
          'p_device_id': identity['deviceId'],
          'p_app_version': identity['appVersion'],
          'p_app_build': identity['appBuild'],
          'p_biometric_used': biometricUsed,
          if (terminalId != null && terminalId.isNotEmpty) ...{
            'p_terminal_id': terminalId,
            'p_entry_point': 'mobile_qr_terminal',
          },
        },
      );
      await logAction(
        action: 'ATTENDANCE_CLOCK_OUT',
        entityType: 'AttendanceRecord',
        entityId: attendanceId,
        details: terminalId != null
            ? 'Clock out via mobile app (channel=qr_terminal)'
            : 'Clock out via mobile app (channel=mobile)',
      );
      return _mapData(data);
    } on Exception catch (e) {
      if (SupabaseService.rpcMissing(e)) {
        try {
          final data = await SupabaseService.client.rpc(
            'clock_out_secure',
            params: {
              'p_attendance_id': attendanceId,
              'p_lat': coords.lat,
              'p_lng': coords.lng,
              'p_accuracy': coords.accuracy,
              'p_device_fingerprint': fingerprint,
            },
          );
          await logAction(
            action: 'ATTENDANCE_CLOCK_OUT',
            entityType: 'AttendanceRecord',
            entityId: attendanceId,
            details: 'Clock out via mobile app (fallback channel=web)',
          );
          return _mapData(data);
        } on Exception catch (e2) {
          throw stateError(e2);
        }
      }
      throw stateError(e);
    }
  }

  /// HR/attendance-management feed (server-authoritative via
  /// `mobile_attendance_summary`). Roles are enforced server-side.
  Future<List<AttendanceManagementRow>> managementSummary({
    DateTime? from,
    DateTime? to,
    String? branchId,
    String? status,
  }) async {
    final data = await SupabaseService.client.rpc<List<dynamic>>(
      'mobile_attendance_summary',
      params: {
        'p_from': from?.toIso8601String().substring(0, 10),
        'p_to': to?.toIso8601String().substring(0, 10),
        'p_branch_id': branchId,
        'p_status': status,
      },
    );
    return data.map(AttendanceManagementRow.fromJson).toList();
  }

  Future<Map<String, dynamic>> reconcileAutoClockouts() async {
    try {
      final data = await SupabaseService.client.rpc(
        'attendance_auto_clockout_close_sessions',
        params: const {},
      );
      return _mapData(data);
    } on Exception catch (e) {
      throw stateError(e);
    }
  }

  // ---- Public QR terminal (intentionally requires no login) ----
  Future<Map<String, dynamic>> validatePublicTerminalEmployee(
    String token,
    String employeeIdentifier,
  ) async {
    try {
      final data = await SupabaseService.client.rpc(
        'validate_attendance_terminal_employee',
        params: {'p_token': token, 'p_employee_identifier': employeeIdentifier},
      );
      return _mapData(data);
    } on Exception catch (e) {
      throw stateError(e);
    }
  }

  Future<Map<String, dynamic>> validatePublicTerminalLocation({
    required String token,
    required String employeeIdentifier,
    required String eventType,
    required PositionFix geo,
  }) async {
    try {
      final data = await SupabaseService.client.rpc(
        'validate_attendance_terminal_location',
        params: {
          'p_token': token,
          'p_employee_identifier': employeeIdentifier,
          'p_lat': geo.lat,
          'p_lng': geo.lng,
          'p_event_type': eventType,
        },
      );
      final parsed = _mapData(data);
      if (parsed['valid'] == false) {
        throw StateError(
          '${parsed['error'] ?? 'Location not valid for attendance'}',
        );
      }
      return parsed;
    } on PostgrestException catch (e) {
      throw stateError(e);
    }
  }

  Future<Map<String, dynamic>> clockPublicTerminal({
    required String token,
    required String employeeIdentifier,
    required String eventType,
    required PositionFix geo,
  }) async {
    try {
      final data = await SupabaseService.client.rpc(
        'clock_attendance_terminal',
        params: {
          'p_token': token,
          'p_employee_identifier': employeeIdentifier,
          'p_event_type': eventType,
          'p_lat': geo.lat,
          'p_lng': geo.lng,
          'p_accuracy': geo.accuracy,
        },
      );
      final parsed = _mapData(data);
      if (parsed['success'] == false) {
        throw StateError('${parsed['error'] ?? 'Clock operation failed'}');
      }
      return parsed;
    } on PostgrestException catch (e) {
      throw stateError(e);
    }
  }

  Future<Map<String, dynamic>> generateTerminalToken({String? deviceId}) async {
    try {
      final data = await SupabaseService.client.rpc(
        'create_attendance_terminal_token',
        params: {
          'p_device_id': deviceId,
          'p_device_name': 'QR Attendance Terminal',
        },
      );
      return _mapData(data);
    } on Exception catch (e) {
      throw stateError(e);
    }
  }

  String terminalUrl(String token) =>
      '${Env.terminalBaseUrl}/#/attendance-terminal?token=$token';

  /// Server-side validation of a scanned terminal token. The server is the
  /// authority: it verifies the token is live/active and returns terminal
  /// identity + readiness before any clock write is attempted.
  Future<TerminalInfo> inspectTerminal(String token) async {
    try {
      final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
        'mobile_qr_terminal_inspect',
        params: {'p_token': token},
      );
      return TerminalInfo.fromJson(data);
    } on Exception catch (e) {
      throw stateError(e);
    }
  }

  static Map<String, dynamic> _mapData(dynamic v) {
    if (v == null) return const {};
    return v is Map<String, dynamic> ? v : Map<String, dynamic>.from(v as Map);
  }

  static String normalizeError(Object error) {
    final message = error.toString();
    if (message.contains('PGRST202') ||
        message.contains('could not find the function')) {
      return 'This feature is not available yet on the server.';
    }
    const prefixes = [
      'MOBILE_SESSION:',
      'BIOMETRIC_REQUIRED:',
      'MOBILE_UNAUTHORIZED_DEVICE:',
      'OUT_OF_BOUNDS:',
      'OUTSIDE_GEOFENCE:',
      'GEOFENCE_NOT_CONFIGURED:',
      'LOCATION_REQUIRED:',
      'LOCATION_INVALID:',
      'DEVICE_BINDING:',
      'TERMINAL_INACTIVE:',
      'TERMINAL_NOT_FOUND:',
    ];
    for (final p in prefixes) {
      if (message.contains(p)) return message.split(p).last.trim();
    }
    if (message.contains('outside the geofence') ||
        message.contains('geofence')) {
      return 'You are outside the approved attendance location.';
    }
    if (message.contains('already clocked')) {
      return 'You are already clocked in.';
    }
    if (message.contains('no clock')) {
      return 'There is no open attendance session to clock out.';
    }
    return message
        .replaceAll('Exception: ', '')
        .replaceAll('PostgrestException: ', '');
  }

  static StateError stateError(Object? error) {
    final raw = error is PostgrestException ? error.message : '$error';
    return StateError(normalizeError(raw));
  }
}
