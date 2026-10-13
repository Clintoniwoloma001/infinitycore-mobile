import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// InfinityCore brand mark — the APPROVED Infinity Bank logo.
///
/// Reproduced from the approved master `Infinity-logo-512px.png` (the business
/// and app logo), NOT the older orange-dominant SARA mark:
///
///   * flat brand green `#029f58` rounded diamond, centred and in FRONT
///   * the identical rounded diamond in orange `#f5820f`, offset down-left
///     BEHIND it (the layered shadow that gives the mark its depth)
///   * the infinity glyph, drawn white
///
/// Everything below is measured, not eyeballed. The master was decoded pixel
/// by pixel and the geometry solved from its edge slopes: the 100x100 design
/// box places the green centre at (51.36, 47.36) with half side 26.6 and
/// corner radius 8.0, the orange copy offset by (-8.3, +4.3), and the glyph
/// runs traced from the master's knockout (every second row).
///
/// The master knocks the infinity glyph OUT of the diamond (transparent), so
/// on the dark auth screens it would show the background through the logo.
/// It is therefore drawn solid white — identical geometry, legible everywhere.
///
/// Locked by `test/approved_logo_test.dart`, which rasterises this painter and
/// diffs it against the approved master.
class InfinityMarkPainter extends CustomPainter {
  const InfinityMarkPainter();

  static const green = Color(0xFF029F58);
  static const orange = Color(0xFFF5820F);

  /// Green mark centre inside the 100x100 design box.
  static const _cx = 51.36;
  static const _cy = 47.36;

  /// Green rotated rounded-square half side and corner radius.
  static const _half = 26.6;
  static const _radius = 8.0;

  /// The orange layer sits BEHIND, slightly larger and offset down-left, which
  /// is what opens the visible gap between the two layers along the upper-left
  /// diagonal in the approved master.
  static const _orangeHalf = 27.71;
  static const _orangeRadius = 8.34;
  static const _dx = -6.84;
  static const _dy = 4.39;

