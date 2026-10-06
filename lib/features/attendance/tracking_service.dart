import 'package:intl/intl.dart';

import '../../core/services/supabase_service.dart';

/// Employee Tracking on mobile — SUPER ADMIN ONLY.
///
/// Reads the SAME server-authoritative RPCs as the web Command Centre:
///   * employee_tracking_access()   — may I read tracking at all?
///   * employee_current_locations() — one live row per employee
///   * employee_location_history()  — that employee's points for one day
///
/// Every inside/outside verdict comes from `resolve_employee_location()` on the
/// server. Nothing here recomputes distance or decides whether a point is
/// inside a fence, so mobile and web cannot disagree about where somebody is.
///
/// Access: see `canAccessEmployeeTracking`. A tracking GRANT issued on web does
/// not open this on mobile — Super Admin only, deliberately. The server still
/// makes the real decision; this client only avoids offering an action the RPC
/// would refuse.
class TrackingService {
  const TrackingService._();

  static final TrackingService instance = TrackingService._();

  /// Whether the server will let this account read tracking.
  ///
  /// Fails CLOSED: any error or non-true answer is "no". A tracking screen that
  /// renders on a failed probe is worse than one that stays closed.
  Future<bool> canView() async {
    try {
      final res = await SupabaseService.client.rpc('employee_tracking_access');
      if (res is Map) return res['can_view'] == true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Live positions, most recent first.
  Future<List<TrackedEmployee>> livePositions({
    int withinMinutes = 240,
  }) async {
    final res = await SupabaseService.client.rpc(
      'employee_current_locations',
      params: {'p_within_minutes': withinMinutes},
    );
    if (res is Map && res['ok'] == false) {
      throw TrackingException(
        '${res['message'] ?? 'Unable to load live positions'}',
      );
    }
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((e) => TrackedEmployee.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  /// Movement history for one employee on one local day.
  Future<TrackingDay> history(String employeeId, DateTime date) async {
    final res = await SupabaseService.client.rpc(
      'employee_location_history',
      params: {
        'p_employee_id': employeeId,
        // The RPC filters in the app timezone, so a plain calendar day is sent
        // rather than an instant.
        'p_date': DateFormat('yyyy-MM-dd').format(date),
        'p_inside_only': 'all',
      },
    );
    if (res is Map && res['ok'] == false) {
      throw TrackingException('${res['message'] ?? 'Unable to load history'}');
    }
    if (res is! Map) {
      throw const TrackingException('The server returned an unexpected response.');
    }
    return TrackingDay.fromJson(Map<String, dynamic>.from(res));
  }
}

class TrackingException implements Exception {
  final String message;
  const TrackingException(this.message);
  @override
  String toString() => message;
}
/// One employee's most recent recorded observation.
class TrackedEmployee {
  const TrackedEmployee({
    required this.id,
    required this.name,
    required this.employeeNumber,
    required this.position,
    required this.branchName,
    required this.insideGeofence,
    required this.locationLabel,
    required this.resolvedPlace,
    required this.minutesAgo,
    this.latitude,
    this.longitude,
  });

  factory TrackedEmployee.fromJson(Map<String, dynamic> j) => TrackedEmployee(
    id: (j['employee_id'] ?? '').toString(),
    name: (j['full_name'] ?? '—').toString(),
    employeeNumber: (j['employee_number'] ?? '').toString(),
    position: (j['position'] ?? '').toString(),
    branchName: (j['branch_name'] ?? '').toString(),
    insideGeofence: j['inside_geofence'] == true,
    locationLabel: (j['location_label'] ?? '').toString(),
    // The reverse-geocoded real place, present only once a client has looked it
    // up. Preferred for an OUTSIDE point; never used for an inside one.
    resolvedPlace: (j['resolved_place'] ?? '').toString(),
    minutesAgo: (j['minutes_ago'] as num?)?.toInt(),
    latitude: (j['latitude'] as num?)?.toDouble(),
    longitude: (j['longitude'] as num?)?.toDouble(),
  );

  final String id;
  final String name;
  final String employeeNumber;
  final String position;
  final String branchName;
  final bool insideGeofence;
  final String locationLabel;
  final String resolvedPlace;
  final int? minutesAgo;
  final double? latitude;
  final double? longitude;

  /// Older than this is not "live", and saying so is the entire point.
  bool get isStale => (minutesAgo ?? 0) > 45;

  /// Where this person actually is, for display.
  ///
  /// Inside a fence the registered location is the VERIFIED answer and is used
  /// regardless of any geocoded address. Outside, the real place is preferred
  /// over the "Outside HEAD OFFICE (9 km away)" wording, and the honest label is
  /// kept as the fallback so a failed lookup never invents a location.
  String get place => insideGeofence
      ? (locationLabel.isEmpty ? 'Registered location' : locationLabel)
      : (resolvedPlace.isNotEmpty ? resolvedPlace : locationLabel);

  /// Sub-line making the verdict explicit, so a place name is never misread as
  /// "they are at the office".
  String? get placeNote {
    if (insideGeofence) return null;
    if (resolvedPlace.isNotEmpty && resolvedPlace != locationLabel) {
      return 'Outside every registered location';
    }
    return locationLabel.isEmpty ? 'Outside registered locations' : null;
  }

  String get subtitle =>
      [if (position.isNotEmpty) position, if (branchName.isNotEmpty) branchName]
          .join(' · ');
}

/// One day's movement history for one employee.
class TrackingDay {
  const TrackingDay({required this.points, required this.timezone});

  factory TrackingDay.fromJson(Map<String, dynamic> j) {
    final raw = j['points'];
    final points = raw is List
        ? raw
              .whereType<Map>()
              .map((e) => TrackingPoint.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
        : const <TrackingPoint>[];
    return TrackingDay(
      points: points,
      timezone: (j['timezone'] ?? '').toString(),
    );
  }

  final List<TrackingPoint> points;
  final String timezone;

  bool get isEmpty => points.isEmpty;
  int get insideCount => points.where((p) => p.insideGeofence).length;

  /// The subset that can actually be drawn, in chronological order.
  ///
  /// Points without usable coordinates are dropped here rather than being
  /// plotted at a default position, so a partially-recorded day still shows
  /// the real route it does have instead of collapsing into one false marker.
  List<TrackingPoint> get mappablePoints {
    final usable = points.where((p) => p.hasCoordinates).toList()
      ..sort((a, b) {
        final at = a.recordedAt;
        final bt = b.recordedAt;
        // Undated points sort last instead of jumping to the start.
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return at.compareTo(bt);
      });
    return usable;
  }

  /// Points that were recorded but could not be placed on the map. Surfaced to
  /// the user so a gap is explained rather than silently hidden.
  int get unplaceableCount => points.where((p) => !p.hasCoordinates).length;
}

/// One recorded observation.
class TrackingPoint {
  const TrackingPoint({
    required this.id,
    required this.recordedAt,
    required this.insideGeofence,
    required this.locationLabel,
    required this.resolvedPlace,
    this.latitude,
    this.longitude,
    this.accuracy,
    this.speedMps,
    this.batteryLevel,
    this.networkType = '',
  });

  factory TrackingPoint.fromJson(Map<String, dynamic> j) => TrackingPoint(
    id: (j['id'] ?? '').toString(),
    recordedAt: DateTime.tryParse((j['recorded_at'] ?? '').toString()),
    insideGeofence: j['inside_geofence'] == true,
    locationLabel: (j['location_label'] ?? '').toString(),
    resolvedPlace: (j['resolved_place'] ?? '').toString(),
    // Coordinates and telemetry are additive: older servers and older rows
    // simply omit them, and a missing value is carried as null rather than
    // being coerced to 0. A 0,0 pin would drop a breadcrumb in the Gulf of
    // Guinea and quietly corrupt the route, so this is deliberately strict.
    latitude: (j['latitude'] as num?)?.toDouble(),
    longitude: (j['longitude'] as num?)?.toDouble(),
    accuracy: (j['accuracy'] as num?)?.toDouble(),
    speedMps: (j['speed_mps'] as num?)?.toDouble(),
    batteryLevel: (j['battery_level'] as num?)?.toInt(),
    networkType: (j['network_type'] ?? '').toString(),
  );

  final String id;
  final DateTime? recordedAt;
  final bool insideGeofence;
  final String locationLabel;
  final String resolvedPlace;
  final double? latitude;
  final double? longitude;

  /// Reported GPS accuracy in metres, when the OS supplied it. Rendered as the
  /// accuracy radius around the marker so a ±80 m fix never looks exact.
  final double? accuracy;
  final double? speedMps;
  final int? batteryLevel;
  final String networkType;

  /// Only a point with a real, in-range coordinate may be drawn on the map.
  bool get hasCoordinates {
    final lat = latitude;
    final lon = longitude;
    if (lat == null || lon == null) return false;
    // Null Island is the classic sentinel for "GPS never initialised".
    if (lat == 0 && lon == 0) return false;
    return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
  }

  /// Evidence quality, stated honestly rather than smoothed over. A fix taken
  /// on a dying battery or with no connectivity is weaker proof of presence,
  /// and the detail sheet says so instead of presenting it as certain.
  String? get evidenceNote {
    final notes = <String>[];
    final battery = batteryLevel;
    if (battery != null && battery <= 15) notes.add('low battery ($battery%)');
    if (networkType.isNotEmpty && networkType != 'unknown') {
      if (networkType == 'other' || networkType == 'ethernet') {
        notes.add('network: $networkType');
      }
    }
    if (notes.isEmpty) return null;
    return 'Weak signal — ${notes.join(', ')}';
  }

  String get place => insideGeofence
      ? (locationLabel.isEmpty ? 'Registered location' : locationLabel)
      : (resolvedPlace.isNotEmpty ? resolvedPlace : locationLabel);
}