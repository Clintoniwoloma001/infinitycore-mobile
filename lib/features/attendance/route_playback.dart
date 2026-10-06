/// Breadcrumb playback and the movement-delay engine for one employee's day.
///
/// DESIGN NOTE — this replaces the Google Routes API entirely, and the swap is
/// not only a licensing decision. A Routes call needs a server-side key, a
/// billed request per playback, and a network round trip that fails offline.
/// Speed-derived classification runs on the pings we already hold, costs
/// nothing, works with no signal, and ships as pure Dart.
///
/// HONESTY LIMIT — read before changing the thresholds:
/// Low ground speed is CORRELATED WITH congestion but does not prove it. A
/// staff member parked outside a client's office, in a meeting, or at a
/// traffic light produces exactly the same trace. So a heavy segment is
/// reported as a REVIEW FLAG that a human confirms or dismisses, never as a
/// verified fact about the road.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'tracking_service.dart';

/// Below this ground speed (m/s) a segment is "slow". 1.5 m/s = 5.4 km/h.
const double kSlowSpeedMs = 1.5;

/// Above this ground speed (m/s) a segment is "free flowing". 4.5 m/s = 16.2 km/h.
const double kFreeFlowSpeedMs = 4.5;

/// A slow segment only becomes a congestion FLAG after it has been held this
/// long. Shorter slow stretches are ordinary city driving, junction stops and
/// reversing, and flagging them would bury the real ones in noise.
const Duration kHeldDuration = Duration(minutes: 10);

/// How the movement along one segment is classified.
enum MovementClass {
  /// Faster than [kFreeFlowSpeedMs] — genuinely moving along a road.
  freeFlowing,

  /// Between the two thresholds.
  moderate,

  /// Below [kSlowSpeedMs].
  slow,
}

/// One leg of the day's movement, between two consecutive usable pings.
class RouteSegment {
  const RouteSegment({
    required this.from,
    required this.to,
    required this.distanceMeters,
    required this.duration,
    required this.speedMs,
    required this.movement,
  });

  final TrackingPoint from;
  final TrackingPoint to;
  final double distanceMeters;
  final Duration duration;

  /// Δdistance / Δtime, in metres per second.
  final double speedMs;
  final MovementClass movement;

  /// True when this segment is slow AND sustained long enough to be worth a
  /// human's attention. This is the flag the UI highlights — never a verdict.
  bool get isPlausibleTrafficHold =>
      movement == MovementClass.slow && duration >= kHeldDuration;

  /// Worst GPS accuracy of the two endpoints, in metres. A "stopped" segment
  /// measured at ±120 m proves very little, so this is carried to the UI and
  /// the caveat is shown rather than hidden.
  double? get worstAccuracy {
    final a = from.accuracy;
    final b = to.accuracy;
    if (a == null && b == null) return null;
    if (a == null) return b;
    if (b == null) return a;
    return math.max(a, b);
  }

  /// Whether the evidence is strong enough to draw a conclusion at all.
  ///
  /// A fix with a reported accuracy worse than 100 m cannot distinguish
  /// "stationary" from "drifted 90 m while stationary", so such a segment is
  /// excluded from the flag.
  bool get hasReliableFix {
    final acc = worstAccuracy;
    return acc == null || acc <= 100;
  }

  /// Combined confidence: a sustained, slow, well-measured segment.
  bool get isStrongFlag => isPlausibleTrafficHold && hasReliableFix;

  String get movementLabel {
    if (movement == MovementClass.freeFlowing) return 'Free-flowing movement';
    if (movement == MovementClass.moderate) return 'Moderate movement';
    return duration >= kHeldDuration
        ? 'Slow movement held over ${minutesLabel(duration)}'
        : 'Brief slow movement';
  }
}

