import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import 'attachment_service.dart';
import 'communication_service.dart';

/// Why a voice action was refused, so the UI can say something specific
/// instead of a generic failure.
enum VoiceError {
  denied,
  busy,
  tooShort,
  tooLong,
  failed;

  String get message => switch (this) {
    VoiceError.denied =>
      'Microphone access is off. Enable it in Settings to send a voice note.',
    VoiceError.busy => 'A recording is already in progress.',
    VoiceError.tooShort => 'Hold to record for at least a second.',
    VoiceError.tooLong => 'Voice notes are limited to 5 minutes.',
    VoiceError.failed =>
      'The recording could not be finished. Please try again.',
  };
}

/// Wraps the `record` plugin with the constraints the messaging product needs.
///
/// A voice note is a first-class attachment, not a raw `.m4a` blob: it is
/// uploaded through the same `documents` bucket as any other file, is named
/// `voice-note-<epoch>.m4a` so [attachmentTypeFor] buckets it as
/// `voice_note`, and its duration is stored on the attachment so the composer
/// can render a label without decoding the container.
class VoiceRecorderService with ChangeNotifier {
  VoiceRecorderService();

  /// Hard cap matching the web composer, so a phone cannot be held recording
  /// for hours while the user forgets it is running.
  static const maxDuration = Duration(minutes: 5);

  static const minDuration = Duration(milliseconds: 800);

  final AudioRecorder _recorder = AudioRecorder();
  Timer? _ticker;

  bool _recording = false;
  bool _cancelling = false;
  Duration _elapsed = Duration.zero;
  String? _path;
  VoiceError? _error;

  bool get isRecording => _recording;

  Duration get elapsed => _elapsed;

  String? get lastError => _error?.message;

  VoiceError? get error => _error;

  /// Requests microphone access, returning `false` when the user declined.
  ///
  /// Permission is requested per recording attempt rather than cached at
  /// startup: Android can revoke it while the app is backgrounded, and a stale
  /// "granted" would fail deep inside the plugin with no useful message.
  ///
  /// The `record` plugin owns this request rather than a separate permission
  /// package, so the app shows exactly one system dialog for the microphone no
  /// matter which feature (voice notes or SARA) asks first.
  Future<bool> ensurePermission() async {
    final granted = await _recorder.hasPermission(request: true);
    if (granted) return true;
    debugPrint('[VoiceRecorderService] microphone permission denied');
    _error = VoiceError.denied;
    notifyListeners();
    return false;
  }

  Future<bool> start() async {
    if (_recording) {
      _error = VoiceError.busy;
      notifyListeners();
      return false;
    }
    if (!await ensurePermission()) return false;
    try {
      final dir = await _temporaryDirectory();
      final path =
          '$dir/voice-note-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: 44100,
        ),
        path: path,
      );
      _path = path;
      _elapsed = Duration.zero;
      _cancelling = false;
      _error = null;
      _recording = true;
      _ticker?.cancel();
      // The plugin exposes no duration stream, so the composer clock is driven
      // locally and kept authoritative: it is what the send button and the
      // auto-stop both read.
      _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _elapsed += const Duration(milliseconds: 100);
        if (_elapsed >= maxDuration) {
          // Auto-stop at the cap so a forgotten recording cannot sit open with
          // the microphone indicator still on.
          unawaited(stop());
        }
        notifyListeners();
      });
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[VoiceRecorderService] start failed: $e');
      _error = VoiceError.failed;
      notifyListeners();
      return false;
    }
  }

  Future<String?> _temporaryDirectory() async {
    final base = Directory.systemTemp;
    final dir = Directory('${base.path}/infinitycore-voice');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Finishes the recording and returns the [PendingAttachment] to queue.
  ///
  /// Returns `null` for a cancelled or too-short take. The temporary file is
  /// left on disk only when it is actually attached; discarded takes are
  /// deleted so a long session does not fill the cache directory.
  Future<PendingAttachment?> stop() async {
    if (!_recording) return null;
    _ticker?.cancel();
    _ticker = null;
    _recording = false;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      debugPrint('[VoiceRecorderService] stop failed: $e');
      _error = VoiceError.failed;
    }
    final elapsed = _elapsed;
    final file = File(path ?? _path ?? '');
    notifyListeners();

    if (_cancelling || elapsed < minDuration || !await file.exists()) {
      await _discard(file);
      if (!_cancelling) _error = VoiceError.tooShort;
      notifyListeners();
      return null;
    }
    final bytes = await file.length();
    final name = file.uri.pathSegments.isEmpty
        ? 'voice-note.m4a'
        : file.uri.pathSegments.last;
    return PendingAttachment(
      path: file.path,
      fileName: name,
      mimeType: 'audio/mp4',
      sizeBytes: bytes,
      durationMs: elapsed.inMilliseconds,
    );
  }

  /// Aborts the current take and discards the audio.
  Future<void> cancel() async {
    if (!_recording) return;
    _cancelling = true;
    await stop();
  }

  /// Releases the underlying recorder and the [ChangeNotifier] subscription
  /// list. Called when the composer is disposed so the microphone is never left
  /// open behind a closed screen.
  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    if (_recording) {
      _recording = false;
      // Fire-and-forget: `dispose` is synchronous, and the plugin's `cancel`
      // releases the OS microphone handle on its own. Awaiting it here would
      // force the whole recorder to become async for no user-visible gain.
      unawaited(
        _recorder.cancel().catchError((Object e) {
          debugPrint('[VoiceRecorderService] cancel on dispose: $e');
        }),
      );
    }
    unawaited(
      _recorder.dispose().catchError((Object e) {
        debugPrint('[VoiceRecorderService] dispose: $e');
      }),
    );
    super.dispose();
  }

  Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[VoiceRecorderService] discard failed: $e');
    }
  }
}

