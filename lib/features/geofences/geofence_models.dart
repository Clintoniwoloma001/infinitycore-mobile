import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';

// ---------------------------------------------------------------------------
// Radius rules — these mirror `branch_geofences_normalize()` /
// `save_branch_geofence` in the server migration
// (20261102000001_geofence_management_rbac.sql). The server raises SQLSTATE
// 22023 outside this band, so the UI must refuse the same values: an editor
// that happily saves 5000 m and a server that replies 42501/22023 is the
// exact kind of disagreement this module exists to prevent.
// ---------------------------------------------------------------------------

const double kMinGeofenceRadiusMetres = 10;
const double kMaxGeofenceRadiusMetres = 5000;

const String kRadiusRangeMessage = 'Radius must be between 10 m and 5000 m.';

/// The unit the radius control is currently displaying in. The STORED value
/// is always metres — the unit only ever changes how it is written down, so
/// switching to km can never silently turn 450 m into 450 km.
enum RadiusUnit {
  metres('m', 'Metres'),
  kilometres('km', 'Kilometres');

  const RadiusUnit(this.symbol, this.label);

  final String symbol;
  final String label;
}

String _trim(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  var s = v.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

/// Canonical radius label: `450 m`, `1.5 km`, `5 km`.
///
/// Metres below 1000 so everyday fences read the way HR says them out loud;
/// kilometres from 1000 up so 4500 m is `4.5 km` rather than `4500 m`.
String formatRadiusMetres(num metres) {
  final v = metres.toDouble();
  if (v >= 1000) return '${_trim(v / 1000)} km';
  return '${_trim(v)} m';
}

/// The number to show for [metres] in [unit] (the suffix is [RadiusUnit]).
double radiusDisplayValue(num metres, RadiusUnit unit) =>
    unit == RadiusUnit.metres ? metres.toDouble() : metres / 1000;

/// The bare number for [metres] in [unit], without a unit suffix:
/// `450`, `1.2`, `5`. The suffix is rendered by the field itself so the unit
/// toggle can swap it without re-parsing.
String formatRadiusValue(num metres, RadiusUnit unit) =>
    _trim(radiusDisplayValue(metres, unit));

/// Inverse of [radiusDisplayValue] — always returns metres.
double metresFromDisplay(num value, RadiusUnit unit) =>
    unit == RadiusUnit.metres ? value.toDouble() : value * 1000;

/// Parse user input in [unit] into metres. Returns null when the text is not
/// a number at all; out-of-range numbers parse fine and are rejected by
/// [radiusRangeError] so the caller can show the specific message.
double? parseRadiusInput(String input, RadiusUnit unit) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final value = double.tryParse(text);
  if (value == null || value.isNaN) return null;
  return metresFromDisplay(value, unit);
}

