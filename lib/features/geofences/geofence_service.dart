import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/services/supabase_service.dart';
import 'geofence_models.dart';

/// A branch offered by "Add fence" — one that has no canonical fence yet.
class BranchOption {
  const BranchOption({
    required this.id,
    required this.branchName,
    required this.branchCode,
    this.latitude,
    this.longitude,
  });

  factory BranchOption.fromJson(Map<String, dynamic> json) => BranchOption(
    id: '${json['id'] ?? ''}',
    branchName: '${json['branch_name'] ?? 'Branch'}',
    branchCode: '${json['branch_code'] ?? ''}',
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
  );

  final String id;
  final String branchName;
  final String branchCode;
  final double? latitude;
  final double? longitude;

  bool get hasCoordinates => latitude != null && longitude != null;

  String get coordinatesLabel => hasCoordinates
      ? '${latitude!.toStringAsFixed(6)}, ${longitude!.toStringAsFixed(6)}'
      : 'No coordinates yet';
}

/// Geofence RPC client. Every management call is a server-authoritative RPC
/// (`require_geofence_admin()` re-checks the role inside Postgres), and
/// `check_is_within_geofence` is deliberately readable by any signed-in user —
/// the tester's verdict is the same haversine the attendance engine enforces.
class GeofenceService {
  GeofenceService._();

  static final GeofenceService instance = GeofenceService._();

  /// `list_branch_geofences()` — every branch fence, ordered by branch name.
  Future<GeofenceListResult> list() async {
    final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'list_branch_geofences',
    );
    return GeofenceListResult.fromRpc(data);
  }

  /// `save_branch_geofence` — creates the fence when the branch has none.
  Future<GeofenceListResult> save({
    required String branchId,
    required double latitude,
    required double longitude,
    required double radiusMetres,
    bool isActive = true,
  }) async {
    final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'save_branch_geofence',
      params: {
        'p_branch_id': branchId,
        'p_latitude': latitude,
        'p_longitude': longitude,
        'p_radius_meters': radiusMetres,
        'p_is_active': isActive,
      },
    );
    return GeofenceListResult.fromRpc(data);
  }

  /// `set_branch_geofence_active` — note p_branch_id, NOT the fence row id.
  Future<GeofenceListResult> setBranchActive({
    required String branchId,
    required bool isActive,
  }) async {
    final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'set_branch_geofence_active',
      params: {'p_branch_id': branchId, 'p_is_active': isActive},
    );
    return GeofenceListResult.fromRpc(data);
  }

  /// `delete_branch_geofence` — takes the branch id; the canonical row goes,
  /// the legacy `branches` / `attendance_geofences` copies are disabled.
  Future<GeofenceListResult> deleteBranch({required String branchId}) async {
    final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'delete_branch_geofence',
      params: {'p_branch_id': branchId},
    );
    return GeofenceListResult.fromRpc(data);
  }

  /// `check_is_within_geofence` — the "Test My Coverage" call. Readable by
  /// ANY authenticated user; `p_branch_id` is required.
  Future<CoverageCheck> checkCoverage({
    required double latitude,
    required double longitude,
    required String branchId,
  }) async {
    final data = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'check_is_within_geofence',
      params: {
        'p_lat': latitude,
        'p_lng': longitude,
        'p_branch_id': branchId,
      },
    );
    return CoverageCheck.fromRpc(data);
  }

  /// The `branches` select list shared with the attendance readers
  /// (see `listGeofences()` in attendance_service.dart) — same columns, so a
  /// branch rendered here looks exactly like the same branch on the map.
  static const String _branchSelect =
      'id, branch_name, branch_code, latitude, longitude, geofence_radius, '
      'geofence_active, location, branch_name_as_location';

  /// Branches with no canonical fence yet — the "Add fence" candidates.
  Future<List<BranchOption>> branchesWithoutFence(
    Iterable<String> fencedBranchIds,
  ) async {
    final fenced = fencedBranchIds.toSet();
    final res = await SupabaseService.client
        .from('branches')
        .select(_branchSelect);
    final options = <BranchOption>[];
    for (final row in (res as List<dynamic>? ?? [])) {
      if (row is! Map) continue;
      final option = BranchOption.fromJson(Map<String, dynamic>.from(row));
      if (!fenced.contains(option.id)) options.add(option);
    }
    options.sort((a, b) => a.branchName.compareTo(b.branchName));
    return options;
  }

  /// The fence list for the coverage tester.
  ///
  /// `list_branch_geofences` is admin-gated, but `check_is_within_geofence`
  /// is intentionally readable by every signed-in user and the tester route
  /// (`/geofences/tester`) is a child path the auth gate does not redirect.
  /// So a non-admin gets the same `branches` fallback the attendance readers
  /// use instead of hitting a 42501 wall — the verdict still comes from the
  /// server, which reads those same legacy stores in its own order.
  Future<List<BranchGeofence>> listForTester() async {
    try {
      return (await list()).geofences;
    } on Exception catch (e) {
      if (!isGeofenceForbidden(e)) rethrow;
      return _branchFallback();
    }
  }

  Future<List<BranchGeofence>> _branchFallback() async {
    final res = await SupabaseService.client
        .from('branches')
        .select(_branchSelect);
    final fences = <BranchGeofence>[];
    for (final row in (res as List<dynamic>? ?? [])) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final latitude = (map['latitude'] as num?)?.toDouble();
      final longitude = (map['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) continue;
      fences.add(
        BranchGeofence(
          // Synthetic fence-row id; the BRANCH id below is the real one and
          // is what `check_is_within_geofence` takes.
          id: 'branch-${map['id']}',
          branchId: '${map['id']}',
          branchName: '${map['branch_name'] ?? 'Branch'}',
          branchCode: '${map['branch_code'] ?? ''}',
          latitude: latitude,
          longitude: longitude,
          radiusMetres: (map['geofence_radius'] as num?)?.toDouble() ?? 150,
          isActive: map['geofence_active'] != false,
          assignedEmployees: 0,
        ),
      );
    }
    fences.sort((a, b) => a.branchName.compareTo(b.branchName));
    return fences;
  }

  /// A device GPS fix with tester-friendly failure messages, each ending in
  /// the manual-entry escape hatch so the tester still works in a simulator
  /// or with location switched off.
  Future<LatLng> deviceFix() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw StateError(
        'Location services are turned off. Turn them on, or enter '
        'coordinates manually.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw StateError(
        'Location permission was denied. You can still enter coordinates '
        'manually.',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw StateError(
        'Location permission is permanently denied. Enable it in Settings, '
        'or enter coordinates manually.',
      );
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return LatLng(position.latitude, position.longitude);
    } catch (error) {
      if (error is StateError) rethrow;
      throw StateError(
        'Could not get a GPS fix ($error). Enter coordinates manually.',
      );
    }
  }
}
