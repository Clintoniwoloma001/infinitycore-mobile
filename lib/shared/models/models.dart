/// Shared, backend-aligned models.
///
/// Field names mirror the Supabase columns used by the InfinityCore web
/// platform so no business logic is re-derived on the client.
library;

Map<String, dynamic> _map(dynamic v) =>
    v is Map<String, dynamic> ? v : <String, dynamic>{};

String _s(dynamic v, [String fallback = '']) {
  final x = v;
  if (x == null) return fallback;
  final s = x.toString().trim();
  return s.isEmpty ? fallback : s;
}

double? _d(dynamic v) {
  final x = double.tryParse(v?.toString() ?? '');
  return x;
}

bool _b(dynamic v, [bool fallback = false]) {
  if (v == null) return fallback;
  if (v is bool) return v;
  return v == true || v == 1 || v == 'true' || v == '1';
}

class Profile {
  final String id;
  final String email;
  final String fullName;
  final String role;
  final String status;
  final String department;
  final String branch;
  final String userType;

  const Profile({
    required this.id,
    this.email = '',
    this.fullName = '',
    this.role = 'staff',
    this.status = 'active',
    this.department = '',
    this.branch = '',
    this.userType = '',
  });

  factory Profile.fromJson(dynamic v) {
    final m = _map(v);
    return Profile(
      id: _s(m['id']),
      email: _s(m['email']),
      fullName: _s(m['full_name']),
      role: _s(m['role'], 'staff'),
      status: _s(m['status'], 'active'),
      department: _s(m['department']),
      branch: _s(m['branch']),
      userType: _s(m['user_type']),
    );
  }

  bool get active => status == 'active';
}

class EmployeeRef {
  final String id;
  final String fullName;
  final String email;
  final String phone;
  final String department;
  final String position;
  final String branch;
  final String branchName;
  final String area;
  final String employmentStatus;
  final String employeeNumber;
  final String staffId;
  final String employeeCode;
  final String confirmationStatus;
  final String managerId;
  final String managerName;
  final String joinedDate;
  final int? joinedYear;

  const EmployeeRef({
    required this.id,
    this.fullName = '',
    this.email = '',
    this.phone = '',
    this.department = '',
    this.position = '',
    this.branch = '',
    this.branchName = '',
    this.area = '',
    this.employmentStatus = 'active',
    this.employeeNumber = '',
    this.staffId = '',
    this.employeeCode = '',
    this.confirmationStatus = '',
    this.managerId = '',
    this.managerName = '',
    this.joinedDate = '',
    this.joinedYear,
  });

  factory EmployeeRef.fromJson(dynamic v, {bool withBranch = false}) {
    final m = _map(v);
    // The backend may return the branch as a nested object under either
    // `branches` (direct-query fallback) or `branch` (the JSONB branch map
    // emitted by `mobile_get_my_employee`). A nested object must never be
    // stringified into the UI, so it is resolved to `branchName` instead.
    final branchMap = (withBranch && m['branches'] is Map)
        ? _map(m['branches'])
        : m['branch'] is Map
        ? _map(m['branch'])
        : null;
    final branchValue = m['branch'];
    final joined = _s(m['joined_date'], _s(m['hire_date']));
    return EmployeeRef(
      id: _s(m['id']),
      fullName: _s(m['full_name']),
      email: _s(m['email']),
      phone: _s(m['phone']),
      department: _s(m['department']),
      position: _s(m['position']),
      branch: branchValue is Map ? '' : _s(branchValue),
      branchName: _s(branchMap?['branch_name'], _s(m['assigned_branch_name'])),
      area: _s(m['area']),
      employmentStatus: _s(m['employment_status'], 'active'),
      employeeNumber: _s(m['employee_number']),
      staffId: _s(m['staff_id']),
      employeeCode: _s(m['employee_code']),
      confirmationStatus: _s(m['confirmation_status']),
      managerId: _s(m['manager_id']),
      managerName: _s(m['manager_name']),
      joinedDate: joined,
      joinedYear: int.tryParse(
        joined.length >= 4 ? joined.substring(0, 4) : '',
      ),
    );
  }

  String get displayId {
    if (employeeNumber.isNotEmpty) return employeeNumber;
    if (staffId.isNotEmpty) return staffId;
    if (employeeCode.isNotEmpty) return employeeCode;
    return '—';
  }

  bool get isActive => employmentStatus == 'active';
}

class SupervisorRef {
  final String supervisorEmployeeId;
  final String supervisorName;
  final String supervisorPosition;
  final String supervisorDepartment;
  final String supervisorTitle;
  final int level;

