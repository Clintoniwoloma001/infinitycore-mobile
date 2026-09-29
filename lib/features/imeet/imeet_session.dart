import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/services/supabase_service.dart';
import 'imeet_models.dart';
import 'imeet_recorder.dart';
import 'imeet_service.dart';

/// Drives one "record a meeting" session end to end.
///
/// This is the orchestrator the UI talks to, and it exists so the screens stay
/// dumb: open a meeting, press record, watch the pipeline, land on the result.
///
/// It enforces the product rules that are easy to break by accident:
///   * rule 9  — a follow-up adds a RECORDING to the same meeting, never a
///               second meeting;
///   * rule 10 — a failed summary does not destroy the transcript;
///   * rule 11 — a failed transcription does not destroy the audio;
///   * rule 12 — every stage is observable, so the user is never left guessing.
class IMeetSession extends ChangeNotifier {
  IMeetSession();

  final IMeetService _service = IMeetService.instance;

  /// Where the pipeline currently is, for the progress panel.
  IMeetStage? _stage;
  IMeetStage? get stage => _stage;

  /// The human-readable reason for the last failure, or null.
  String? _failure;
  String? get failure => _failure;

  /// True while an upload or AI stage is in flight.
  bool _busy = false;
  bool get busy => _busy;

  /// The recording created by the most recent stop, so the details screen can
  /// link straight to it.
  String? _lastRecordingId;
  String? get lastRecordingId => _lastRecordingId;

  /// True once a transcript exists even though the overall run failed. This is
  /// the "summary failed, transcript is fine" case the UI must present as a
  /// partial success rather than an error.
  bool _transcriptSurvived = false;
  bool get transcriptSurvived => _transcriptSurvived;

  void clearFailure() {
    _failure = null;
    notifyListeners();
  }

  /// Start a capture against a newly opened (or reused) meeting.
  ///
  /// The meeting is opened server-side FIRST so the recording and its frozen
  /// audience are attached to a real meeting from the first second. When the
  /// meeting came from a calendar event, the server reuses the existing meeting
  /// rather than forking a duplicate (rule 8), which is reported back as
  /// [reused] so the UI can say so.
  Future<({String meetingId, int sequence, bool reused})> beginRecording({
    String? title,
    String? location,
    String? calendarProvider,
    String? calendarExternalId,
    DateTime? startedAt,
    String? folderId,
  }) async {
    final opened = await _service.openMeeting(
      title: title,
      calendarProvider: calendarProvider,
      calendarExternalId: calendarExternalId,
      startedAt: startedAt,
      location: location,
      folderId: folderId,
    );
    final ok = await IMeetRecorder.instance.start(opened.meetingId);
    if (!ok) {
      _failure =
          IMeetRecorder.instance.error ??
          'Recording could not be started. Check microphone permission.';
      notifyListeners();
    }
    return (
      meetingId: opened.meetingId,
      sequence: opened.nextSequence,
      reused: opened.reused,
    );
  }

  /// Stop, upload, and run the AI pipeline for the current capture.
  ///
  /// Returns the recording id on success. On a FAILED upload the audio is kept
  /// on disk and the caller is told, because losing a meeting to a network blip
  /// is the one outcome this module must never produce (section 26).
  Future<String?> stopAndProcess({
    required String meetingId,
    required int sequence,
    String? label,
  }) async {
    _stage = null;
    _failure = null;
    _transcriptSurvived = false;
    _busy = true;
    notifyListeners();

    final duration = IMeetRecorder.instance.elapsed;
    File? file;
    try {
      file = await IMeetRecorder.instance.stop();
      if (file == null) {
        _failure = 'Nothing was recorded. Hold the microphone and try again.';
        _busy = false;
        notifyListeners();
        return null;
      }

      final me = SupabaseService.userId ?? '';
      if (me.isEmpty) {
        _failure = 'You need to be signed in to save a recording.';
        _busy = false;
        notifyListeners();
        return null;
      }

      // Register first, so the audience is frozen, then upload to the path the
      // registration is updated with.
      final recordingId = await _service.addRecording(
        meetingId: meetingId,
        sequence: sequence,
        label: label,
        durationSeconds: duration.inSeconds,
      );
      _lastRecordingId = recordingId;

      final path = await _service.uploadAudio(
        file: file,
        ownerId: me,
        meetingId: meetingId,
        recordingId: recordingId,
      );
      await _service.updateMeeting(meetingId, {
        'ended_at': DateTime.now().toUtc().toIso8601String(),
      });
      await _attachAudioPath(recordingId, path, await file.length());

      IMeetRecorder.instance.markProcessing();

      final result = await _service.processRecording(
        recordingId,
        onStage: (s, message) {
          if ((s == IMeetStage.failed || s == IMeetStage.summaryFailed) &&
              message != null) {
            _failure = message;
          }
          _stage = s;
          notifyListeners();
        },
      );

      _transcriptSurvived = result.transcriptReady;
      if (result.ok) {
        await _service.notifyReady(meetingId, 'Meeting');
      } else {
        // Notify honestly: the user is told which stage failed, and the UI
        // offers a retry rather than implying the meeting is lost.
        await _service.notifyFailed(
          meetingId,
          'Meeting',
          result.message ?? 'Processing did not complete.',
        );
      }
      _busy = false;
      notifyListeners();
      return recordingId;
    } catch (e) {
      // The audio file still exists on disk. Report it and keep it, so the
      // recording can be retried rather than re-recorded.
      _failure =
          'The recording was saved on this device but could not be uploaded: $e';
      _busy = false;
      notifyListeners();
      return null;
    }
  }

  /// Write the stored audio location onto the recording.
  Future<void> _attachAudioPath(
    String recordingId,
    String path,
    int bytes,
  ) async {
    try {
      await SupabaseService.client
          .from('imeet_recordings')
          .update({
            'audio_path': path,
            'audio_mime': 'audio/mp4',
            'audio_bytes': bytes,
            'upload_status': 'uploaded',
          })
          .eq('id', recordingId);
    } catch (_) {
      // Status is a hint; the audio itself is already stored.
    }
  }

  /// Retry a single stage for an existing recording.
  Future<bool> retry(String recordingId, String stage) async {
    _busy = true;
    _failure = null;
    _stage = stage == 'summary'
        ? IMeetStage.summarising
        : IMeetStage.transcribing;
    notifyListeners();
    final result = await _service.retryStage(recordingId, stage);
    _busy = false;
    if (result.ok) {
      _stage = IMeetStage.completed;
      _failure = null;
    } else {
      _failure = result.message;
      _stage = IMeetStage.failed;
    }
    notifyListeners();
    return result.ok;
  }

  @override
  void dispose() {
    _service.unsubscribe();
    super.dispose();
  }
}
