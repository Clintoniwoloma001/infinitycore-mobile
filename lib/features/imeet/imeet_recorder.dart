import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// The recording lifecycle, exactly as specified in section 7.
///
/// Exposed as an explicit enum rather than a bool pair so the UI can never
/// render "recording" while paused (rule 12: the user must always know whether
/// the microphone is live).
enum IMeetRecordState {
  /// Nothing in progress.
  idle,

  /// Microphone open and capturing.
  recording,

  /// Microphone still open but not capturing; the timer is held.
  paused,

  /// Playback head is being finalised before upload.
  stopping,

  /// Audio is uploaded and the AI pipeline is running.
  processing,
}

/// Drives recording for one meeting.
///
/// Deliberately thin: it owns the recorder and the state machine, and nothing
/// else. Persistence and the AI pipeline belong to [IMeetService] so a
/// processing failure can never lose or corrupt the audio (rules 10/11).
///
/// Recording never starts without an explicit permission check. A denial leaves
/// the controller [IMeetRecordState.idle] and reports the reason, so the caller
/// can explain it rather than appearing to hang (section 22).
class IMeetRecorder extends ChangeNotifier {
  IMeetRecorder._();

  static final IMeetRecorder instance = IMeetRecorder._();

  final AudioRecorder _recorder = AudioRecorder();

  /// The meeting the current recording belongs to, or null when idle.
  ///
  /// A non-null value here is what makes the current capture a FOLLOW-UP of an
  /// existing meeting rather than a new meeting (rule 9).
  String? _meetingId;
  String? get activeMeetingId => _meetingId;

  IMeetRecordState _state = IMeetRecordState.idle;
  IMeetRecordState get state => _state;

  /// Elapsed capture time, excluding paused stretches.
  Duration _elapsed = Duration.zero;
  Duration get elapsed => _elapsed;

  /// Why the last attempt to record failed, if it did.
  String? _error;
  String? get error => _error;

  Timer? _ticker;

  /// True while the microphone is actually capturing audio.
  bool get isCapturing => _state == IMeetRecordState.recording;

  /// True while a stop is in flight, so the UI can disable the button.
  bool get isStopping => _state == IMeetRecordState.stopping;

  /// 'mm:ss' or 'h:mm:ss' — the only duration format the UI needs.
  String get elapsedLabel {
    final s = _elapsed.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  void _set(IMeetRecordState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  /// Start capturing for [meetingId].
  ///
  /// Returns false and sets [error] when the microphone is unavailable or the
  /// permission was refused. It never throws, so a denial cannot leave the app
  /// in a broken state.
  Future<bool> start(String meetingId) async {
    if (_state != IMeetRecordState.idle) return false;
    _error = null;
    _meetingId = meetingId;
    _elapsed = Duration.zero;
    try {
      if (!await _recorder.hasPermission()) {
        _fail('Microphone permission is required to record a meeting.');
        return false;
      }
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          // Mono at 16 kHz is what a transcription service wants; capturing
          // higher fidelity would only cost upload time and bytes.
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _pathFor(meetingId),
      );
      _startTicker();
      _set(IMeetRecordState.recording);
      return true;
    } catch (e) {
      _fail('Could not start recording: $e');
      return false;
    }
  }

  /// Hold the timer without releasing the microphone.
  Future<void> pause() async {
    if (_state != IMeetRecordState.recording) return;
    try {
      await _recorder.pause();
      _ticker?.cancel();
      _set(IMeetRecordState.paused);
    } catch (e) {
      _fail('Could not pause: $e');
    }
  }

  Future<void> resume() async {
    if (_state != IMeetRecordState.paused) return;
    try {
      await _recorder.resume();
      _startTicker();
      _set(IMeetRecordState.recording);
    } catch (e) {
      _fail('Could not resume: $e');
    }
  }

  /// Stop and return the audio file, or null if nothing usable was captured.
  ///
  /// The file is NOT uploaded here: the caller decides when to hand it to the
  /// service, which is what keeps a network drop from losing the recording
  /// (section 26).
  Future<File?> stop() async {
    if (_state != IMeetRecordState.recording &&
        _state != IMeetRecordState.paused) {
      return null;
    }
    _set(IMeetRecordState.stopping);
    _ticker?.cancel();
    try {
      final path = await _recorder.stop();
      final duration = _elapsed;
      _reset();
      if (path == null) return null;
      final file = File(path);
      if (!await file.exists()) return null;
      // A zero-length or sub-second capture is not a meeting. Saying so beats
      // uploading silence and generating an empty transcript.
      if (await file.length() == 0 || duration.inSeconds == 0) return null;
      return file;
    } catch (e) {
      _fail('Could not finish the recording: $e');
      return null;
    }
  }

  /// Abandon the capture and discard the audio.
  Future<void> cancel() async {
    if (_state == IMeetRecordState.idle) return;
    _ticker?.cancel();
    try {
      await _recorder.cancel();
    } catch (_) {
      // Cancelling a recorder that already stopped is not an error worth
      // surfacing; the user asked to discard either way.
    }
    _reset();
  }

  /// Move to [IMeetRecordState.processing] once the audio is safely stored.
  void markProcessing() {
    if (_state == IMeetRecordState.idle) return;
    _ticker?.cancel();
    _set(IMeetRecordState.processing);
  }

  /// Return to idle so the next recording can start.
  void finish() {
    _ticker?.cancel();
    _reset();
  }

  void _startTicker() {
    _ticker?.cancel();
    // 1 Hz is enough for an mm:ss readout and keeps the UI cheap.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsed += const Duration(seconds: 1);
      notifyListeners();
    });
  }

  void _fail(String message) {
    _error = message;
    _ticker?.cancel();
    _reset(notify: false);
    _state = IMeetRecordState.idle;
    notifyListeners();
  }

  void _reset({bool notify = true}) {
    _ticker?.cancel();
    _ticker = null;
    _meetingId = null;
    _elapsed = Duration.zero;
    if (notify) notifyListeners();
  }

  String _pathFor(String meetingId) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    // Written to the app's own temp directory and uploaded to the private
    // bucket afterwards; the file is never world-readable.
    return '${Directory.systemTemp.path}/imeet_$meetingId$stamp.m4a';
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_recorder.dispose());
    super.dispose();
  }
}