  const SupervisorRef({
    this.supervisorEmployeeId = '',
    this.supervisorName = '',
    this.supervisorPosition = '',
    this.supervisorDepartment = '',
    this.supervisorTitle = '',
    this.level = 1,
  });

  factory SupervisorRef.fromJson(dynamic v) {
    final m = _map(v);
    return SupervisorRef(
      supervisorEmployeeId: _s(m['supervisor_employee_id']),
      supervisorName: _s(m['supervisor_name']),
      supervisorPosition: _s(m['supervisor_position']),
      supervisorDepartment: _s(m['supervisor_department']),
      supervisorTitle: _s(m['supervisor_title']),
      level: (m['level'] is num) ? (m['level'] as num).toInt() : 1,
    );
  }
}

class ReminderSettings {
  final String clockInTime;
  final String clockOutTime;
  final int graceMinutes;
  final bool enabled;

  const ReminderSettings({
    this.clockInTime = '08:00',
    this.clockOutTime = '18:00',
    this.graceMinutes = 30,
    this.enabled = true,
  });

  factory ReminderSettings.fromJson(dynamic v) {
    final m = _map(v);
    return ReminderSettings(
      clockInTime: _s(m['clock_in_time'], '08:00'),
      clockOutTime: _s(m['clock_out_time'], '18:00'),
      graceMinutes: int.tryParse(_s(m['grace_minutes'])) ?? 30,
      enabled: m['enabled'] != false,
    );
  }
}

class BranchGeofence {
  final String id;
  final String name;
  final String locationName;
  final double? latitude;
  final double? longitude;
  final double radiusMeters;
  final bool active;
  final bool clockInAllowed;
  final bool clockOutAllowed;
  final String source;

  const BranchGeofence({
    required this.id,
    this.name = '',
    this.locationName = '',
    this.latitude,
    this.longitude,
    this.radiusMeters = 150,
    this.active = true,
    this.clockInAllowed = true,
    this.clockOutAllowed = true,
    this.source = 'branch',
  });

  factory BranchGeofence.fromJson(dynamic v) {
    final m = _map(v);
    return BranchGeofence(
      id: _s(m['id']),
      name: _s(m['name'], _s(m['branch_name'])),
      locationName: _s(
        m['location_name'],
        _s(m['location'], _s(m['branch_name'])),
      ),
      latitude: _d(m['latitude']),
      longitude: _d(m['longitude']),
      radiusMeters: _d(m['radius_meters']) ?? _d(m['geofence_radius']) ?? 150,
      active: _b(m['active'], _b(m['geofence_active'], true)),
      clockInAllowed: _b(m['clock_in_allowed'], true),
      clockOutAllowed: _b(m['clock_out_allowed'], true),
      source: _s(m['source'], 'attendance'),
    );
  }
}

class AttendanceRequirements {
  final bool requireGpsClockIn;
  final bool requireGpsClockOut;
  final bool geofenceEnabled;
  final double defaultGeofenceRadius;
  final int lateThresholdMinutes;
  final int earlyDepartureThresholdMinutes;
  final String defaultWorkStartTime;
  final String defaultWorkEndTime;
  final int defaultGracePeriodMinutes;
  final List<String> defaultWorkingDays;
  final String appTimezone;

  const AttendanceRequirements({
    this.requireGpsClockIn = true,
    this.requireGpsClockOut = true,
    this.geofenceEnabled = false,
    this.defaultGeofenceRadius = 150,
    this.lateThresholdMinutes = 15,
    this.earlyDepartureThresholdMinutes = 30,
    this.defaultWorkStartTime = '',
    this.defaultWorkEndTime = '',
    this.defaultGracePeriodMinutes = 0,
    this.defaultWorkingDays = const [],
    this.appTimezone = 'Africa/Lagos',
  });

  factory AttendanceRequirements.fromJson(dynamic v) {
    final m = _map(v);
    final days = m['default_working_days'];
    return AttendanceRequirements(
      requireGpsClockIn: _b(m['require_gps_clock_in'], true),
      requireGpsClockOut: _b(m['require_gps_clock_out'], true),
      geofenceEnabled: _b(m['geofence_enabled'], false),
      defaultGeofenceRadius: _d(m['default_geofence_radius']) ?? 150,
      lateThresholdMinutes: int.tryParse(_s(m['late_threshold_minutes'])) ?? 15,
      earlyDepartureThresholdMinutes:
          int.tryParse(_s(m['early_departure_threshold_minutes'])) ?? 30,
      defaultWorkStartTime: _s(m['default_work_start_time']),
      defaultWorkEndTime: _s(m['default_work_end_time']),
      defaultGracePeriodMinutes:
          int.tryParse(_s(m['default_grace_period_minutes'])) ?? 0,
      defaultWorkingDays: days is List
          ? days.map((d) => d.toString().trim()).toList()
          : const [],
      appTimezone: _s(m['app_timezone'], 'Africa/Lagos'),
    );
  }
}

