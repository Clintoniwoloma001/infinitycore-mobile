import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import 'route_playback.dart';
import 'tracking_service.dart';

/// Full-screen OpenStreetMap view of one tracked employee: live position,
/// the day's breadcrumb route, and the movement-delay analysis.
///
/// WHY OSM AND NOT GOOGLE: `flutter_map` is pure Dart over public tiles, so
/// this screen needs no API key, no billing account and no native plugin —
/// which means it can ship in a Shorebird patch instead of forcing a store
/// release. Google renders live traffic, but only for the current moment; it
/// cannot answer "what was the road like at 14:20 on the 12th", which is the
/// question this screen exists to answer.
///
/// TILE PROVIDER NOTE: tile.openstreetmap.org is the OSMF public tile service.
/// Their usage policy forbids heavy or commercial production use. That is
/// adequate at staff scale for this release, but a bank-wide rollout should
/// move to a contracted provider (MapTiler/Protomaps) by changing
/// [_tileUrlTemplate] alone — no other code depends on the provider.
class StaffLocationMapScreen extends StatefulWidget {
  const StaffLocationMapScreen({
    super.key,
    required this.employee,
    this.initialDate,
  });

  final TrackedEmployee employee;
  final DateTime? initialDate;

  @override
  State<StaffLocationMapScreen> createState() => _StaffLocationMapScreenState();
}

/// Preset shift windows offered by the time filter.
enum _ShiftWindow {
  all('Whole day'),
  morning('Morning 08:00–12:00'),
  afternoon('Afternoon 12:00–17:00');

  const _ShiftWindow(this.label);
  final String label;
}

class _StaffLocationMapScreenState extends State<StaffLocationMapScreen> {
  static const String _tileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _tileUserAgent = 'com.infinitymfb.core_app';

  final _service = TrackingService.instance;
  final _map = MapController();

  late DateTime _date;
  _ShiftWindow _window = _ShiftWindow.all;

  /// Playback head, an index into [_filteredPoints]. -1 shows the whole day.
  int _playhead = -1;

  bool _loading = true;
  String? _error;
  TrackingDay? _day;
  RouteAnalysis? _analysis;
  List<TrackingPoint> _routePoints = const [];
  List<TrackingPoint> _filteredPoints = const [];

