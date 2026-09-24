import 'dart:math';

import 'package:intl/intl.dart';

import '../models/models.dart';

/// Formatting + numeric helpers shared across features.
class Fmt {
  static String dateShort(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat('d MMM yyyy').format(dt.toLocal());
  }

  static String dateTime(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat('d MMM yyyy, h:mm a').format(dt.toLocal());
  }

  static String clock(String? iso, {String fallback = '—'}) {
    if (iso == null || iso.isEmpty) return fallback;
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat('h:mm a').format(dt.toLocal());
  }

  static String dateTimeShort(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat('d MMM, h:mm a').format(dt.toLocal());
  }

  static String timeShort(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat('h:mm a').format(dt.toLocal());
  }

  static String money(double? v) {
    if (v == null) return '\u2014';
    return NumberFormat.currency(locale: 'en_NG', symbol: '\u20A6').format(v);
  }

  static String num(double? v, {String fallback = '—'}) =>
      v == null ? fallback : v.toStringAsFixed(1);

  static String initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  static String titleCase(String value) {
    if (value.isEmpty) return value;
    return value
        .split(RegExp(r'[_\s]+'))
        .where((p) => p.isNotEmpty)
        .map((p) => p.substring(0, 1).toUpperCase() + p.substring(1))
        .join(' ');
  }
}

/// Haversine distance in metres — same formula as the web geofence service.
double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double toRad(double d) => d * 3.141592653589793 / 180.0;
  final dLat = toRad(lat2 - lat1);
  final dLng = toRad(lng2 - lng1);
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(toRad(lat1)) * cos(toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

class GeoCheck {
  final List<BranchGeofence> geofences;
  final BranchGeofence? nearest;
  final double? distance;
  final bool inside;
  final bool noneConfigured;

  const GeoCheck({
    required this.geofences,
    this.nearest,
    this.distance,
    this.inside = false,
    this.noneConfigured = true,
  });

  factory GeoCheck.evaluate(double lat, double lng, List<BranchGeofence> all) {
    final active = all.where(
      (g) => g.active && g.latitude != null && g.longitude != null,
    );
    if (active.isEmpty) {
      return GeoCheck(geofences: [], noneConfigured: true);
    }
    BranchGeofence? nearest;
    double min = double.infinity;
    for (final g in active) {
      final d = haversineMeters(lat, lng, g.latitude!, g.longitude!);
      if (d < min) {
        min = d;
        nearest = g;
      }
    }
    final inside = nearest != null && min <= nearest.radiusMeters;
    return GeoCheck(
      geofences: active.toList(),
      nearest: nearest,
      distance: nearest == null ? null : min,
      inside: inside,
      noneConfigured: false,
    );
  }
}

class WorkedHours {
  final double worked;
  final double overtime;
  final double allowed;

  const WorkedHours({
    required this.worked,
    required this.overtime,
    required this.allowed,
  });

  static WorkedHours fromRecord(
    AttendanceRecord record, {
    int? overtimeThresholdHours,
  }) {
    final end = DateTime.tryParse(record.clockOut ?? '');
    final start = DateTime.tryParse(record.clockIn ?? '');
    final worked = end != null && start != null
        ? end.difference(start).inMinutes / 60.0
        : record.workHours;
    final threshold = overtimeThresholdHours ?? 10;
    final overtime = worked > threshold ? worked - threshold : 0.0;
    return WorkedHours(
      worked: worked,
      overtime: overtime,
      allowed: overtimeThresholdHours == null ? worked : worked,
    );
  }

  String format() {
    final h = worked.floor();
    final m = ((worked - h) * 60).round();
    return '${h}h ${m}m';
  }
}