class AttendanceRecord {
  final String id;
  final String employeeId;
  final String attendanceDate;
  final String? clockIn;
  final String? clockOut;
  final String status;
  final int lateMinutes;
  final int earlyDepartureMinutes;
  final int overtimeMinutes;
  final double workHours;
  final String branchId;
  final String actualLocationName;
  final String assignedBranchName;
  final String source;
  final String geofenceStatus;
  final String locationStatus;
  final String verificationMethod;
  final double? clockInLat;
  final double? clockInLng;
  final double? clockInAccuracy;
  final double? clockInDistance;
  final Map<String, dynamic> raw;

  const AttendanceRecord({
    required this.id,
    this.employeeId = '',
    this.attendanceDate = '',
    this.clockIn,
    this.clockOut,
    this.status = '',
    this.lateMinutes = 0,
    this.earlyDepartureMinutes = 0,
    this.overtimeMinutes = 0,
    this.workHours = 0,
    this.branchId = '',
    this.actualLocationName = '',
    this.assignedBranchName = '',
    this.source = '',
    this.geofenceStatus = '',
    this.locationStatus = '',
    this.verificationMethod = '',
    this.clockInLat,
    this.clockInLng,
    this.clockInAccuracy,
    this.clockInDistance,
    this.raw = const {},
  });

  factory AttendanceRecord.fromJson(dynamic v) {
    final m = _map(v);
    return AttendanceRecord(
      id: _s(m['id']),
      employeeId: _s(m['employee_id']),
      attendanceDate: _s(m['attendance_date']),
      clockIn: m['clock_in']?.toString(),
      clockOut: m['clock_out']?.toString(),
      status: _s(m['status']),
      lateMinutes: int.tryParse(_s(m['late_minutes'])) ?? 0,
      earlyDepartureMinutes:
          int.tryParse(_s(m['early_departure_minutes'])) ?? 0,
      overtimeMinutes: int.tryParse(_s(m['overtime_minutes'])) ?? 0,
      workHours: _d(m['work_hours']) ?? 0,
      branchId: _s(m['branch_id']),
      actualLocationName: _s(m['actual_location_name']),
      assignedBranchName: _s(m['assigned_branch_name']),
      source: _s(m['source']),
      geofenceStatus: _s(m['geofence_status']),
      locationStatus: _s(m['location_status']),
      verificationMethod: _s(m['verification_method']),
      clockInLat: _d(m['clock_in_lat']),
      clockInLng: _d(m['clock_in_lng']),
      clockInAccuracy: _d(m['clock_in_accuracy']),
      clockInDistance: _d(m['clock_in_distance']),
      raw: m,
    );
  }

  bool get isClockedIn => clockIn != null && clockOut == null;
  bool get isInsideGeofence => geofenceStatus == 'inside';
}

/// Row returned by `mobile_attendance_summary` (HR/attendance management).
class AttendanceManagementRow {
  final String attendanceId;
  final String employeeId;
  final String employeeName;
  final String employeeNumber;
  final String department;
  final String branchId;
  final String branchName;
  final String attendanceDate;
  final String? clockIn;
  final String? clockOut;
  final String status;
  final double workHours;
  final int totalMinutes;
  final String lateStatus;
  final int lateMinutes;
  final String locationStatus;
  final String geofenceStatus;
  final double? clockInLat;
  final double? clockInLng;
  final double? clockInAccuracy;
  final String actualLocationName;

  const AttendanceManagementRow({
    required this.attendanceId,
    this.employeeId = '',
    this.employeeName = '',
    this.employeeNumber = '',
    this.department = '',
    this.branchId = '',
    this.branchName = '',
    this.attendanceDate = '',
    this.clockIn,
    this.clockOut,
    this.status = '',
    this.workHours = 0,
    this.totalMinutes = 0,
    this.lateStatus = '',
    this.lateMinutes = 0,
    this.locationStatus = '',
    this.geofenceStatus = '',
    this.clockInLat,
    this.clockInLng,
    this.clockInAccuracy,
    this.actualLocationName = '',
  });

