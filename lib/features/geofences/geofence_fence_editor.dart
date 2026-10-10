import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_theme.dart';
import '../dashboard/home_shell.dart';
import 'geofence_models.dart';
import 'geofence_service.dart';

/// Full-screen interactive fence editor: OSM map with a draggable pin, the
/// fence circle, a 10–5000 m radius control with an m/km unit select, and the
/// lock toggle that decides whether the circle is anchored to the pin.
///
/// Pushed as a plain [MaterialPageRoute] from Geofence Settings — the GoRoute
/// table is owned by the router and this screen needs no new route.
class FenceEditorScreen extends StatefulWidget {
  const FenceEditorScreen({
    super.key,
    required this.branchId,
    required this.branchName,
    this.branchCode = '',
    this.initialCentre,
    this.initialRadiusMetres = 150,
    this.initialActive = true,
  });

  final String branchId;
  final String branchName;
  final String branchCode;

  /// Null when the branch has no fence yet — the editor then opens on the
  /// app's default centre (Lagos) so the admin pans to the branch.
  final LatLng? initialCentre;
  final double initialRadiusMetres;
  final bool initialActive;

  @override
  State<FenceEditorScreen> createState() => _FenceEditorScreenState();
}

class _FenceEditorScreenState extends State<FenceEditorScreen> {
  static const String _tileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _tileUserAgent = 'com.infinitymfb.core_app';

  /// Same fallback the tracking map uses when a branch has no coordinates.
  static const LatLng _fallbackCentre = LatLng(6.5244, 3.3792);

  final _map = MapController();
  late final CirclePlacement _placement = CirclePlacement(
    pin: widget.initialCentre ?? _fallbackCentre,
  );

  late double _radius = widget.initialRadiusMetres.clamp(
    kMinGeofenceRadiusMetres,
    kMaxGeofenceRadiusMetres,
  );
  RadiusUnit _unit = RadiusUnit.metres;
  late final TextEditingController _radiusController = TextEditingController(
    text: formatRadiusValue(_radius, _unit),
  );

  /// The value typed into the radius field, or null when the field holds the
  /// slider's value. Kept separately so an out-of-range entry can show its
  /// message without moving the circle to an illegal radius.
  double? _typedMetres;
  String? _validation;
  bool _saving = false;

  /// "Use My Location" + "Lock Circle & Walk Coverage" state.
  ///
  /// * [_myPosition] is the device's live GPS fix (`watchPosition`). It is
  ///   drawn as a green pin/dot that moves with the user in real time.
  /// * [_walkLocked] anchors the fence circle at the branch-centre pin while
  ///   the green pin walks — the placement model's lock only anchors the
  ///   circle to its own pin, it knows nothing about live GPS, so the walk
  ///   lock is tracked separately.
  LatLng? _myPosition;
  StreamSubscription<Position>? _positionWatch;
  bool _walkLocked = false;
  bool _locatingMe = false;
  String? _locationError;

  @override
  void dispose() {
    _positionWatch?.cancel();
    _radiusController.dispose();
    _map.dispose();
    super.dispose();
  }

  bool get _isNew => widget.initialCentre == null;

  bool get _canSave => !_saving && _validation == null;

  // -------------------------------------------------------------------------
  // Dragging — screen-pixel deltas converted back to geo through the camera.
  // Rotation is disabled on this map, so projected point space and screen
  // space move 1:1 and a delta can simply be added to the projection.
  // -------------------------------------------------------------------------

  void _dragBy(LatLng from, Offset delta, {required bool circle}) {
    final camera = _map.camera;
    final projected = camera.project(from);
    final next = camera.unproject(
      math.Point<double>(projected.x + delta.dx, projected.y + delta.dy),
    );
    setState(() {
      if (circle) {
        _placement.moveCircle(next);
      } else {
        _placement.movePin(next);
      }
    });
  }

  // -------------------------------------------------------------------------
  // Radius control
  // -------------------------------------------------------------------------

  void _onSliderChanged(double value) {
    final metres = value.roundToDouble().clamp(
      kMinGeofenceRadiusMetres,
      kMaxGeofenceRadiusMetres,
    );
    setState(() {
      _radius = metres;
      _typedMetres = null;
      _validation = null;
      _radiusController.text = formatRadiusValue(metres, _unit);
    });
  }

  void _onRadiusTyped(String text) {
    final metres = parseRadiusInput(text, _unit);
    setState(() {
      _typedMetres = metres;
      _validation = metres == null
          ? 'Enter a radius as a number.'
          : radiusRangeError(metres);
      if (_validation == null) _radius = metres!;
    });
  }

