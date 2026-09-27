import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The SARA mark, drawn rather than shipped as a bitmap.
///
/// It reproduces `infinitycore-sara/public/favicon.svg` exactly: a green
/// diamond with a second orange diamond peeking out behind it and the Infinity
/// glyph on top. Drawing it keeps the mark crisp at every density, lets it
/// re-tint for dark mode, and avoids adding an SVG dependency plus a rasterised
/// asset that would blur on a 3x display.
class SaraMark extends StatelessWidget {
  const SaraMark({super.key, this.size = 28, this.glyphColor});

  final double size;

  /// Colour of the "∞". Defaults to near-black in light mode and white in dark
  /// mode, matching the web favicon's `fill="#000"` on the light brand tile.
  final Color? glyphColor;

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.isDark(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SaraMarkPainter(
          green: dark ? AppColors.accentGreen : AppColors.green,
          orange: dark ? AppColors.orange : AppColors.orangeDark,
          glyph: glyphColor ?? (dark ? Colors.white : Colors.black),
        ),
      ),
    );
  }
}

class _SaraMarkPainter extends CustomPainter {
  const _SaraMarkPainter({
    required this.green,
    required this.orange,
    required this.glyph,
  });

  final Color green;
  final Color orange;
  final Color glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    // The web favicon uses a 100×100 viewBox with 60×60 squares rotated 45°,
    // centred at (50, 50) and (48, 48). Reproducing those proportions keeps the
    // mobile mark pixel-comparable with the web one.
    final square = side * 0.60;
    final centre = Offset(side / 2, side / 2);

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(-math.pi / 4);
    // Orange sits behind and slightly up-left, which is what produces the
    // "two-tone diamond" read in the favicon.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(0, -side * 0.02),
          width: square,
          height: square,
        ),
        Radius.circular(square * 0.22),
      ),
      Paint()..color = orange,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: square, height: square),
        Radius.circular(square * 0.22),
      ),
      Paint()..color = green,
    );
    canvas.restore();

    // The Infinity glyph. Drawn as two mirrored circles joined by a bar rather
    // than as text so it is resolution independent and does not depend on a
    // bundled font shipping an ∞ glyph.
    final glyphWidth = side * 0.44;
    final glyphHeight = side * 0.26;
    final r = glyphHeight / 2;
    final paint = Paint()
      ..color = glyph
      ..style = PaintingStyle.stroke
      ..strokeWidth = side * 0.075
      ..strokeCap = StrokeCap.round;
    final left = Rect.fromCenter(
      center: Offset(
        centre.dx - glyphWidth / 2 + r,
        centre.dy + side * 0.02,
      ),
      width: glyphHeight,
      height: glyphHeight,
    );
    final right = Rect.fromCenter(
      center: Offset(
        centre.dx + glyphWidth / 2 - r,
        centre.dy + side * 0.02,
      ),
      width: glyphHeight,
      height: glyphHeight,
    );
    final path = Path()
      ..addArc(left, math.pi / 2, math.pi)
      ..lineTo(right.left + r, centre.dy + side * 0.02)
      ..addArc(right, math.pi * 1.5, math.pi);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SaraMarkPainter old) =>
      old.green != green ||
      old.orange != orange ||
      old.glyph != glyph;
}
