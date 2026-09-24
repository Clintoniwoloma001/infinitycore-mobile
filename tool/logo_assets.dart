import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:infinitycore/core/theme/infinity_logo.dart';

/// Renders [InfinityMarkPainter] onto a [width]x[height] canvas with the mark
/// scaled to a fraction of the canvas (used to build launcher/splash assets).
Future<Uint8List> renderMarkPng({int size = 1024, double markScale = 1.0}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (markScale != 1.0) {
    canvas.translate(size / 2, size / 2);
    canvas.scale(size * markScale / 100);
    canvas.translate(-50, -50);
  } else {
    canvas.scale(size / 100);
  }
  const InfinityMarkPainter().paint(canvas, const Size(100, 100));
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}