/// "1 h 5 min" / "42 min" — used by both the segment and the summary copy.
String minutesLabel(Duration d) {
  final mins = d.inMinutes;
  if (mins < 60) return '$mins min';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// One day's movement, split into classified segments.
class RouteAnalysis {
  const RouteAnalysis({
    required this.segments,
    required this.pointsUsed,
    required this.pointsSkipped,
    this.zeroDurationSegments = 0,
  });

  /// Empty result for a day with fewer than two timed, placeable pings.
  ///
  /// [used] is carried through so a day holding one valid ping still reports
  /// "1 point" rather than a misleading zero.
  factory RouteAnalysis.empty(int skipped, {int used = 0}) => RouteAnalysis(
    segments: const [],
    pointsUsed: used,
    pointsSkipped: skipped,
  );

  final List<RouteSegment> segments;
  final int pointsUsed;

  /// Pings that were recorded but had no usable coordinate, so they cannot be
  /// placed on the map and are excluded from the speed maths.
  final int pointsSkipped;

  /// Segments discarded because two pings shared a timestamp, which would
  /// otherwise divide by zero and report an infinite speed.
  final int zeroDurationSegments;

  bool get isEmpty => segments.isEmpty;

  /// Segments worth a human's attention, on the strongest evidence first.
  List<RouteSegment> get flagged =>
      segments.where((s) => s.isStrongFlag).toList(growable: false);

  /// Total ground distance covered across the day, in metres.
  double get totalDistanceMeters =>
      segments.fold(0, (sum, s) => sum + s.distanceMeters);

  /// Wall-clock time from the first usable ping to the last.
  Duration get elapsed {
    if (segments.isEmpty) return Duration.zero;
    var total = Duration.zero;
    for (final s in segments) {
      total += s.duration;
    }
    return total;
  }

  /// Fraction of elapsed time spent on flagged segments, 0..1.
  double get flaggedTimeShare {
    if (elapsed.inSeconds <= 0) return 0;
    var held = Duration.zero;
    for (final s in flagged) {
      held += s.duration;
    }
    return (held.inMicroseconds / elapsed.inMicroseconds).clamp(0.0, 1.0);
  }

  /// Builds the movement analysis for one day of pings.
  ///
  /// Points are ordered chronologically first, so an out-of-order server
  /// response cannot produce a negative duration or an infinite speed.
  static RouteAnalysis build(Iterable<TrackingPoint> points) {
    final all = points.toList();
    final usable = all.where((p) => p.hasCoordinates).toList()
      ..sort((a, b) {
        final at = a.recordedAt;
        final bt = b.recordedAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return at.compareTo(bt);
      });

    final skipped = all.where((p) => !p.hasCoordinates).length;

    // A point with no timestamp cannot anchor a speed calculation.
    final timed = usable.where((p) => p.recordedAt != null).toList();
    if (timed.length < 2) {
      return RouteAnalysis.empty(skipped, used: timed.length);
    }

    final distance = Distance();
    final segments = <RouteSegment>[];
    var zeroDuration = 0;

    for (var i = 0; i < timed.length - 1; i++) {
      final a = timed[i];
      final b = timed[i + 1];
      final micros = b.recordedAt!.difference(a.recordedAt!).inMicroseconds;

      // Two pings at the same instant: no time passed, so no speed exists.
      // Without this guard the division below yields Infinity and the segment
      // would be misclassified as free-flowing.
      if (micros <= 0) {
        zeroDuration++;
        continue;
      }

      final seconds = micros / 1000000;
      final meters = distance.as(
        LengthUnit.Meter,
        LatLng(a.latitude!, a.longitude!),
        LatLng(b.latitude!, b.longitude!),
      );
      final speed = meters / seconds;

      segments.add(
        RouteSegment(
          from: a,
          to: b,
          distanceMeters: meters,
          duration: Duration(microseconds: micros),
          speedMs: speed,
          movement: _classify(speed),
        ),
      );
    }

    return RouteAnalysis(
      segments: segments,
      pointsUsed: timed.length,
      pointsSkipped: skipped,
      zeroDurationSegments: zeroDuration,
    );
  }

  static MovementClass _classify(double speedMs) {
    if (speedMs < kSlowSpeedMs) return MovementClass.slow;
    if (speedMs <= kFreeFlowSpeedMs) return MovementClass.moderate;
    return MovementClass.freeFlowing;
  }
}
