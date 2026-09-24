import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/theme/app_theme.dart';

/// Lightweight signature capture used by the training assessment flow.
/// Produces a PNG [Uint8List]; the file is uploaded into the private
/// `documents` bucket under `training-signatures/<participant>/<uuid>.png` —
/// the same path convention the web platform enforces server-side.
class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key, required this.onChanged});

  final ValueChanged<Uint8List?> onChanged;

  @override
  State<SignaturePad> createState() => SignaturePadState();
}

class SignaturePadState extends State<SignaturePad> {
  final _key = GlobalKey();
  final _strokes = <List<Offset>>[];
  List<Offset>? _current;
  Uint8List? _lastPng;
  Timer? _debounce;

  bool get isEmpty => _strokes.isEmpty;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onPanStart(DragStartDetails d) {
    _current = [d.localPosition];
    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails d) {
    _current?.add(d.localPosition);
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _capturePng);
  }

  void _onPanEnd(DragEndDetails d) {
    final current = _current;
    if (current != null && current.isNotEmpty) {
      _strokes.add(List.of(current));
    }
    _current = null;
    _capturePng();
  }

  Future<void> _capturePng() async {
    try {
      final boundary =
          _key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      await WidgetsBinding.instance.endOfFrame;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      _lastPng = byteData?.buffer.asUint8List();
      widget.onChanged(_lastPng);
    } catch (_) {
      // Signature capture is best-effort; submission remains server-gated.
    }
  }

  void _clear() {
    setState(() {
      _strokes.clear();
      _current = null;
      _lastPng = null;
    });
    widget.onChanged(null);
  }

  /// Render the current pad to a PNG (web flow requires the captured bitmap
  /// at the moment of signing).
  Future<Uint8List?> capture() async {
    await _capturePng();
    return _lastPng;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          height: 200,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFD5DCE6)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: RepaintBoundary(
            key: _key,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: GestureDetector(
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _SignaturePainter(List.of(_strokes), live: _current),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: IconButton.filledTonal(
            tooltip: 'Clear signature',
            onPressed: _strokes.isEmpty ? null : _clear,
            icon: const Icon(Icons.backspace_outlined, size: 18),
          ),
        ),
        if (_strokes.isEmpty)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Text(
                  'Sign here',
                  style: TextStyle(color: Colors.black26, fontSize: 15),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes, {this.live});

  final List<List<Offset>> strokes;
  final List<Offset>? live;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.slate900
      ..strokeWidth = 2.4
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final all = List<List<Offset>>.of(strokes);
    if (live != null && live!.isNotEmpty) all.add(live!);

    for (final stroke in all) {
      if (stroke.length > 1) {
        final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
        for (var i = 1; i < stroke.length; i++) {
          path.lineTo(stroke[i].dx, stroke[i].dy);
        }
        canvas.drawPath(path, paint);
      } else if (stroke.isNotEmpty) {
        canvas.drawPoints(ui.PointMode.points, stroke, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) =>
      oldDelegate.strokes != strokes || oldDelegate.live != live;
}
