import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_theme.dart';
import '../imeet_models.dart';
import '../imeet_service.dart';

/// Download / save controls for one recording.
///
/// Two separate affordances, because they answer different questions:
///   * Save the audio to the device.
///   * Save the TRANSCRIPT text.
///
/// Both resolve through `imeet_sign_recording`, which the server re-checks on
/// every call. That matters: a short-lived URL minted while someone still had
/// access is useless once the owner revokes it, because the NEXT call is
/// refused. A URL cached in the app cannot be used to smuggle access back.
///
/// The buttons are hidden entirely when the owner shared the folder read-only,
/// rather than shown and then failing — offering a control that cannot work is
/// worse than not offering it.
class IMeetRecordingExport extends StatefulWidget {
  const IMeetRecordingExport({
    super.key,
    required this.recording,
    required this.canDownload,
    this.meetingTitle = 'Meeting',
  });

  final IMeetRecording recording;
  final bool canDownload;
  final String meetingTitle;

  @override
  State<IMeetRecordingExport> createState() => _IMeetRecordingExportState();
}

class _IMeetRecordingExportState extends State<IMeetRecordingExport> {
  // Not `const`: IMeetService.instance is a lazily-created singleton.
  final _svc = IMeetService.instance;

  bool _busy = false;
  String? _error;

  /// A filesystem-safe stem, with follow-ups kept distinct so two snippets of
  /// the same meeting never overwrite each other on save.
  String get _stem {
    final raw = widget.meetingTitle.replaceAll(RegExp(r'[^\w\- ]'), '').trim();
    final base = raw.isEmpty ? 'Meeting' : raw;
    return widget.recording.isFollowUp
        ? '$base (follow-up ${widget.recording.sequence})'
        : base;
  }

  /// Fetch the signed audio URL, write it to app storage, then hand the real
  /// file to the OS. The user keeps a file, not a link that expires in minutes.
  Future<void> _saveAudio() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final url = await _svc.signedAudioUrl(widget.recording.id);
      if (url == null || url.isEmpty) {
        throw Exception('The server did not return a download link.');
      }
      // Dart's built-in HttpClient: the project declares no `http` or
      // `path_provider` dependency, and adding one purely to save a file would
      // be a larger change than this feature warrants.
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        if (res.statusCode != 200) {
          throw Exception('download failed (HTTP ${res.statusCode})');
        }
        final bytes = await res.fold<BytesBuilder>(
          BytesBuilder(),
          (b, chunk) => b..add(chunk),
        );
        final dir = Directory.systemTemp.createTempSync('imeet_export');
        final path = '$dir.path/$_stem.m4a';
        File(path).writeAsBytesSync(bytes.takeBytes());
        // Hand the real file to the OS so the user can Save to Files, AirDrop,
        // mail it, or open it in another app.
        await SharePlus.instance.share(
          ShareParams(files: [XFile(path)], text: 'Recording from $_stem'),
        );
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save the recording: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Save the transcript as plain text, so it is readable offline and in any
  /// editor rather than only inside the app.
  Future<void> _saveTranscript() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final text = await _svc.loadTranscript(widget.recording.id);
      if (text == null || text.trim().isEmpty) {
        throw Exception('There is no transcript for this recording yet.');
      }
      final dir = Directory.systemTemp.createTempSync('imeet_export');
      final path = '$dir.path/$_stem.txt';
      File(path).writeAsStringSync(text);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: 'Transcript from $_stem'),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save the transcript: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!widget.canDownload) {
      // Not an error state: the owner deliberately shared this folder read-only.
      return Row(
        children: [
          Icon(
            Icons.visibility_outlined,
            size: 14,
            color: AppColors.textTertiary(context),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'The owner shared this folder for reading only, so downloads are off.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _saveAudio,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save recording'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _saveTranscript,
              icon: const Icon(Icons.description_outlined, size: 16),
              label: const Text('Save transcript'),
            ),
          ],
        ),
      ],
    );
  }
}