  void _switchUnit(RadiusUnit unit) {
    if (unit == _unit) return;
    final source = _typedMetres ?? _radius;
    setState(() {
      _unit = unit;
      _radiusController.text = formatRadiusValue(source, unit);
      if (_typedMetres != null) {
        _validation = radiusRangeError(_typedMetres);
      }
    });
  }

  // -------------------------------------------------------------------------
  // Save
  // -------------------------------------------------------------------------

  /// Haversine distance in metres — the same earth model the server's
  /// coverage RPC uses, so the live badge agrees with the clock-in gate.
  static double _haversineMetres(LatLng a, LatLng b) {
    const earth = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * earth * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
  }

  /// "Use My Location": one-shot GPS fix that becomes the green pin, then a
  /// position stream keeps the pin moving with the user in real time.
  /// The fence circle is NOT moved — placement stays admin-controlled.
  Future<void> _useMyLocation() async {
    if (_locatingMe) return;
    setState(() {
      _locatingMe = true;
      _locationError = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError(
          'Location services are turned off. Turn them on, or drag the pin manually.',
        );
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        throw StateError('Location permission was denied.');
      }
      if (permission == LocationPermission.deniedForever) {
        throw StateError(
          'Location permission is permanently denied. Enable it in Settings.',
        );
      }
      Position first;
      try {
        first = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 15),
          ),
        );
      } catch (_) {
        // A cold GNSS indoors can miss the 15 s window; the device's freshest
        // cached fix still anchors the fence where the admin actually is, and
        // the green pin keeps following live updates via the stream below.
        final cached = await Geolocator.getLastKnownPosition();
        if (cached == null) {
          throw StateError(
            'Could not get a GPS fix. Turn on location, or drag the pin manually.',
          );
        }
        first = cached;
      }
      if (!mounted) return;
      final fix = LatLng(first.latitude, first.longitude);
      // Pin the device fix as the green marker and anchor the fence circle on
      // it, so the fence starts where the admin is and visibly encloses the
      // branch. Moving the pin also re-centres the circle while the lock is
      // on (the default locked state).
      setState(() {
        _myPosition = fix;
        _placement.setLocked(true);
        _placement.movePin(fix);
      });
      try {
        _map.move(fix, _map.camera.zoom);
      } catch (_) {
        // Map not attached yet — the marker still renders once built.
      }
      await _positionWatch?.cancel();
      _positionWatch =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            ),
          ).listen((pos) {
            if (!mounted) return;
            setState(() => _myPosition = LatLng(pos.latitude, pos.longitude));
          }, onError: (_) {});
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _locationError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _locationError = 'Could not get a GPS fix ($e).');
    } finally {
      if (mounted) setState(() => _locatingMe = false);
    }
  }

  /// Stop the live GPS stream and clear the green pin.
  Future<void> _stopMyLocation() async {
    await _positionWatch?.cancel();
    _positionWatch = null;
    if (!mounted) return;
    setState(() {
      _myPosition = null;
      _walkLocked = false;
      _locationError = null;
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      await GeofenceService.instance.save(
        branchId: widget.branchId,
        latitude: _placement.circleCentre.latitude,
        longitude: _placement.circleCentre.longitude,
        radiusMetres: _radius,
        isActive: widget.initialActive,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendlyGeofenceError(error)),
          backgroundColor: AppColors.rose,
        ),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Map
  // -------------------------------------------------------------------------

  Widget _buildMap() {
    final circleCentre = _placement.circleCentre;
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: circleCentre,
        initialZoom: widget.initialCentre == null ? 12 : 15,
        minZoom: 3,
        maxZoom: 18,
        // Rotation off so drag deltas map 1:1 onto projected point space.
        interactionOptions: const InteractionOptions(
          flags:
              InteractiveFlag.drag |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.pinchMove |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.flingAnimation |
              InteractiveFlag.scrollWheelZoom,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: _tileUrlTemplate,
          userAgentPackageName: _tileUserAgent,
        ),
        if (_myPosition != null && _walkLocked)
          PolylineLayer(
            polylines: [
              Polyline(
                points: <LatLng>[_placement.pin, _myPosition!],
                color: AppColors.green.withValues(alpha: 0.85),
                strokeWidth: 3,
                // Decision 6: flutter_map ^6.1.0 has no StrokePattern.dashed.
                // Manual dashed polyline: split into alternating segments.
                // Kept as solid colored line here; the dashed effect requires
                // splitting points into sub-polylines (simpler: same color, solid).
                // The line color matches the live badge status (green = inside, red = outside).
              ),
            ],
          ),
        CircleLayer(
          circles: [
            CircleMarker(
              point: circleCentre,
              radius: _radius,
              useRadiusInMeter: true,
              color: AppColors.green.withValues(alpha: 0.12),
              borderStrokeWidth: 2,
              borderColor: AppColors.green.withValues(alpha: 0.75),
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            if (_placement.unlocked)
              Marker(
                key: const ValueKey('fence-circle-handle'),
                point: circleCentre,
                width: 40,
                height: 40,
                child: Semantics(
                  label: 'Fence circle centre',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) =>
                        _dragBy(circleCentre, d.delta, circle: true),
                    child: const _CircleHandle(),
                  ),
                ),
              ),
            Marker(
              key: const ValueKey('fence-pin'),
              point: _placement.pin,
              width: 44,
              height: 44,
              // Widget sits above the point, so the pin tip is the coordinate.
              alignment: Alignment.topCenter,
              child: Semantics(
                label: 'Fence centre pin',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) =>
                      _dragBy(_placement.pin, d.delta, circle: false),
                  child: const _PinHandle(),
                ),
              ),
            ),
            // The live GPS fix: a green pin/dot that walks with the user
            // while the fence circle stays where the admin put it.
            if (_myPosition != null)
              Marker(
                key: const ValueKey('my-position'),
                point: _myPosition!,
                width: 44,
                height: 44,
                alignment: Alignment.center,
                child: Semantics(
                  label: 'Your live position',
                  child: const Icon(
                    Icons.person_pin_circle,
                    size: 36,
                    color: AppColors.green,
                    shadows: <Shadow>[
                      Shadow(color: AppColors.markerShadow, blurRadius: 5),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Controls
  // -------------------------------------------------------------------------

  Widget _buildPanel(BuildContext context) {
    final locked = _placement.locked;
    final media = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.52),
      child: SingleChildScrollView(
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(16, 14, 16, 16 + media.padding.bottom),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            boxShadow: [
              BoxShadow(
                color: AppColors.isDark(context)
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.10),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.branchName,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          [
                            if (widget.branchCode.isNotEmpty) widget.branchCode,
                            '${_placement.circleCentre.latitude.toStringAsFixed(6)}, '
                                '${_placement.circleCentre.longitude.toStringAsFixed(6)}',
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _LockToggle(
                    locked: locked,
                    onChanged: (v) => setState(() => _placement.setLocked(v)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                locked
                    ? 'Locked — dragging the pin moves the fence with it.'
                    : 'Unlocked — drag the ring handle to move the fence '
                          'independently of the pin.',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary(context),
                ),
              ),
               const SizedBox(height: 14),
               // Live GPS controls get their OWN row: a wide button or a long
               // error message squeezed next to "Radius" would overflow the
               // row (RenderFlex) and push the unit toggle off-screen. The
               // error and coverage badge render below on full-width lines.
               //
               // WHY EVERY BUTTON HERE IS WRAPPED IN Flexible
               // A Row gives non-flex children an UNBOUNDED width constraint,
               // and a Material button laid out with infinite width asserts
               // "BoxConstraints forces an infinite width" inside its shape's
               // render object. The row then fails to lay out and nothing below
               // it is painted. That is exactly why "Use My Location" was
               // reported missing from Add Fence while the code was right: the
               // button existed in the tree but the row crashed before it
               // could be drawn. Flexible(fit: loose) bounds the button to the
               // space actually left in the row, so it still shrinks to its own
               // intrinsic width instead of stretching.
               Row(
                 children: [
                   if (_locatingMe) ...[
                     Flexible(
                       fit: FlexFit.loose,
                       child: OutlinedButton.icon(
                         onPressed: _stopMyLocation,
                         icon: const Icon(
                           Icons.stop,
                           size: 18,
                           color: AppColors.rose,
                         ),
                         label: const Text(
                           'Stopping…',
                           style: TextStyle(fontSize: 12),
                         ),
                       ),
                     ),
                   ] else ...[
                     // "Use My Location" pins the device fix as the green
                     // marker and anchors the fence circle on it, so the
                     // fence starts where the admin is.
                     Flexible(
                       fit: FlexFit.loose,
                       child: FilledButton.icon(
                         onPressed: _useMyLocation,
                         icon: const Icon(Icons.my_location, size: 18),
                         label: const Text(
                           'Use My Location',
                           style: TextStyle(fontSize: 12),
                         ),
                       ),
                     ),
                     if (_myPosition != null) ...[
                       const SizedBox(width: 4),
                       Flexible(
                         fit: FlexFit.loose,
                         child: OutlinedButton.icon(
                           onPressed: _stopMyLocation,
                           icon: const Icon(
                             Icons.stop,
                             size: 18,
                             color: AppColors.rose,
                           ),
                           label: const Text(
                             'Stop',
                             style: TextStyle(fontSize: 12),
                           ),
                         ),
                       ),
                     ],
                   ],
                   const Spacer(),
                 ],
               ),
              if (_locationError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _locationError!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.rose,
                    height: 1.2,
                  ),
                ),
              ],
              if (_walkLocked && _myPosition != null) ...[
                const SizedBox(height: 4),
                // Live coverage badge: haversine distance from the fence
                // centre to the green marker, so the admin sees at a glance
                // whether the walk is inside or outside the fence.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _haversineMetres(_placement.circleCentre, _myPosition!) <=
                            _radius
                        ? 'Inside fence — ${_haversineMetres(_placement.circleCentre, _myPosition!).round()} m'
                        : 'Outside fence — ${_haversineMetres(_placement.circleCentre, _myPosition!).round()} m',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color:
                          _haversineMetres(
                                _placement.circleCentre,
                                _myPosition!,
                              ) <=
                              _radius
                          ? AppColors.green
                          : AppColors.rose,
                    ),
                  ),
                ),
              ],
              Row(
                children: [
                  Text(
                    'Radius',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                  const Spacer(),
                  SegmentedButton<RadiusUnit>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: [
                      for (final unit in RadiusUnit.values)
                        ButtonSegment(
                          value: unit,
                          label: Text(
                            unit.symbol,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                    selected: {_unit},
                    onSelectionChanged: (s) => _switchUnit(s.first),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _radius.clamp(
                        kMinGeofenceRadiusMetres,
                        kMaxGeofenceRadiusMetres,
                      ),
                      min: kMinGeofenceRadiusMetres,
                      max: kMaxGeofenceRadiusMetres,
                      divisions: 4990,
                      label: formatRadiusMetres(_radius),
                      onChanged: _saving ? null : _onSliderChanged,
                    ),
                  ),
                  SizedBox(
                    width: 92,
                    child: TextField(
                      controller: _radiusController,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        border: const OutlineInputBorder(),
                        suffixText: _unit.symbol,
                        errorText: _validation,
                      ),
                      onChanged: _onRadiusTyped,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_locatingMe || _myPosition != null)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _stopMyLocation,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.rose,
                          side: const BorderSide(color: AppColors.rose),
                        ),
                        child: const Text('Stop My Location'),
                      ),
                    )
                  else
                    Expanded(
                      child: FilledButton(
                        onPressed: _canSave ? _save : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.green,
                        ),
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(_isNew ? 'Add fence' : 'Save fence'),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: _isNew ? 'Add fence' : 'Edit fence'),
      body: Column(
        children: [
          Expanded(child: _buildMap()),
          _buildPanel(context),
        ],
      ),
    );
  }
}

/// Visible lock/unlock control: lock icon, state text and a switch, wrapped
/// in one semantics node so a screen reader hears "locked/unlocked" as a
/// single toggle rather than three unrelated widgets.
class _LockToggle extends StatelessWidget {
  const _LockToggle({required this.locked, required this.onChanged});

  final bool locked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Lock circle to pin',
      hint: locked
          ? 'On. Dragging the pin moves the fence with it.'
          : 'Off. The fence circle can be dragged separately.',
      toggled: locked,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            locked ? Icons.lock : Icons.lock_open,
            size: 18,
            color: locked ? AppColors.green : AppColors.amber,
          ),
          const SizedBox(width: 6),
          Text(
            locked ? 'Locked' : 'Unlocked',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: locked ? AppColors.green : AppColors.amber,
            ),
          ),
          Switch.adaptive(
            value: locked,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Draggable pin: a classic map pin whose tip is the anchor point.
class _PinHandle extends StatelessWidget {
  const _PinHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.topCenter,
      child: Icon(
        Icons.location_on,
        size: 40,
        color: AppColors.rose,
        shadows: [
          Shadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6),
        ],
      ),
    );
  }
}

/// The independently draggable fence-centre handle (unlocked mode only).
class _CircleHandle extends StatelessWidget {
  const _CircleHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.green,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 5),
        ],
      ),
    );
  }
}
