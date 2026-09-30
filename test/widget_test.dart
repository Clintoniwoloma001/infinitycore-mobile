import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/features/attendance/attendance_service.dart';
import 'package:infinitycore/features/attendance/qr_terminal.dart';
import 'package:infinitycore/shared/models/models.dart';
import 'package:infinitycore/shared/utils/formatters.dart';
import 'package:infinitycore/shared/widgets/attendance_history_card.dart';
import 'package:infinitycore/shared/widgets/common.dart';

void main() {
  group('Fmt', () {
    test('initials derives two-letter initials', () {
      expect(Fmt.initials('Adeola Bankole'), 'AB');
      expect(Fmt.initials('Sara'), 'S');
      expect(Fmt.initials(''), '?');
    });

    test('titleCase handles underscores and spaces', () {
      expect(Fmt.titleCase('hr_manager'), 'Hr Manager');
      expect(Fmt.titleCase('branch manager'), 'Branch Manager');
    });

    test('dateShort falls back to the raw value for bad input', () {
      expect(Fmt.dateShort(null), '\u2014');
      expect(Fmt.dateShort('not-a-date'), 'not-a-date');
    });
  });

  group('GeoCheck', () {
    test('haversineMeters approximates Lagos branch distance', () {
      final d = haversineMeters(6.5244, 3.3792, 6.5244, 3.3792);
      expect(d, lessThan(1));
      final km = haversineMeters(6.5244, 3.3792, 6.5285, 3.3797) / 1000;
      expect(km, greaterThan(0.4));
      expect(km, lessThan(0.62));
    });

    test('evaluate flags inside a configured geofence', () {
      final check = GeoCheck.evaluate(6.5244, 3.3792, [
        BranchGeofence(
          id: '1',
          name: 'Main',
          latitude: 6.5244,
          longitude: 3.3792,
          radiusMeters: 150,
        ),
      ]);
      expect(check.noneConfigured, isFalse);
      expect(check.inside, isTrue);
    });
  });

  testWidgets('StatCard renders label and value', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StatCard(label: 'Present today', value: '42'),
        ),
      ),
    );
    expect(find.text('Present today'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('StatusBadge renders green badge', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StatusBadge(label: 'Clocked in')),
      ),
    );
    expect(find.text('Clocked In'), findsOneWidget);
  });

  group('EmployeeRef', () {
    test('parses joined year safely when joined_date is empty', () {
      final e = EmployeeRef.fromJson(const {'id': 'a', 'joined_date': ''});
      expect(e.joinedYear, isNull);
      expect(e.displayId, '—');
    });

    test('parses employee fields incl. manager and phone', () {
      final e = EmployeeRef.fromJson({
        'id': 'a',
        'full_name': 'Ada Obi',
        'phone': '0800',
        'manager_id': 'm1',
        'manager_name': 'Kele Okafor',
        'joined_date': '2021-03-14',
        'employee_number': 'INF-2001',
      });
      expect(e.phone, '0800');
      expect(e.managerName, 'Kele Okafor');
      expect(e.joinedYear, 2021);
      expect(e.displayId, 'INF-2001');
    });
  });

  group('AttendanceRecord', () {
    test('parses server location/geofence fields', () {
      final r = AttendanceRecord.fromJson({
        'id': 'rec1',
        'employee_id': 'e1',
        'attendance_date': '2026-09-22',
        'clock_in': '2026-09-22T08:03:00Z',
        'geofence_status': 'inside',
        'location_status': 'inside',
        'verification_method': 'biometric',
        'clock_in_lat': 6.5244,
        'clock_in_lng': 3.3792,
        'clock_in_accuracy': 8.5,
        'clock_in_distance': 42.0,
        'actual_location_name': 'Main Branch',
      });
      expect(r.isInsideGeofence, isTrue);
      expect(r.verificationMethod, 'biometric');
      expect(r.clockInLat, 6.5244);
      expect(r.clockInDistance, 42.0);
      expect(r.actualLocationName, 'Main Branch');
      expect(r.isClockedIn, isTrue);
    });
  });

  group('AttendanceManagementRow', () {
    test('parses a summary row', () {
      final row = AttendanceManagementRow.fromJson({
        'attendance_id': 'a1',
        'employee_id': 'e1',
        'employee_name': 'Ada Obi',
        'employee_number': 'INF-2001',
        'department': 'Operations',
        'branch_id': 'b1',
        'branch_name': 'Lagos Main',
        'attendance_date': '2026-09-22',
        'clock_in': '2026-09-22T08:03:00Z',
        'clock_out': '2026-09-22T17:02:00Z',
        'status': 'late',
        'work_hours': 8.98,
        'total_minutes': 539,
        'late_minutes': 3,
        'location_status': 'inside',
        'geofence_status': 'inside',
      });
      expect(row.employeeName, 'Ada Obi');
      expect(row.status, 'late');
      expect(row.isCurrentlyOpen, isFalse);
    });

    test('flags open sessions', () {
      final row = AttendanceManagementRow.fromJson({
        'attendance_id': 'a2',
        'employee_name': 'Kele Okafor',
        'clock_in': '2026-09-22T08:03:00Z',
      });
      expect(row.isCurrentlyOpen, isTrue);
    });

    test('normalizes late_status from boolean legacy rows', () {
      final lateBool = AttendanceManagementRow.fromJson({
        'attendance_id': 'a3',
        'late_status': true,
      }).lateStatus;
      expect(lateBool, 'late');

      final onTimeBool = AttendanceManagementRow.fromJson({
        'attendance_id': 'a3',
        'late_status': false,
      }).lateStatus;
      expect(onTimeBool, 'on_time');
    });

    test('normalizes late_status raw 1/0 and passthrough text', () {
      expect(
        AttendanceManagementRow.fromJson({
          'attendance_id': 'a3',
          'late_status': '1',
        }).lateStatus,
        'late',
      );
      expect(
        AttendanceManagementRow.fromJson({
          'attendance_id': 'a3',
          'late_status': '0',
        }).lateStatus,
        'on_time',
      );
      expect(
        AttendanceManagementRow.fromJson({
          'attendance_id': 'a3',
          'late_status': null,
        }).lateStatus,
        '',
      );
      expect(
        AttendanceManagementRow.fromJson({
          'attendance_id': 'a3',
          'late_status': 'late',
        }).lateStatus,
        'late',
      );
    });
  });

  group('QrTerminalPayload', () {
    test('parses the web attendance-terminal URL', () {
      final p = QrTerminalPayload.tryParse(
        'https://clintoniwolomaim001.github.io/infinitycore-sara/'
        '#/attendance-terminal?token=abc123def456',
      );
      expect(p.token, 'abc123def456');
      expect(p.source, 'url');
    });

    test('falls back to a raw token', () {
      final p = QrTerminalPayload.tryParse(
        '  7f8e9d0c1b2a3f4e5d6c7b8a9f0e1d2c  ',
      );
      expect(p.token, '7f8e9d0c1b2a3f4e5d6c7b8a9f0e1d2c');
      expect(p.source, 'raw');
    });

    test('rejects empty and non-terminal inputs', () {
      expect(() => QrTerminalPayload.tryParse(''), throwsFormatException);
      expect(
        () => QrTerminalPayload.tryParse('https://example.com/foo'),
        throwsFormatException,
      );
      expect(
        () => QrTerminalPayload.tryParse('has / slash'),
        throwsFormatException,
      );
    });
  });

  group('TerminalInfo', () {
    test('maps inspect fields', () {
      final t = TerminalInfo.fromJson({
        'valid': true,
        'message': 'ok',
        'terminal_id': 't-1',
        'terminal_name': 'Reception',
        'status': 'active',
        'active': true,
        'area': 'Lobby',
        'latitude': 6.52,
        'longitude': 3.37,
        'geofence_status': 'inside',
      });
      expect(t.valid, isTrue);
      expect(t.terminalId, 't-1');
      expect(t.terminalName, 'Reception');
      expect(t.latitude, 6.52);
      expect(t.geofenceStatus, 'inside');
    });

    test('invalid verdict round-trips through TerminalScanResult encode', () {
      final r = TerminalScanResult(
        token: 'tok',
        terminal: TerminalInfo.fromJson({
          'valid': false,
          'message': 'Terminal not found',
          'terminal_id': null,
          'terminal_name': null,
        }),
      );
      final decoded = TerminalScanResult.fromJson(r.toJson());
      expect(decoded.token, 'tok');
      expect(decoded.terminal.valid, isFalse);
      expect(decoded.terminal.message, 'Terminal not found');
    });
  });

  group('AttendanceHistoryCard', () {
    String isoDate(DateTime d) {
      final m = d.month.toString().padLeft(2, '0');
      final day = d.day.toString().padLeft(2, '0');
      return '${d.year}-$m-$day';
    }

    AttendanceRecord record(String id, DateTime date) =>
        AttendanceRecord.fromJson({
          'id': id,
          'employee_id': 'e1',
          'attendance_date': isoDate(date),
          'clock_in': '${isoDate(date)}T08:03:00',
          'clock_out': '${isoDate(date)}T17:02:00',
          'status': 'present',
        });

    Widget host(AttendanceHistoryCard card) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: card)),
    );

    testWidgets('filters by DAY, WEEK and MONTH', (tester) async {
      final now = DateTime.now();
      final today = now.toLocal();
      final delta6 = today.subtract(const Duration(days: 6));
      final old = today.subtract(const Duration(days: 800));

      await tester.pumpWidget(
        host(
          AttendanceHistoryCard(
            records: [
              record('old', old),
              record('six', delta6),
              record('now', today),
            ],
          ),
        ),
      );

      final todayLabel = Fmt.dateShort(isoDate(today));
      final delta6Label = Fmt.dateShort(isoDate(delta6));
      final oldLabel = Fmt.dateShort(isoDate(old));

      expect(find.text(todayLabel), findsOneWidget);

      await tester.tap(find.text('DAY'));
      await tester.pumpAndSettle();
      expect(find.text(todayLabel), findsOneWidget);
      expect(find.text(delta6Label), findsNothing);
      expect(find.text(oldLabel), findsNothing);

      await tester.tap(find.text('WEEK'));
      await tester.pumpAndSettle();
      expect(find.text(todayLabel), findsOneWidget);
      expect(find.text(delta6Label), findsOneWidget);
      expect(find.text(oldLabel), findsNothing);

      await tester.tap(find.text('MONTH'));
      await tester.pumpAndSettle();
      expect(find.text(todayLabel), findsOneWidget);
      expect(find.text(oldLabel), findsNothing);
    });

    testWidgets('caps rows at maxRows and surfaces the empty state', (
      tester,
    ) async {
      final now = DateTime.now().toLocal();
      await tester.pumpWidget(
        host(const AttendanceHistoryCard(records: [], maxRows: 12)),
      );
      expect(
        find.text('Clock in to create your first attendance record.'),
        findsOneWidget,
      );

      final rows = [for (var i = 0; i < 15; i++) record('r$i', now)];
      await tester.pumpWidget(
        host(AttendanceHistoryCard(records: rows, maxRows: 12)),
      );
      await tester.tap(find.text('DAY'));
      await tester.pumpAndSettle();
      expect(find.text(Fmt.dateShort(isoDate(now))), findsNWidgets(12));
    });
  });

  group('AttendanceService.normalizeError', () {
    test('extracts each known server prefix', () {
      const cases = {
        'MOBILE_SESSION: This device is no longer your active session. '
                'Sign in on another device.':
            'This device is no longer your active session. Sign in on another device.',
        'OUTSIDE_GEOFENCE: You are 2.1 km from the nearest approved location.':
            'You are 2.1 km from the nearest approved location.',
        'GEOFENCE_NOT_CONFIGURED: No geofence is configured for your branch.':
            'No geofence is configured for your branch.',
        'LOCATION_REQUIRED: Location permission is required to clock in.':
            'Location permission is required to clock in.',
        'LOCATION_INVALID: Spoofed location detected.':
            'Spoofed location detected.',
        'DEVICE_BINDING: This device is already bound to another employee today.':
            'This device is already bound to another employee today.',
      };
      cases.forEach((raw, expected) {
        expect(AttendanceService.normalizeError(raw), expected);
      });
    });

    test('extracts biometric and unauthorized-device server prefixes', () {
      expect(
        AttendanceService.normalizeError(
          'BIOMETRIC_REQUIRED:Attendance requires a successful biometric '
          'assertion on this device.',
        ),
        'Attendance requires a successful biometric assertion on this device.',
      );
      expect(
        AttendanceService.normalizeError(
          'MOBILE_UNAUTHORIZED_DEVICE:This account is already linked to '
          'another mobile device. Please contact HR or Super Admin to '
          'authorize this device.',
        ),
        'This account is already linked to another mobile device. Please '
        'contact HR or Super Admin to authorize this device.',
      );
    });

    test('maps messages to friendly text', () {
      expect(
        AttendanceService.normalizeError(
          'PostgrestException: you are outside the geofence',
        ),
        'You are outside the approved attendance location.',
      );
      expect(
        AttendanceService.normalizeError('you are already clocked in'),
        'You are already clocked in.',
      );
      expect(
        AttendanceService.normalizeError('There is no clock to close'),
        'There is no open attendance session to clock out.',
      );
    });

    test('fallback strips exception prefixes', () {
      expect(
        AttendanceService.normalizeError('Exception: Request failed'),
        'Request failed',
      );
    });

    test('extracts terminal-validation server prefixes', () {
      expect(
        AttendanceService.normalizeError(
          'TERMINAL_INACTIVE:This attendance terminal is not active.',
        ),
        'This attendance terminal is not active.',
      );
      expect(
        AttendanceService.normalizeError(
          'TERMINAL_NOT_FOUND:No terminal matches that code.',
        ),
        'No terminal matches that code.',
      );
    });
  });
}
