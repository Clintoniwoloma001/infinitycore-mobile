import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';
import 'geofence_models.dart';
import 'geofence_service.dart';

/// Interactive "Test My Coverage" screen: pick a branch fence, drop a test
/// point (device GPS, a map tap, or typed coordinates) and ask the server
/// whether that point is inside the branch's fence.
///
/// The verdict — including the distance — always comes from
/// `check_is_within_geofence`; nothing is computed on the client, because the
/// point of the screen is to show what the clock-in gate will decide.
///
/// The route is reachable by any signed-in user (the auth gate only guards
/// the exact `/geofences` path), which is intended: this screen is the
/// employee-facing self-service check. Fence geometry therefore comes from
/// [GeofenceService.listForTester], which falls back to the branches table
/// when the admin RPC refuses.
class GeofenceCoverageTesterScreen extends StatefulWidget {
  const GeofenceCoverageTesterScreen({super.key});

  /// Which branch the screen should open on. The router builder ignores
  /// `state.extra` (it is `builder: (_, _)`), so callers prime this static
  /// before pushing the route; the value is consumed once and cleared.
  static String? _primedBranchId;

  static void primeBranchId(String? branchId) => _primedBranchId = branchId;

  static String? takePrimedBranchId() {
    final value = _primedBranchId;
    _primedBranchId = null;
    return value;
  }

  @override
  State<GeofenceCoverageTesterScreen> createState() =>
      _GeofenceCoverageTesterScreenState();
}

