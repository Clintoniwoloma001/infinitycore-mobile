import '../../core/services/auth_service.dart';
import '../../core/services/device_identity.dart';
import '../../core/services/employee_photo.dart';
import '../../core/services/mobile_session_service.dart';
import '../../shared/models/models.dart';
import '../attendance/attendance_service.dart';

/// Client-friendly, employee-first dashboard snapshot. The backend remains
/// authoritative for identity/attendance; this only assembles what the Home
/// tab needs: who you are, today's attendance state and a short history.
class DashboardSnapshot {
  final EmployeeRef? employee;
  final AttendanceRecord? today;
  final List<AttendanceRecord> recentAttendance;
  final Map<String, String> device;
  final bool? mobileSessionEnforced;
  final String? mobileSessionId;
  final bool biometricEnabled;
  final String? photoUrl;
  final DashboardMetrics metrics;

  const DashboardSnapshot({
    this.employee,
    this.today,
    this.recentAttendance = const [],
    this.device = const {},
    this.mobileSessionEnforced,
    this.mobileSessionId,
    this.biometricEnabled = false,
    this.photoUrl,
    this.metrics = const DashboardMetrics(),
  });

  AttendanceRecord? get current =>
      today != null && (today!.isClockedIn || today!.clockOut != null)
      ? today
      : null;

  bool get clockedIn => today?.isClockedIn ?? false;

  String get todayLabel {
    final t = today;
    if (t == null) return 'No record';
    if (t.clockOut != null) return 'Clocked out';
    if (t.clockIn != null) return 'Clocked in';
    return 'Not clocked in';
  }
}

/// Calendar-month attendance figures derived from the employee's history and
/// the attendance policy. Pure presentation — the server stays authoritative.
class DashboardMetrics {
  final int daysPresent;
  final double totalHours;
  final int lateDays;
  final double onTimeRate;

  const DashboardMetrics({
    this.daysPresent = 0,
    this.totalHours = 0,
    this.lateDays = 0,
    this.onTimeRate = 0,
  });

  factory DashboardMetrics.fromRecords(
    List<AttendanceRecord> records, {
    DateTime? now,
  }) {
    final ref = now ?? DateTime.now();

    final seen = <String>{};
    var hours = 0.0;
    var late = 0;
    for (final r in records) {
      final date = DateTime.tryParse(r.attendanceDate);
      if (date == null) continue;
      final local = date.toLocal();
      if (local.year != ref.year || local.month != ref.month) continue;
      seen.add(r.attendanceDate.substring(0, 10));
      if (r.clockIn != null) {
        hours += r.workHours > 0 ? r.workHours : 0;
      }
      if (r.lateMinutes > 0) late += 1;
    }
    final present = seen.length;
    final onTime = present - late;
    final rate = present == 0 ? 0.0 : (onTime / present) * 100;
    return DashboardMetrics(
      daysPresent: present,
      totalHours: hours,
      lateDays: late,
      onTimeRate: rate,
    );
  }
}

class DashboardService {
  DashboardService._();
  static final DashboardService instance = DashboardService._();

  Future<DashboardSnapshot> getSnapshot() async {
    final employee = await AttendanceService.instance
        .getMyEmployee()
        .catchError((_) => null);

    AttendanceRecord? today;
    List<AttendanceRecord> history = const [];
    if (employee != null) {
      today = await AttendanceService.instance
          .getToday(employee.id)
          .catchError((_) => null);
      history = await AttendanceService.instance
          .getHistory(employee.id, limit: 90)
          .catchError((_) => <AttendanceRecord>[]);
    }

    final device = await DeviceIdentity.instance.describe();
    final session = MobileSessionService.instance;
    final auth = AuthService.instance;
    final photoUrl = employee == null
        ? null
        : await EmployeePhoto.signedUrlFor(employee.id);

    return DashboardSnapshot(
      employee: employee,
      today: today,
      recentAttendance: history,
      photoUrl: photoUrl,
      metrics: DashboardMetrics.fromRecords(history),
      device: {
        'deviceName': device['deviceName'] ?? 'This device',
        'platform': device['platform'] ?? '',
        'appVersion': device['appVersion'] ?? '',
      },
      mobileSessionEnforced: session.enforced,
      mobileSessionId: session.sessionId,
      biometricEnabled: auth.biometricEnabled,
    );
  }
}
