import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// InfinityCore brand mark, reproduced from the official InfinityCore/SARA
/// logo (`src/components/Logo.jsx` in the web platform).
///
///   * rotated square (diamond) in orange `#f58220`
///   * inner diamond filled with the green brand gradient `#00a85a → #007a4a`
///   * white infinity symbol `∞`
///   * small orange accent diamond at the top-right
class InfinityMarkPainter extends CustomPainter {
  const InfinityMarkPainter();

  static const orange = Color(0xFFF58220);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 100;
    canvas.save();
    canvas.scale(scale, scale);

    final orangePaint = Paint()..color = orange;
    final greenFill = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF00A85A), AppColors.greenDark],
      ).createShader(const Rect.fromLTWH(0, 0, 100, 100));

    // Outer (orange) diamond.
    canvas.save();
    canvas.translate(50, 50);
    canvas.rotate(math.pi / 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(-29, -31, 29, 27),
        const Radius.circular(15),
      ),
      orangePaint,
    );
    canvas.restore();

    // Inner (green gradient) diamond.
    canvas.save();
    canvas.translate(50, 50);
    canvas.rotate(math.pi / 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(-26, -26, 26, 26),
        const Radius.circular(13),
      ),
      greenFill,
    );
    canvas.restore();

    // White infinity glyph.
    final textPainter = TextPainter(
      text: const TextSpan(
        text: '∞',
        style: TextStyle(
          color: Colors.white,
          fontSize: 30,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = 50 - textPainter.width / 2;
    final dy = 51 - textPainter.height / 2;
    textPainter.paint(canvas, Offset(dx, dy));

    // Small orange accent diamond (top-right strip).
    canvas.save();
    canvas.translate(63, 50);
    canvas.rotate(math.pi / 4);
    canvas.drawRect(const Rect.fromLTRB(-3, -3, 3, 3), orangePaint);
    canvas.restore();

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
                    style: TextStyle(
                      color: infinityColor == Colors.white
                          ? const Color(0xFFF58220)
                          : const Color(0xFFF58220),
                    ),
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
