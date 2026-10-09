// ============================================================================
// Tracking is clock-independent (supersedes all previous rules)
// ============================================================================
// Pure/source tests only. No Supabase session, no geolocation, no network.
//
// THE RULE THIS FILE GUARDS
// Background location tracking runs for the WHOLE authenticated session and
// must NOT stop when the employee clocks out. Clocking in/out is an attendance
// event, not a tracking event. This rule supersedes every earlier intent that
// might have tied tracking to attendance state.
//
// Because the bug this protects against is a *regression* - someone re-gating
// tracking on the clock again - a behavioural unit test is not enough (there
// is no clock path to exercise today). Instead this file reads the source and
// fails loudly if the contract is ever broken:
//   1. LocationTrackingService.evaluate() never reads attendance/clock state.
//   2. No clock-out flow calls a tracking stop.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _trackingPath = 'lib/core/services/location_tracking_service.dart';
const _attendanceScreenPath = 'lib/features/attendance/attendance_screen.dart';
const _overviewPath = 'lib/features/director/attendance_overview_screen.dart';
const _attendanceServicePath =
    'lib/features/attendance/attendance_service.dart';

String _read(String path) => File(path).readAsStringSync();

/// Extracts the body of [evaluate] from the tracking service so the assertions
/// below target the eligibility decision itself and not unrelated comments.
String _evaluateBody() {
  final src = _read(_trackingPath);
  final start = src.indexOf('Future<void> evaluate(');
  expect(
    start,
    greaterThan(-1),
    reason: 'evaluate() must exist in LocationTrackingService',
  );
  // The next method after evaluate() is _startNativeService(); cut there so we
  // only inspect evaluate()'s own logic.
  final end = src.indexOf('Future<void> _startNativeService(', start);
  expect(end, greaterThan(start), reason: 'could not bound evaluate() body');
  return src.substring(start, end);
}

/// Removes // line comments and /* */ block comments so that prose (e.g. the
/// word "attendance" in a doc comment) can never satisfy or trip a code-level
/// assertion. We only want to scan executable logic.
String _stripComments(String source) {
  final buf = StringBuffer();
  var i = 0;
  var inString = false;
  var stringQuote = '';
  while (i < source.length) {
    final c = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    // Skip string literals so a "//" inside a string is not treated as one.
    if (inString) {
      if (c == '\\') {
        buf.write(c);
        if (next.isNotEmpty) buf.write(next);
        i += 2;
        continue;
      }
      if (c == stringQuote) inString = false;
      buf.write(c);
      i++;
      continue;
    }
    if (c == '"' || c == "'" || c == '`') {
      inString = true;
      stringQuote = c;
      buf.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i < source.length &&
          !(source[i] == '*' &&
              i + 1 < source.length &&
              source[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    buf.write(c);
    i++;
  }
  return buf.toString();
}

void main() {
  group('Tracking runs regardless of clock state', () {
    test('evaluate() gates only on auth/status/location/permission', () {
      final body = _stripComments(_evaluateBody());

      // Every gate that IS allowed to stop tracking.
      expect(body, contains('isAuthenticated'));
      expect(body, contains('blockedByStatus'));
      expect(body, contains('isLocationServiceEnabled'));
      expect(body, contains('checkPermission'));

      // The contract: attendance state is never consulted. None of these
      // attendance/clock tokens may appear in the eligibility decision.
      for (final forbidden in const [
        'isClockedIn',
        'clockOut',
        'clockIn',
        'getToday',
        'AttendanceService',
        'attendance',
        'shift',
      ]) {
        expect(
          body.toLowerCase(),
          isNot(contains(forbidden.toLowerCase())),
          reason:
              'evaluate() must not gate tracking on "$forbidden" - '
              'tracking must run even when clocked out',
        );
      }
    });

    test('the "always on" invariant is documented in the header', () {
      final src = _read(_trackingPath);
      expect(src, contains('TRACKING IS ALWAYS ON'));
      expect(src, contains('clocking OUT does not stop it'));
    });
  });

  group('No clock-out flow stops tracking', () {
    // A tracking stop is any of these; a clock-out path must contain none.
    const stopTokens = [
      'LocationHeartbeat.instance.stop',
      'LocationTrackingService.instance._stop',
      '_stopNativeService',
      '.stopAutomatic',
    ];

    for (final entry in const [
      {'label': 'attendance_screen', 'path': _attendanceScreenPath},
      {'label': 'attendance_overview_screen', 'path': _overviewPath},
      {'label': 'attendance_service', 'path': _attendanceServicePath},
    ]) {
      test('${entry['label']} never stops tracking', () {
        final src = _read(entry['path']!);
        for (final token in stopTokens) {
          expect(
            src,
            isNot(contains(token)),
            reason:
                '${entry['label']} must not call "$token" - clocking out '
                'must not stop location tracking',
          );
        }
      });
    }
  });
}