class _GeofenceCoverageTesterScreenState
    extends State<GeofenceCoverageTesterScreen>
    with SingleTickerProviderStateMixin {
  static const String _tileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _tileUserAgent = 'com.infinitymfb.core_app';

  /// Same fallback the tracking map uses when a branch has no coordinates.
  static const LatLng _fallbackCentre = LatLng(6.5244, 3.3792);

  final _service = GeofenceService.instance;
  final _map = MapController();
  final _latitudeController = TextEditingController();
  final _longitudeController = TextEditingController();

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  List<BranchGeofence> _fences = const [];
  BranchGeofence? _selected;
  bool _loading = true;
  String? _loadError;

  /// Where the test point came from — only a label, the point itself is what
  /// is in the coordinate fields.
  String _pointSource = 'the map';

  bool _locating = false;
  String? _locationError;

  bool _checking = false;
  CoverageCheck? _result;
  String? _checkError;
  String? _coordsError;

  @override
  void initState() {
    super.initState();
    _latitudeController.addListener(_onCoordsEdited);
    _longitudeController.addListener(_onCoordsEdited);
    _load();
  }

  @override
  void dispose() {
    _latitudeController.removeListener(_onCoordsEdited);
    _longitudeController.removeListener(_onCoordsEdited);
    _latitudeController.dispose();
    _longitudeController.dispose();
    _pulse.dispose();
    _map.dispose();
    super.dispose();
  }

  // ---- Loading -------------------------------------------------------------

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final fences = await _service.listForTester();
      if (!mounted) return;
      final primedId = GeofenceCoverageTesterScreen.takePrimedBranchId();
      BranchGeofence? selected;
      if (primedId != null) {
        for (final fence in fences) {
          if (fence.branchId == primedId) selected = fence;
        }
      }
      selected ??= fences.isEmpty ? null : fences.first;
      setState(() {
        _fences = fences;
        _selected = selected;
        _result = null;
        _checkError = null;
      });
      if (selected != null) _moveTo(selected);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = friendlyGeofenceError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Move the camera to [fence]. Deferred by a frame because the map
  /// controller only exists once the map widget has been built.
  void _moveTo(BranchGeofence fence) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        _map.move(fence.centre, 15);
      } catch (_) {
        // Map not attached yet — the initial camera already aims at the
        // fallback, and the selector tap will move it later.
      }
    });
  }

  // ---- Test point ----------------------------------------------------------

  void _onCoordsEdited() {
    if (_result != null || _checkError != null) {
      setState(() {
        _result = null;
        _checkError = null;
      });
    }
  }

  LatLng? get _typedPoint {
    final lat = double.tryParse(_latitudeController.text.trim());
    final lng = double.tryParse(_longitudeController.text.trim());
    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return LatLng(lat, lng);
  }

  void _writePoint(LatLng point, {required String source}) {
    setState(() {
      _latitudeController.text = point.latitude.toStringAsFixed(6);
      _longitudeController.text = point.longitude.toStringAsFixed(6);
      _pointSource = source;
      _locationError = null;
      _coordsError = null;
      _result = null;
      _checkError = null;
    });
  }

  Future<void> _locateMe() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final fix = await _service.deviceFix();
      if (!mounted) return;
      _writePoint(fix, source: 'your GPS');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _locationError = error is StateError
            ? '${error.message}'
            : friendlyGeofenceError(error);
      });
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  // ---- The check -----------------------------------------------------------

  Future<void> _runCheck() async {
    final fence = _selected;
    if (fence == null) return;

    final point = _typedPoint;
    if (point == null) {
      setState(() {
        _coordsError =
            'Enter a latitude and longitude, or tap the map to drop a point.';
      });
      return;
    }
    setState(() {
      _checking = true;
      _checkError = null;
      _coordsError = null;
    });
    try {
      final result = await _service.checkCoverage(
        latitude: point.latitude,
        longitude: point.longitude,
        branchId: fence.branchId,
      );
      if (!mounted) return;
      setState(() => _result = result);
      if (result.within) _showSuccessDialog(fence, result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _checkError = friendlyGeofenceError(error));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Full-screen, animated "you are covered" confirmation. Scale + fade in
  /// via the dialog transition builder — no extra animation code needed.
  Future<void> _showSuccessDialog(
    BranchGeofence fence,
    CoverageCheck result,
  ) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: const Color(0x66000000),
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (ctx, _, _) => _CoverageSuccessDialog(
        fence: fence,
        result: result,
      ),
      transitionBuilder: (ctx, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutBack,
            reverseCurve: Curves.easeInCubic,
          ),
          child: child,
        ),
      ),
    );
  }

  // ---- Rendering -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: 'Test My Coverage'),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _fences.isEmpty) {
      return const PageLoadingView(label: 'Loading fences…');
    }
    if (_loadError != null && _fences.isEmpty) {
      return PageErrorView(message: _loadError!, onRetry: _load);
    }
    if (_fences.isEmpty) {
      return const PageEmptyView(
        title: 'No fences to test yet',
        description:
            'Add a fence from Geofence Settings first — the tester shows '
            'whether your position is inside an existing branch fence.',
      );
    }

    return Column(
      children: [
        _buildSelector(context),
        Expanded(child: _buildMap(context)),
        _buildPanel(context),
      ],
    );
  }

  Widget _buildSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<BranchGeofence>(
              value: _selected,
              isDense: true,
              decoration: const InputDecoration(
                labelText: 'Branch fence',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary(context),
              ),
              items: [
                for (final fence in _fences)
                  DropdownMenuItem<BranchGeofence>(
                    value: fence,
                    child: Text(
                      fence.branchName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (fence) {
                if (fence == null) return;
                setState(() {
                  _selected = fence;
                  _result = null;
                  _checkError = null;
                });
                _moveTo(fence);
              },
            ),
          ),
          IconButton(
            tooltip: 'Refresh fences',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
    );
  }

  Widget _buildMap(BuildContext context) {
    final fence = _selected;
    final point = _typedPoint;

    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: fence?.centre ?? _fallbackCentre,
        initialZoom: 15,
        // Rotation off so what you see is what the server measures against.
        interactionOptions: const InteractionOptions(
          flags:
              InteractiveFlag.drag |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.pinchMove |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.flingAnimation,
        ),
        onTap: (_, tapped) => _writePoint(tapped, source: 'the map'),
      ),
      children: [
        TileLayer(
          urlTemplate: _tileUrlTemplate,
          userAgentPackageName: _tileUserAgent,
        ),
        if (fence != null)
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => CircleLayer(circles: _circles(fence)),
          ),
        if (point != null)
          MarkerLayer(
            markers: [
              Marker(
                key: const ValueKey('tester-point'),
                point: point,
                width: 44,
                height: 44,
                alignment: Alignment.center,
                child: Semantics(
                  label: 'Test point at ${point.latitude.toStringAsFixed(4)}, '
                      '${point.longitude.toStringAsFixed(4)}',
                  child: const Icon(
                    Icons.location_pin,
                    size: 34,
                    color: AppColors.amber,
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// The fence itself plus two radar ripples pulsing out of its centre,
  /// driven by [_pulse].
  List<CircleMarker> _circles(BranchGeofence fence) {
    final t = _pulse.value;
    List<CircleMarker> ripples(double phase) {
      final p = (phase % 1.0);
      return [
        CircleMarker(
          point: fence.centre,
          radius: fence.radiusMetres * (0.4 + 0.6 * p),
          useRadiusInMeter: true,
          color: AppColors.blue.withValues(alpha: 0.22 * (1 - p)),
        ),
      ];
    }

    return [
      CircleMarker(
        point: fence.centre,
        radius: fence.radiusMetres,
        useRadiusInMeter: true,
        color: AppColors.green.withValues(alpha: 0.12),
        borderStrokeWidth: 2,
        borderColor: AppColors.green.withValues(alpha: 0.75),
      ),
      ...ripples(t),
      ...ripples((t + 0.5) % 1.0),
    ];
  }

  Widget _buildPanel(BuildContext context) {
    final fence = _selected;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        border: Border(top: BorderSide(color: AppColors.border(context))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _latitudeController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Latitude',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  controller: _longitudeController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Longitude',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                label: 'Use my device GPS location',
                button: true,
                child: IconButton.filledTonal(
                  tooltip: 'Use my GPS location',
                  onPressed: _locating ? null : _locateMe,
                  icon: _locating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location, size: 20),
                ),
              ),
            ],
          ),
          if (_coordsError != null || _locationError != null) ...[
            const SizedBox(height: 6),
            Text(
              _coordsError ?? _locationError!,
              style: const TextStyle(fontSize: 12, color: AppColors.rose),
            ),
          ] else ...[
            const SizedBox(height: 6),
            Text(
              'Test point from $_pointSource.',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
          if (_result != null || _checkError != null) ...[
            const SizedBox(height: 8),
            if (_checkError != null)
              _VerdictCard(
                tone: AppColors.rose,
                icon: Icons.error_outline,
                title: 'Could not run the check',
                body: _checkError!,
              )
            else
              _buildVerdict(fence!),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _checking || fence == null ? null : _runCheck,
              icon: _checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.radar, size: 18),
              label: Text(
                _checking ? 'Checking…' : 'Test my coverage',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The verdict card. Every number here is the server's answer.
  Widget _buildVerdict(BranchGeofence fence) {
    final result = _result!;
    if (!result.hasGeofence) {
      return _VerdictCard(
        tone: AppColors.amber,
        icon: Icons.info_outline,
        title: 'No fence for this branch',
        body: '${fence.branchName} has no active fence, so clock-ins are not '
            'checked against a location.',
      );
    }
    if (result.within) {
      return _VerdictCard(
        tone: AppColors.green,
        icon: Icons.check_circle_outline,
        title: 'Inside coverage',
        body: 'The server measured ${result.distanceLabel} from the centre of '
            '${fence.branchName} — inside the ${fence.radiusLabel} fence.',
      );
    }
    return _VerdictCard(
      tone: AppColors.rose,
      icon: Icons.location_off_outlined,
      title: 'Outside coverage',
      body: 'The server measured ${result.distanceLabel} from the centre of '
          '${fence.branchName} — ${result.outsideLabel} beyond the '
          '${fence.radiusLabel} fence.',
    );
  }
}

// -----------------------------------------------------------------------------

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({
    required this.tone,
    required this.icon,
    required this.title,
    required this.body,
  });

  final Color tone;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: tone),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: tone,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverageSuccessDialog extends StatelessWidget {
  const _CoverageSuccessDialog({required this.fence, required this.result});

  final BranchGeofence fence;
  final CoverageCheck result;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Dialog(
          backgroundColor: AppColors.surface(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.6, end: 1),
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.elasticOut,
                  builder: (context, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      color: AppColors.green,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 38,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Inside coverage',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary(context),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'The server measured you ${result.distanceLabel} from the '
                  'centre of ${fence.branchName}, inside its '
                  '${fence.radiusLabel} fence. Clock-in will accept this '
                  'location.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary(context),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