  // Traced from the approved 512px mark: per-row knockout runs of the
  // infinity glyph, sampled every 2nd row. Exact pixel geometry.
  static const _glyphRuns = <(double, double, double)>[
    (35.16, 38.09, 41.21),
    (35.16, 63.87, 66.99),
    (35.55, 36.91, 42.38),
    (35.55, 62.70, 68.36),
    (35.94, 35.94, 43.55),
    (35.94, 61.72, 69.34),
    (36.33, 35.35, 44.34),
    (36.33, 60.94, 69.92),
    (36.72, 34.77, 44.92),
    (36.72, 60.35, 70.51),
    (37.11, 34.38, 45.51),
    (37.11, 59.96, 70.90),
    (37.50, 33.98, 45.90),
    (37.50, 59.38, 71.29),
    (37.89, 33.59, 46.48),
    (37.89, 58.98, 71.68),
    (38.28, 33.20, 46.88),
    (38.28, 58.59, 72.07),
    (38.67, 33.01, 38.09),
    (38.67, 41.80, 47.27),
    (38.67, 58.20, 63.48),
    (38.67, 67.19, 71.68),
    (39.06, 32.81, 37.11),
    (39.06, 42.77, 47.66),
    (39.06, 57.81, 62.50),
    (39.06, 67.97, 71.29),
    (39.45, 32.42, 36.52),
    (39.45, 43.55, 48.05),
    (39.45, 57.42, 61.72),
    (39.45, 68.75, 70.70),
    (39.84, 32.03, 35.94),
    (39.84, 44.14, 48.44),
    (39.84, 56.84, 61.13),
    (39.84, 69.14, 70.31),
    (40.23, 31.84, 35.55),
    (40.23, 44.73, 48.63),
    (40.23, 56.45, 60.55),
    (40.23, 69.53, 69.92),
    (40.62, 31.64, 35.16),
    (40.62, 45.31, 49.02),
    (40.62, 56.25, 59.96),
    (41.02, 31.45, 34.77),
    (41.02, 45.90, 49.22),
    (41.02, 55.86, 59.38),
    (41.41, 31.25, 34.18),
    (41.41, 46.29, 49.61),
    (41.41, 55.47, 58.79),
    (41.80, 31.05, 33.98),
    (41.80, 46.68, 49.80),
    (41.80, 55.27, 58.40),
    (42.19, 30.86, 33.79),
    (42.19, 47.07, 47.07),
    (42.19, 47.46, 50.00),
    (42.19, 54.88, 58.01),
    (42.58, 30.66, 33.59),
    (42.58, 47.46, 47.46),
    (42.58, 47.85, 50.39),
    (42.58, 54.69, 57.81),
    (42.97, 30.66, 33.40),
    (42.97, 47.85, 50.78),
    (42.97, 54.30, 57.42),
    (43.36, 30.66, 33.20),
    (43.36, 48.24, 51.17),
    (43.36, 54.10, 57.03),
    (43.75, 30.47, 33.01),
    (43.75, 48.63, 51.56),
    (43.75, 53.91, 56.84),
    (44.14, 30.27, 33.01),
    (44.14, 49.22, 51.95),
    (44.14, 53.52, 56.45),
    (44.53, 30.27, 32.81),
    (44.53, 49.61, 52.15),
    (44.53, 53.32, 56.25),
    (44.92, 30.27, 32.81),
    (44.92, 49.80, 55.86),
    (45.31, 30.27, 32.81),
    (45.31, 50.20, 55.47),
    (45.70, 30.08, 32.62),
    (45.70, 50.59, 55.27),
    (46.09, 30.08, 32.62),
    (46.09, 50.78, 55.08),
    (46.48, 30.08, 32.62),
    (46.48, 50.98, 54.69),
    (46.88, 30.08, 32.62),
    (46.88, 51.37, 54.49),
    (47.27, 30.08, 32.62),
    (47.27, 51.37, 54.49),
    (47.66, 30.08, 32.62),
    (47.66, 51.17, 54.69),
    (48.05, 30.08, 32.62),
    (48.05, 50.78, 54.88),
    (48.44, 30.08, 32.62),
    (48.44, 50.59, 55.08),
    (48.83, 30.08, 32.62),
    (48.83, 50.20, 55.47),
    (49.22, 30.27, 32.81),
    (49.22, 50.20, 55.66),
    (49.61, 30.27, 32.81),
    (49.61, 49.80, 55.86),
    (50.00, 30.27, 32.81),
    (50.00, 49.41, 51.95),
    (50.00, 53.12, 56.25),
    (50.39, 30.27, 32.81),
    (50.39, 49.22, 51.76),
    (50.39, 53.32, 56.64),
    (50.78, 30.47, 33.01),
    (50.78, 48.63, 51.56),
    (50.78, 53.71, 56.64),
    (51.17, 30.47, 33.20),
    (51.17, 48.24, 51.17),
    (51.17, 53.91, 57.03),
    (51.56, 30.66, 33.20),
    (51.56, 47.85, 50.59),
    (51.56, 54.30, 57.42),
    (51.95, 30.66, 33.40),
    (51.95, 47.46, 50.39),
    (51.95, 54.49, 57.81),
    (52.34, 30.86, 33.59),
    (52.34, 47.27, 50.20),
    (52.34, 54.88, 58.01),
    (52.73, 31.05, 33.79),
    (52.73, 46.88, 49.80),
    (52.73, 55.08, 58.40),
    (53.12, 31.05, 33.98),
    (53.12, 46.29, 49.61),
    (53.12, 55.47, 58.79),
    (53.52, 31.25, 34.18),
    (53.52, 46.09, 49.22),
    (53.52, 55.86, 59.18),
    (53.91, 31.45, 34.77),
    (53.91, 45.51, 48.83),
    (53.91, 56.05, 59.77),
    (54.30, 31.64, 34.96),
    (54.30, 45.12, 48.63),
    (54.30, 56.45, 60.35),
    (54.69, 31.84, 35.35),
    (54.69, 44.53, 48.24),
    (54.69, 56.84, 60.74),
    (54.69, 69.73, 69.73),
    (55.08, 32.03, 35.94),
    (55.08, 43.95, 47.85),
    (55.08, 57.42, 61.33),
    (55.08, 69.34, 70.12),
    (55.47, 32.42, 36.33),
    (55.47, 43.36, 47.66),
    (55.47, 57.81, 62.11),
    (55.47, 68.75, 70.51),
    (55.86, 32.81, 36.91),
    (55.86, 42.58, 47.27),
    (55.86, 58.20, 62.70),
    (55.86, 68.16, 70.90),
    (56.25, 33.01, 37.89),
    (56.25, 41.60, 46.88),
    (56.25, 58.59, 63.87),
    (56.25, 67.19, 71.29),
    (56.64, 33.20, 46.48),
    (56.64, 58.98, 71.68),
    (57.03, 33.59, 45.90),
    (57.03, 59.38, 71.88),
    (57.42, 33.98, 45.51),
    (57.42, 59.96, 71.48),
    (57.81, 34.38, 45.12),
    (57.81, 60.35, 71.09),
    (58.20, 34.96, 44.34),
    (58.20, 60.94, 70.51),
    (58.59, 35.55, 43.55),
    (58.59, 61.72, 69.73),
    (58.98, 36.33, 42.77),
    (58.98, 62.50, 68.95),
    (59.38, 36.72, 36.72),
    (59.38, 37.30, 41.80),
    (59.38, 62.89, 62.89),
    (59.38, 63.48, 67.97),
    (59.77, 37.89, 41.02),
    (59.77, 64.06, 67.19),
  ];