  TrackedEmployee get _employee => widget.employee;

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate ?? DateTime.now();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final day = await _service.history(_employee.id, _date);
      if (!mounted) return;
      setState(() {
        _day = day;
        _routePoints = day.mappablePoints;
        _applyWindow();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _day = null;
        _routePoints = const [];
        _filteredPoints = const [];
        _analysis = null;
      });
    }
  }

  /// Recomputes the visible slice for the chosen shift window.
  ///
  /// Filtering happens on the already-ordered pings, and the analysis is
  /// rebuilt from the FILTERED set so the speed maths only ever sees points
  /// inside the window. Otherwise the gap across a window boundary would be
  /// measured as one enormous, meaningless segment.
  void _applyWindow() {
    if (_window == _ShiftWindow.all) {
      _filteredPoints = _routePoints;
      _analysis = RouteAnalysis.build(_routePoints);
      _playhead = -1;
      return;
    }
    final startHour = _window == _ShiftWindow.morning ? 8 : 12;
    final slice = _routePoints
        .where((p) {
          final at = p.recordedAt;
          if (at == null) return false;
          return at.hour >= startHour && at.hour < startHour + 4;
        })
        .toList(growable: false);
    _filteredPoints = slice;
    _analysis = RouteAnalysis.build(slice);
    _playhead = -1;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now(),
      helpText: 'History for which day?',
    );
    if (picked == null || !mounted) return;
    setState(() => _date = picked);
    await _load();
  }

  void _setYesterday() {
    final now = DateTime.now();
    final y = now.subtract(const Duration(days: 1));
    setState(() => _date = DateTime(y.year, y.month, y.day));
    _load();
  }

  /// Moves the playback head and centres the map on that waypoint.
  void _stepTo(int index) {
    if (index < 0 || index >= _filteredPoints.length) return;
    final p = _filteredPoints[index];
    setState(() => _playhead = index);
    _map.move(LatLng(p.latitude!, p.longitude!), _map.camera.zoom);
  }

  TrackingPoint? get _playheadPoint =>
      (_playhead >= 0 && _playhead < _filteredPoints.length)
      ? _filteredPoints[_playhead]
      : null;

  String _timeOf(DateTime? at) =>
      at == null ? '—' : DateFormat('HH:mm').format(at.toLocal());

  LatLng? _latlng(TrackingPoint p) =>
      p.hasCoordinates ? LatLng(p.latitude!, p.longitude!) : null;

  /// Colour for one movement segment, per the 1.5 / 4.5 m/s bands.
  ///
  /// Free-flowing uses the brand green rather than a traffic-light green so the
  /// map reads as one system. A slow-and-sustained segment is rose; a brief
  /// slow stretch stays amber, because most of those are junctions, not
  /// congestion.
  Color _segmentColor(RouteSegment s) {
    if (s.movement == MovementClass.freeFlowing) return AppColors.accentGreen;
    if (s.movement == MovementClass.moderate) return AppColors.amber;
    return s.isPlausibleTrafficHold ? AppColors.rose : AppColors.amber;
  }

  Widget _buildMap() {
    final points = _filteredPoints;

    // Drawn per segment so each can carry its own colour.
    final segmentLines = (_analysis?.segments ?? const <RouteSegment>[])
        .where((s) => _latlng(s.from) != null && _latlng(s.to) != null)
        .map(
          (s) => Polyline(
            points: [_latlng(s.from)!, _latlng(s.to)!],
            color: _segmentColor(s),
            strokeWidth: 5,
          ),
        )
        .toList(growable: false);

    // Accuracy circles, only for waypoints that reported a radius.
    final accuracyCircles = points
        .where(
          (p) => p.accuracy != null && p.accuracy! > 0 && _latlng(p) != null,
        )
        .map(
          (p) => CircleMarker(
            point: _latlng(p)!,
            radius: p.accuracy!,
            useRadiusInMeter: true,
            color: AppColors.blue.withValues(alpha: 0.10),
            borderColor: AppColors.blue.withValues(alpha: 0.35),
            borderStrokeWidth: 1,
          ),
        )
        .toList(growable: false);

    final markers = <Marker>[];
    for (var i = 0; i < points.length; i++) {
      final ll = _latlng(points[i]);
      if (ll == null) continue;
      markers.add(
        Marker(
          point: ll,
          width: 30,
          height: 30,
          child: _WaypointPin(
            number: i + 1,
            active: i == _playhead,
            inside: points[i].insideGeofence,
          ),
        ),
      );
    }

    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: points.isNotEmpty
            ? _latlng(points.first)!
            : const LatLng(6.5244, 3.3792),
        initialZoom: 15,
        minZoom: 3,
        maxZoom: 18,
        onTap: (_, _) => setState(() => _playhead = -1),
      ),
      children: [
        TileLayer(
          urlTemplate: _tileUrlTemplate,
          userAgentPackageName: _tileUserAgent,
        ),
        if (accuracyCircles.isNotEmpty) CircleLayer(circles: accuracyCircles),
        if (segmentLines.isNotEmpty) PolylineLayer(polylines: segmentLines),
        if (markers.isNotEmpty) MarkerLayer(markers: markers),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _employee.name.isEmpty ? 'Location history' : _employee.name,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const PageLoadingView();

    if (_error != null) {
      return PageErrorView(
        message: "Unable to load this day's history.",
        detail: _error,
        onRetry: _load,
      );
    }

    if (_routePoints.isEmpty) {
      return PageEmptyView(
        title: 'No route recorded',
        description:
            'No usable location pings were recorded for '
            '${DateFormat('d MMM yyyy').format(_date)}. Points appear only '
            'while the app is open and sharing is on.',
      );
    }

    return Column(
      children: [
        _controls(),
        Expanded(child: _buildMap()),
        _playbackBar(),
        _detailSheet(),
      ],
    );
  }

  /// Date and shift-window filters.
  Widget _controls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today, size: 16),
              label: Text(DateFormat('d MMM yyyy').format(_date)),
              onPressed: _pickDate,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.outlined(
            tooltip: 'Yesterday',
            icon: const Icon(Icons.history, size: 18),
            onPressed: _setYesterday,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<_ShiftWindow>(
              initialValue: _window,
              isDense: true,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                border: OutlineInputBorder(),
              ),
              items: _ShiftWindow.values
                  .map(
                    (w) => DropdownMenuItem(
                      value: w,
                      child: Text(
                        w.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (w) {
                if (w == null) return;
                setState(() => _window = w);
                _applyWindow();
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Breadcrumb playback: stepping the slider walks the numbered waypoints and
  /// recentres the map on each one.
  Widget _playbackBar() {
    final points = _filteredPoints;
    if (points.isEmpty) return const SizedBox.shrink();
    final head = _playhead < 0 ? points.length - 1 : _playhead;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Row(
        children: [
          IconButton(
            tooltip: _playhead < 0 ? 'Replay from the start' : 'Previous point',
            icon: Icon(
              _playhead < 0 ? Icons.replay : Icons.skip_previous,
              size: 20,
            ),
            onPressed: () => _stepTo(_playhead < 0 ? 0 : _playhead - 1),
          ),
          Expanded(
            child: Slider(
              value: head.toDouble(),
              min: 0,
              max: (points.length - 1).toDouble().clamp(0, double.infinity),
              onChanged: (v) => _stepTo(v.round()),
            ),
          ),
          Text(
            '${head + 1}/${points.length}',
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// The detail sheet: live context, the selected waypoint, and the movement
  /// summary for the window.
  Widget _detailSheet() {
    final a = _analysis;
    final selected =
        _playheadPoint ??
        (_filteredPoints.isNotEmpty ? _filteredPoints.last : null);
    final flagged = a?.flagged ?? const <RouteSegment>[];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          // Dark mode needs a lighter shadow than light mode: the surface is
          // already dark, so a light-mode-strength shadow is invisible.
          BoxShadow(
            color: AppColors.isDark(context)
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _liveHeader(selected),
            const SizedBox(height: 10),
            if (a != null) _movementSummary(a, flagged),
            if ((_day?.unplaceableCount ?? 0) > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${_day!.unplaceableCount} ping(s) had no usable coordinates '
                'and are excluded from the route.',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary(context),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _liveHeader(TrackingPoint? p) {
    final last = _employee.minutesAgo;
    final net = p == null || p.networkType.isEmpty || p.networkType == 'unknown'
        ? null
        : p.networkType.toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p == null ? _employee.place : '${_timeOf(p.recordedAt)} · ${p.place}',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        const SizedBox(height: 4),
        Text(
          [
            if (_employee.branchName.isNotEmpty) _employee.branchName,
            if (p?.batteryLevel != null) 'Battery ${p!.batteryLevel}%',
            if (net != null) 'Network $net',
            if (p?.accuracy != null) '±${p!.accuracy!.round()} m',
            if (last != null) 'Live ping $last min ago',
          ].join(' · '),
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary(context),
          ),
        ),
        if (p?.evidenceNote != null) ...[
          const SizedBox(height: 4),
          Text(
            p!.evidenceNote!,
            style: const TextStyle(fontSize: 11, color: AppColors.amber),
          ),
        ],
      ],
    );
  }

  Widget _movementSummary(RouteAnalysis a, List<RouteSegment> flagged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Movement · ${a.pointsUsed} pings · '
          '${(a.totalDistanceMeters / 1000).toStringAsFixed(2)} km · '
          '${minutesLabel(a.elapsed)}',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        if (a.zeroDurationSegments > 0)
          Text(
            '${a.zeroDurationSegments} duplicate-timestamp ping(s) skipped.',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textTertiary(context),
            ),
          ),
        const SizedBox(height: 8),
        if (flagged.isEmpty)
          Text(
            'No sustained low-speed holds in this window.',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary(context),
            ),
          )
        else ...[
          Text(
            '${flagged.length} sustained slow segment(s) for review:',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.rose,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Low speed is not proof of congestion — a parked vehicle, a '
            'client visit or a meeting leaves the same trace. Confirm before '
            'acting on this.',
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: AppColors.textTertiary(context),
            ),
          ),
          const SizedBox(height: 6),
          for (final s in flagged.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '• ${_timeOf(s.from.recordedAt)}–${_timeOf(s.to.recordedAt)} · '
                '${minutesLabel(s.duration)} · '
                '${(s.speedMs * 3.6).toStringAsFixed(1)} km/h'
                '${s.hasReliableFix ? '' : ' (low GPS confidence)'}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ],
    );
  }
}

/// Numbered breadcrumb pin. The number is the order of the ping, so the
/// sequence is readable without tapping anything.
class _WaypointPin extends StatelessWidget {
  const _WaypointPin({
    required this.number,
    required this.active,
    required this.inside,
  });

  final int number;
  final bool active;
  final bool inside;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: inside ? AppColors.accentGreen : AppColors.blue,
        border: Border.all(color: Colors.white, width: active ? 3 : 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.26),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$number',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: active ? 13 : 11,
        ),
      ),
    );
  }
}