  factory AttendanceManagementRow.fromJson(dynamic v) {
    final m = _map(v);
    return AttendanceManagementRow(
      attendanceId: _s(m['attendance_id']),
      employeeId: _s(m['employee_id']),
      employeeName: _s(m['employee_name']),
      employeeNumber: _s(m['employee_number']),
      department: _s(m['department']),
      branchId: _s(m['branch_id']),
      branchName: _s(m['branch_name']),
      attendanceDate: _s(m['attendance_date']),
      clockIn: m['clock_in']?.toString(),
      clockOut: m['clock_out']?.toString(),
      status: _s(m['status']),
      workHours: _d(m['work_hours']) ?? 0,
      totalMinutes: int.tryParse(_s(m['total_minutes'])) ?? 0,
      lateStatus: _lateStatus(m['late_status']),
      lateMinutes: int.tryParse(_s(m['late_minutes'])) ?? 0,
      locationStatus: _s(m['location_status']),
      geofenceStatus: _s(m['geofence_status']),
      clockInLat: _d(m['clock_in_lat']),
      clockInLng: _d(m['clock_in_lng']),
      clockInAccuracy: _d(m['clock_in_accuracy']),
      actualLocationName: _s(m['actual_location_name']),
    );
  }

  bool get isCurrentlyOpen => clockIn != null && clockOut == null;
}

/// Normalizes the `late_status` summary column. The server contract is the
/// text values `'late'` / `'on_time'`, but older rows may surface the raw
/// boolean flag (`true`/`false`) instead — accept both.
String _lateStatus(dynamic v) {
  if (v == null) return '';
  if (v is bool) return v ? 'late' : 'on_time';
  final s = v.toString().trim().toLowerCase();
  if (s == 'true' || s == '1') return 'late';
  if (s == 'false' || s == '0') return 'on_time';
  return s;
}

class AppNotification {
  final String id;
  final String title;
  final String message;
  final String link;
  final bool read;
  final String type;
  final String createdAt;

  const AppNotification({
    required this.id,
    this.title = '',
    this.message = '',
    this.link = '',
    this.read = false,
    this.type = 'system',
    this.createdAt = '',
  });

  factory AppNotification.fromJson(dynamic v) {
    final m = _map(v);
    return AppNotification(
      id: _s(m['id']),
      title: _s(m['title']),
      message: _s(m['message']),
      link: _s(m['link']),
      read: _b(m['read']),
      type: _s(m['type'], 'system'),
      createdAt: _s(m['created_at']),
    );
  }
}

class ChatThread {
  final String id;
  final String memberA;
  final String memberB;
  final String otherName;
  final String lastMessage;
  final String lastMessageAt;
  final Map<String, dynamic> raw;

  const ChatThread({
    required this.id,
    this.memberA = '',
    this.memberB = '',
    this.otherName = '',
    this.lastMessage = '',
    this.lastMessageAt = '',
    this.raw = const {},
  });

  factory ChatThread.fromJson(dynamic v) {
    final m = _map(v);
    return ChatThread(
      id: _s(m['id']),
      memberA: _s(m['member_a']),
      memberB: _s(m['member_b']),
      otherName: _s(m['other_name']),
      lastMessage: _s(m['last_message']),
      lastMessageAt: _s(m['last_message_at']),
      raw: m,
    );
  }
}

class ChatMessage {
  final String id;
  final String threadId;
  final String senderId;
  final String body;
  final String fileUrl;
  final String fileType;
  final String createdAt;

  /// The full backend row, so newer server columns (priority, is_official,
  /// is_pinned, parent_message_id, …) are available without the client having
  /// to re-declare the schema. Unknown columns are simply not modelled.
  final Map<String, dynamic> raw;

  const ChatMessage({
    required this.id,
    this.threadId = '',
    this.senderId = '',
    this.body = '',
    this.fileUrl = '',
    this.fileType = '',
    this.createdAt = '',
    this.raw = const {},
  });

  factory ChatMessage.fromJson(dynamic v) {
    final m = _map(v);
    return ChatMessage(
      id: _s(m['id']),
      threadId: _s(m['thread_id']),
      senderId: _s(m['sender_id']),
      body: _s(m['body']),
      fileUrl: _s(m['file_url'], _s(m['attachment_url'])),
      fileType: _s(m['file_type'], _s(m['attachment_type'])),
      createdAt: _s(m['created_at']),
      raw: m,
    );
  }
}