  void _diamond(
    Canvas canvas,
    double cx,
    double cy,
    double half,
    double radius,
    Paint paint,
  ) {
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(math.pi / 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-half, -half, half * 2, half * 2),
        Radius.circular(radius),
      ),
      paint,
    );
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 100;
    canvas.save();
    canvas.scale(scale, scale);

    // Orange layer first (behind), then the green mark on top.
    _diamond(
      canvas,
      _cx + _dx,
      _cy + _dy,
      _orangeHalf,
      _orangeRadius,
      Paint()..color = orange,
    );
    _diamond(canvas, _cx, _cy, _half, _radius, Paint()..color = green);

    // Infinity glyph: one rect per traced run. The 0.4 height closes the
    // two-row sampling gap so the glyph reads as a solid silhouette.
    final glyph = Path();
    for (final run in _glyphRuns) {
      final (y, x0, x1) = run;
      glyph.addRect(Rect.fromLTRB(x0, y, x1 + 0.4, y + 0.4));
    }
    canvas.drawPath(glyph, Paint()..color = const Color(0xFFFFFFFF));

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant InfinityMarkPainter oldDelegate) => false;
}

/// Brand mark as a widget.
class InfinityMark extends StatelessWidget {
  const InfinityMark({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: const InfinityMarkPainter(),
    );
  }
}

/// Brand logo (mark + wordmark), matching the web platform's
/// `Logo` component. `light` is for dark backgrounds.
class InfinityCoreLogo extends StatelessWidget {
  const InfinityCoreLogo({
    super.key,
    this.size = 40,
    this.light = false,
    this.showTagline = false,
  });

  final double size;
  final bool light;
  final bool showTagline;

  @override
  Widget build(BuildContext context) {
    final infinityColor = light ? Colors.white : const Color(0xFF007A4A);
    final taglineColor = light ? Colors.white70 : const Color(0xFF333333);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InfinityMark(size: size),
            SizedBox(width: size * 0.16),
            Text.rich(
              TextSpan(
                style: TextStyle(
                  color: infinityColor,
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  height: 1.0,
                ),
                children: [
                  const TextSpan(text: 'Infinity'),
                  TextSpan(
                    text: 'Core',
                    style: const TextStyle(color: Color(0xFFF58220)),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (showTagline) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 22,
                height: 1,
                color: light ? Colors.white54 : AppColors.greenDark,
              ),
              const SizedBox(width: 8),
              Text(
                'Powering Every Decision.',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.3,
                  color: taglineColor,
                ),
              ),
              const SizedBox(width: 8),
              Container(width: 22, height: 1, color: const Color(0xFFF58220)),
            ],
          ),
        ],
      ],
    );
  }
}

/// Renders [InfinityMarkPainter] into a PNG byte array (used by the asset
/// generator and tests).
Future<ui.Image> renderMark({int size = 1024}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(size / 100);
  const InfinityMarkPainter().paint(canvas, const Size(100, 100));
  final picture = recorder.endRecording();
  return picture.toImage(size, size);
}