/// Plays back a voice note from a short-lived signed URL.
///
/// Voice notes live in the private `documents` bucket, so playback has to mint
/// a signed URL first ([CommunicationService.signedAttachmentUrl]) and must
/// never assume a public path. A signed URL expires, so the player re-mints it
/// transparently when a note is played after a long pause rather than failing
/// with a 403 the user cannot act on.
class VoicePlaybackController extends ChangeNotifier {
  VoicePlaybackController();

  final AudioPlayer _player = AudioPlayer();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _durationSub;

  /// Attachment id currently loaded, so tapping a second note stops the first.
  String? _activeId;
  bool _loading = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  String? get activeId => _activeId;

  bool get isLoading => _loading;

  bool get isPlaying => _playing;

  /// True when the note with [id] is loaded and actively playing.
  bool isPlayingId(String id) => _playing && _activeId == id;

  /// True when the note with [id] is the one currently loaded, playing or not.
  bool isActiveId(String id) => _activeId == id;

  Duration get position => _position;

  Duration get duration => _duration;

  String? get error => _error;

  /// 0..1, used by the composer's progress bar and the bubble's waveform.
  double get progress {
    final total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// Loads (and, when [autoplay] is set, starts) the note identified by
  /// [attachmentId].
  ///
  /// Re-tapping the note that is already playing pauses it, which is what users
  /// expect from a single play/pause control.
  Future<void> toggle(Map<String, dynamic> attachment) async {
    final id = '${attachment['id'] ?? attachment['file_path'] ?? ''}';
    if (id.isEmpty) return;
    if (_activeId == id) {
      if (_playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
      return;
    }
    await play(attachment);
  }

  Future<void> play(
    Map<String, dynamic> attachment, {
    bool autoplay = true,
  }) async {
    final id = '${attachment['id'] ?? attachment['file_path'] ?? ''}';
    final path = '${attachment['file_path'] ?? ''}';
    if (id.isEmpty || path.isEmpty) return;

    await _detach();
    _activeId = id;
    _loading = true;
    _error = null;
    _position = Duration.zero;
    _duration = Duration(
      milliseconds: '${attachment['duration_ms'] ?? 0}'.isEmpty
          ? 0
          : int.tryParse('${attachment['duration_ms'] ?? 0}') ?? 0,
    );
    notifyListeners();

    try {
      final url = await CommunicationService.instance.signedAttachmentUrl(path);
      if (url == null || url.isEmpty) {
        throw StateError('This voice note is no longer available.');
      }
      final loaded = await _player.setUrl(url);
      _duration = loaded ?? _duration;
      _attach();
      if (autoplay) await _player.play();
    } catch (e) {
      debugPrint('[VoicePlaybackController] $e');
      _error = 'This voice note could not be played.';
      _activeId = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void _attach() {
    _positionSub = _player.positionStream.listen((p) {
      _position = p;
      notifyListeners();
    });
    _durationSub = _player.durationStream.listen((d) {
      if (d != null && d > Duration.zero) {
        _duration = d;
        notifyListeners();
      }
    });
    _stateSub = _player.playerStateStream.listen((state) {
      final nowPlaying =
          state.playing && state.processingState != ProcessingState.completed;
      if (_playing != nowPlaying) {
        _playing = nowPlaying;
        notifyListeners();
      }
    });
  }

  Future<void> _detach() async {
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _stateSub?.cancel();
    _positionSub = null;
    _durationSub = null;
    _stateSub = null;
    try {
      await _player.stop();
    } catch (_) {
      // Stopping an unloaded player is a no-op on some platforms.
    }
    _playing = false;
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}

/// `m:ss` label for a voice-note duration.
String formatVoiceDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