/// null when [metres] is inside the server's 10–5000 m band, otherwise the
/// message to show (and the reason Save stays disabled).
String? radiusRangeError(num? metres) {
  if (metres == null || metres.isNaN) return 'Enter a radius.';
  if (metres < kMinGeofenceRadiusMetres || metres > kMaxGeofenceRadiusMetres) {
    return kRadiusRangeMessage;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Error mapping — SQLSTATE / server token -> the sentence the user reads.
// ---------------------------------------------------------------------------

/// True when [error] is the `require_geofence_admin()` refusal (SQLSTATE
/// 42501). Detection is code-first but falls back to the text because some
/// transports stringify the code into the message only.
bool isGeofenceForbidden(Object error) {
  final code = error is PostgrestException ? error.code : null;
  if (code == '42501') return true;
  final text = error.toString();
  return text.contains('42501') || text.contains('GEOFENCE_FORBIDDEN');
}

/// Map any error thrown by a geofence RPC to a human sentence.
///
/// The three server tokens get verbatim messages agreed with the product:
///   42501  GEOFENCE_FORBIDDEN     -> role restriction
///   22023  GEOFENCE_INVALID(_RADIUS) -> coordinate / radius band
///   P0002  GEOFENCE_NOT_FOUND     -> nothing to act on
String friendlyGeofenceError(Object error) {
  final code = error is PostgrestException ? error.code : null;
  final text = error.toString();

  if (code == '42501' ||
      text.contains('42501') ||
      text.contains('GEOFENCE_FORBIDDEN')) {
    return 'Only Super Admin / Head of HR can manage geofences.';
  }
  if (code == '22023' ||
      text.contains('22023') ||
      text.contains('GEOFENCE_INVALID')) {
    if (text.contains('GEOFENCE_INVALID_RADIUS') ||
        text.toLowerCase().contains('radius')) {
      return kRadiusRangeMessage;
    }
    return 'That geofence is not valid. Check the coordinates and radius.';
  }
  if (code == 'P0002' ||
      text.contains('P0002') ||
      text.contains('GEOFENCE_NOT_FOUND')) {
    return 'No fence configured for this branch.';
  }
  if (SupabaseService.rpcMissing(error)) {
    return 'This feature is not available yet on the server.';
  }
  return text
      .replaceFirst('Exception: ', '')
      .replaceFirst('PostgrestException: ', '');
}

// ---------------------------------------------------------------------------
// RPC payloads
// ---------------------------------------------------------------------------

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

num? _asNum(dynamic value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

/// One row of `list_branch_geofences()` — a branch and its canonical fence.
///
/// The payload carries both column spellings (`latitude`/`center_lat`,
/// `is_active`/`active`) because the deployed table shape varies; reading
/// either is correct and the values are mirrors of each other by trigger.
class BranchGeofence {
  const BranchGeofence({
    required this.id,
    required this.branchId,
    required this.branchName,
    required this.branchCode,
    required this.latitude,
    required this.longitude,
    required this.radiusMetres,
    required this.isActive,
    required this.assignedEmployees,
    this.createdAt,
    this.updatedAt,
  });

  factory BranchGeofence.fromJson(Map<String, dynamic> json) {
    final latitude = _asNum(json['latitude'] ?? json['center_lat']);
    final longitude = _asNum(json['longitude'] ?? json['center_lng']);
    final active = json['is_active'] ?? json['active'] ?? json['geofence_active'];
    return BranchGeofence(
      id: '${json['id'] ?? ''}',
      branchId: '${json['branch_id'] ?? json['id'] ?? ''}',
      branchName: '${json['branch_name'] ?? json['name'] ?? 'Branch'}',
      branchCode: '${json['branch_code'] ?? ''}',
      latitude: latitude?.toDouble() ?? 0,
      longitude: longitude?.toDouble() ?? 0,
      radiusMetres: (_asNum(json['radius_meters']) ?? 100).toDouble(),
      isActive: active != false,
      assignedEmployees: _asNum(json['assigned_employees'])?.round() ?? 0,
      createdAt: json['created_at']?.toString(),
      updatedAt: json['updated_at']?.toString(),
    );
  }

  final String id;
  final String branchId;
  final String branchName;
  final String branchCode;
  final double latitude;
  final double longitude;
  final double radiusMetres;
  final bool isActive;
  final int assignedEmployees;
  final String? createdAt;
  final String? updatedAt;

  LatLng get centre => LatLng(latitude, longitude);

  String get radiusLabel => formatRadiusMetres(radiusMetres);

  /// Six decimal places: ~0.1 m of resolution, the same precision the table
  /// stores (`numeric(10,6)`), so what is shown is what is saved.
  String get coordinatesLabel =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';

  String get employeesLabel => '$assignedEmployees employees';
}

/// The envelope every management RPC returns: the refreshed full list plus
/// `{ok, saved_id / branch_id / is_active / deleted}` depending on the call.
class GeofenceListResult {
  const GeofenceListResult({required this.ok, required this.geofences, required this.raw});

  factory GeofenceListResult.fromRpc(dynamic payload) {
    final raw = _asMap(payload);
    final rows = raw['geofences'];
    final geofences = <BranchGeofence>[];
    if (rows is List) {
      for (final row in rows) {
        if (row is Map) geofences.add(BranchGeofence.fromJson(_asMap(row)));
      }
    }
    return GeofenceListResult(
      ok: raw['ok'] == true,
      geofences: geofences,
      raw: raw,
    );
  }

  final bool ok;
  final List<BranchGeofence> geofences;
  final Map<String, dynamic> raw;
}

/// `check_is_within_geofence()` verdict.
///
/// The distance figures come from the server's own `geo_distance` haversine;
/// the client never recomputes them, because a locally computed "inside" that
/// disagrees with the enforced value is worse than no answer at all.
class CoverageCheck {
  const CoverageCheck({
    required this.ok,
    required this.within,
    required this.hasGeofence,
    this.distanceMetres,
    this.radiusMetres,
    this.metersOutside,
    this.branchId,
    this.source,
    this.reason,
    this.errorCode,
  });

  factory CoverageCheck.fromRpc(dynamic payload) {
    final raw = _asMap(payload);
    return CoverageCheck(
      ok: raw['ok'] == true,
      within: raw['within'] == true,
      // Absent entirely means "the field is new/unknown"; only an explicit
      // false is a true negative (the RPC always sets it when it answers).
      hasGeofence: raw['has_geofence'] != false,
      distanceMetres: _asNum(raw['distance_meters'])?.toDouble(),
      radiusMetres: _asNum(raw['radius_meters'])?.toDouble(),
      metersOutside: _asNum(raw['meters_outside'])?.toDouble(),
      branchId: raw['branch_id']?.toString(),
      source: raw['source']?.toString(),
      reason: raw['reason']?.toString(),
      errorCode: raw['error']?.toString(),
    );
  }

  final bool ok;
  final bool within;
  final bool hasGeofence;
  final double? distanceMetres;
  final double? radiusMetres;
  final double? metersOutside;
  final String? branchId;
  final String? source;
  final String? reason;
  final String? errorCode;

  /// The raw server distance, e.g. `123.4 m` or `1.2 km`.
  String get distanceLabel => distanceMetres == null
      ? '—'
      : formatRadiusMetres(distanceMetres!);

  /// How far past the fence edge the server measured, same formatting.
  String get outsideLabel => metersOutside == null
      ? '—'
      : formatRadiusMetres(metersOutside!);
}

// ---------------------------------------------------------------------------
// Lock-circle state machine
// ---------------------------------------------------------------------------

/// Where the pin and the fence circle are, and whether they are locked
/// together. This is the whole editor interaction model:
///
///  * LOCKED (default): the circle is anchored to the pin — dragging the pin
///    moves the fence with it, and the circle handle is hidden because there
///    is nothing separate to grab.
///  * UNLOCKED: the pin (the test/user location) and the circle (the fence
///    being placed) are two independent handles.
///
/// Unlocking never jumps the circle: it snapshots the pin's position as the
/// free centre at the moment of release, and locking snaps it back onto the
/// pin, so no transition silently relocates the fence.
class CirclePlacement {
  CirclePlacement({required LatLng pin, bool startLocked = true})
    : _pin = pin,
      _freeCentre = pin,
      _locked = startLocked;

  LatLng _pin;
  LatLng _freeCentre;
  bool _locked;

  bool get locked => _locked;
  bool get unlocked => !_locked;

  /// The test/user location handle.
  LatLng get pin => _pin;

  /// The centre the fence circle must be drawn at given the lock state.
  LatLng get circleCentre => _locked ? _pin : _freeCentre;

  /// Switch between anchored and free. Locking re-anchors the circle onto the
  /// pin; unlocking releases it exactly where it currently sits.
  void setLocked(bool value) {
    if (value == _locked) return;
    if (value) {
      _locked = true;
    } else {
      _freeCentre = _pin;
      _locked = false;
    }
  }

  void toggleLock() => setLocked(!_locked);

  /// Move the pin. While locked the circle follows, and the free copy is kept
  /// in step so a later unlock starts from where the circle visibly is.
  void movePin(LatLng next) {
    _pin = next;
    if (_locked) _freeCentre = next;
  }

  /// Move the circle independently — a no-op while locked, which is exactly
  /// what "locked" means: there is no separate circle to drag.
  void moveCircle(LatLng next) {
    if (_locked) return;
    _freeCentre = next;
  }
}
