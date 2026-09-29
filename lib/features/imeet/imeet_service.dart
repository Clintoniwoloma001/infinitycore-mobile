import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/notification_service.dart';
import '../../core/services/supabase_service.dart';
import 'imeet_models.dart';

/// Data layer for I-Meet — InfinityCore's AI meeting intelligence module.
///
/// The model mirrors the server exactly, because the server is the authority
/// (section 27): the Flutter client never transcribes locally and never holds a
/// provider key (rule 5). It uploads audio to the private `i-meet-audio` bucket
/// and then drives the `imeet-transcribe` edge function, which chains
/// audio -> transcript -> summary -> action items.
///
/// Nothing here re-derives state the server already owns. Meeting status,
/// recording status and the frozen audience are all read back from Postgres.
class IMeetService {
  IMeetService._();

  static final IMeetService instance = IMeetService._();

  // -------------------------------------------------------------------------
  // Read paths
  // -------------------------------------------------------------------------

  /// Meetings the caller may see, newest first.
  ///
  /// RLS already scopes this to owner-or-participant, so there is no client
  /// filter to bypass or get wrong. Columns are selected explicitly: the list
  /// must never pull transcripts or audio (section 30).
  Future<List<IMeetMeeting>> listMeetings({
    String? folderId,
    int limit = 50,
    int offset = 0,
  }) async {
    // Apply the filter BEFORE order/range: those return a transform builder,
    // and composing a filter onto one is a different (and here unavailable)
    // builder type.
    final base = SupabaseService.client
        .from('imeet_meetings')
        .select(
          'id, title, description, location, folder_id, status, '
          'calendar_provider, calendar_external_id, started_at, ended_at, '
          'created_at, updated_at',
        );
    final filtered = folderId == null ? base : base.eq('folder_id', folderId);
    final rows = _rows(
      await filtered
          .order('started_at', ascending: false)
          .range(offset, offset + limit - 1),
    );
    return [for (final r in rows) IMeetMeeting.fromRow(r)];
  }

  /// Full detail for one meeting: participants, recordings, action items.
  Future<IMeetMeetingDetail?> loadMeeting(String meetingId) async {
    final m = _row(
      await SupabaseService.client
          .from('imeet_meetings')
          .select('*')
          .eq('id', meetingId)
          .maybeSingle(),
    );
    // _row normalises a null payload to an empty map, so "not found" and "found
    // nothing useful" are the same case here.
    if (m.isEmpty) return null;

    // The transcript is deliberately NOT selected here: it is fetched only
    // when a specific recording's transcript is opened.
    final recs = _rows(
      await SupabaseService.client
          .from('imeet_recordings')
          .select(
            'id, meeting_id, sequence, label, is_follow_up, '
            'audio_mime, audio_bytes, duration_seconds, recorded_at, '
            'upload_status, transcription_status, summary_status, '
            'error_message, transcript_language, transcript_provider, '
            'summary_overview, summary_key_points, summary_decisions, '
            'summary_issues, summary_generated_at, created_at',
          )
          .eq('meeting_id', meetingId)
          .order('sequence'),
    );
    final parts = _rows(
      await SupabaseService.client
          .from('imeet_participants')
          .select('*')
          .eq('meeting_id', meetingId),
    );
    final actions = _rows(
      await SupabaseService.client
          .from('imeet_action_items')
          .select('*')
          .eq('meeting_id', meetingId)
          .order('created_at'),
    );
    return IMeetMeetingDetail(
      meeting: IMeetMeeting.fromRow(m),
      recordings: [for (final r in recs) IMeetRecording.fromRow(r)],
      participants: [for (final p in parts) IMeetParticipant.fromRow(p)],
      actionItems: [for (final a in actions) IMeetActionItem.fromRow(a)],
    );
  }

  /// The transcript for ONE recording.
  ///
  /// Split out from [loadMeeting] so opening the meeting list, or even the
  /// details page, never transfers transcript text for every recording.
  Future<String?> loadTranscript(String recordingId) async {
    final r = _row(
      await SupabaseService.client
          .from('imeet_recordings')
          .select('transcript')
          .eq('id', recordingId)
          .maybeSingle(),
    );
    return r['transcript'] as String?;
  }

  /// A short-lived signed URL for playback.
  ///
  /// Audio is never fetched with a public or bearer URL: the server re-checks
  /// access and mints a URL that expires (section 20/31).
  Future<String?> signedAudioUrl(String recordingId) async {
    final res = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'imeet_sign_recording',
      params: {'p_recording_id': recordingId},
    );
    final url = res['url'] as String?;
    if (url == null || url.isEmpty) return null;
    return url;
  }

  Future<List<IMeetFolder>> listFolders() async {
    final rows = _rows(
      await SupabaseService.client
          .from('imeet_folders')
          .select('*')
          .order('sort_order')
          .order('name'),
    );
    return [for (final r in rows) IMeetFolder.fromRow(r)];
  }

  // -------------------------------------------------------------------------
  // Write paths
  // -------------------------------------------------------------------------

  Future<IMeetFolder> createFolder(String name) async {
    // Folders are a plain owner-scoped insert; RLS is the boundary.
    final row = _row(
      await SupabaseService.client
          .from('imeet_folders')
          .insert({'name': name})
          .select('*')
          .single(),
    );
    return IMeetFolder.fromRow(row);
  }

  Future<void> renameFolder(String id, String name) async {
    await SupabaseService.client
        .from('imeet_folders')
        .update({'name': name, 'updated_at': DateTime.now().toIso8601String()})
        .eq('id', id);
  }

  /// Delete a folder. Meetings inside are UNASSIGNED, not deleted
  /// (section 14) — the FK is ON DELETE SET NULL for exactly this reason, so a
  /// meeting can never be destroyed by tidying a folder.
  Future<void> deleteFolder(String id) async {
    await SupabaseService.client.from('imeet_folders').delete().eq('id', id);
  }

  Future<void> moveMeetingToFolder(String meetingId, String? folderId) async {
    await SupabaseService.client
        .from('imeet_meetings')
        .update({
          'folder_id': folderId,
          'updated_at': DateTime.now().toIso8601String(),
        })
        .eq('id', meetingId);
  }

  Future<void> updateMeeting(
    String meetingId,
    Map<String, Object?> patch,
  ) async {
    await SupabaseService.client
        .from('imeet_meetings')
        .update({...patch, 'updated_at': DateTime.now().toIso8601String()})
        .eq('id', meetingId);
  }

  /// Open (or reuse) a meeting and return the id plus the next sequence.
  ///
  /// Reuse is what makes a second recording of the SAME calendar event attach
  /// to the same meeting rather than forking a duplicate (rule 8).
  Future<({String meetingId, int nextSequence, bool reused})> openMeeting({
    String? title,
    String? calendarProvider,
    String? calendarExternalId,
    DateTime? startedAt,
    String? location,
    String? folderId,
  }) async {
    final res = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'imeet_open_meeting',
      params: {
        'p_title': title,
        'p_calendar_provider': calendarProvider,
        'p_calendar_external_id': calendarExternalId,
        'p_started_at': startedAt?.toUtc().toIso8601String(),
        'p_location': location,
        'p_folder_id': folderId,
      },
    );
    final meeting = (res['meeting'] as Map).cast<String, dynamic>();
    return (
      meetingId: '${meeting['id']}',
      nextSequence: (res['next_sequence'] as num?)?.toInt() ?? 1,
      reused: res['reused_existing'] == true,
    );
  }

  /// Attach participants BEFORE recording, so the audience is frozen from real
  /// people rather than guessed after the fact.
  Future<void> setParticipants(
    String meetingId,
    List<({String name, String? userId, bool organiser})> people,
  ) async {
    if (people.isEmpty) return;
    await SupabaseService.client.from('imeet_participants').upsert([
      for (final p in people)
        {
          'meeting_id': meetingId,
          'display_name': p.name,
          'user_id': p.userId,
          'is_organiser': p.organiser,
        },
    ], onConflict: 'meeting_id,display_name');
  }

  /// Register a finished recording. The frozen audience is seeded here, in the
  /// same transaction.
  Future<String> addRecording({
    required String meetingId,
    int? sequence,
    String? label,
    int? durationSeconds,
    String? audioPath,
    String? audioMime,
    int? audioBytes,
  }) async {
    final res = await SupabaseService.client.rpc<Map<String, dynamic>>(
      'imeet_add_recording',
      params: {
        'p_meeting_id': meetingId,
        'p_sequence': sequence,
        'p_label': label,
        'p_duration_seconds': durationSeconds,
        'p_audio_path': audioPath,
        'p_audio_mime': audioMime,
        'p_audio_bytes': audioBytes,
      },
    );
    final rec = (res['recording'] as Map).cast<String, dynamic>();
    return '${rec['id']}';
  }

  /// Flag one pipeline stage as failed WITHOUT destroying anything else
  /// (rules 10/11). Audio and any existing transcript are left untouched.
  Future<void> markStageFailed(
    String recordingId,
    String stage,
    String error,
  ) async {
    try {
      await SupabaseService.client.rpc<Map<String, dynamic>>(
        'imeet_mark_stage',
        params: {
          'p_recording_id': recordingId,
          'p_stage': stage,
          'p_error': error,
          'p_failed': true,
        },
      );
    } catch (_) {
      // The recording itself is safe; only the status hint is lost.
    }
  }

  /// Upload a local recording into the PRIVATE bucket.
  ///
  /// Path convention matches the storage policy exactly:
  /// `<owner>/<meeting>/<recording>.m4a`. The first segment MUST be the
  /// caller's own id or the insert policy rejects the upload.
  Future<String> uploadAudio({
    required File file,
    required String ownerId,
    required String meetingId,
    required String recordingId,
  }) async {
    // Extension taken from the file itself rather than via `package:path`, so
    // I-Meet adds no dependency.
    final dot = file.path.lastIndexOf('.');
    final ext = (dot > 0 && file.path.length - dot <= 5)
        ? file.path.substring(dot)
        : '.m4a';
    final path = '$ownerId/$meetingId/$recordingId$ext';
    final bytes = await file.readAsBytes();
    await SupabaseService.client.storage
        .from('i-meet-audio')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            upsert: true,
            contentType: 'audio/mp4',
          ),
        );
    return path;
  }

  // -------------------------------------------------------------------------
  // AI pipeline
  // -------------------------------------------------------------------------

  /// Drive transcription then summary for one recording.
  ///
  /// [onStage] fires as the pipeline advances so the UI can show
  /// "Audio uploaded / Transcript generated / Generating summary" instead of
  /// leaving the user wondering whether anything happened (section 8).
  ///
  /// Each stage is independent: a summary failure still leaves a readable
  /// transcript, and either stage can be retried on its own.
  Future<IMeetPipelineResult> processRecording(
    String recordingId, {
    void Function(IMeetStage stage, String? message)? onStage,
  }) async {
    onStage?.call(IMeetStage.transcribing, null);

    final t = await _invokeStage(recordingId, 'transcription');
    if (!t.ok) {
      onStage?.call(IMeetStage.failed, t.message);
      return IMeetPipelineResult(
        ok: false,
        failedStage: IMeetStage.transcribing,
        message: t.message,
      );
    }
    onStage?.call(IMeetStage.transcribed, null);
    onStage?.call(IMeetStage.summarising, null);

    final s = await _invokeStage(recordingId, 'summary');
    if (!s.ok) {
      // The transcript is already stored and usable — say so plainly rather
      // than reporting the whole meeting as lost.
      onStage?.call(IMeetStage.summaryFailed, s.message);
      return IMeetPipelineResult(
        ok: false,
        transcriptReady: true,
        failedStage: IMeetStage.summarising,
        message: s.message,
      );
    }
    onStage?.call(IMeetStage.completed, null);
    return const IMeetPipelineResult(ok: true, transcriptReady: true);
  }

  /// Retry a single stage, for the "Retry transcription" / "Retry summary"
  /// affordance the UI must offer rather than forcing a re-record.
  Future<IMeetPipelineResult> retryStage(
    String recordingId,
    String stage,
  ) async {
    final r = await _invokeStage(recordingId, stage);
    return IMeetPipelineResult(
      ok: r.ok,
      transcriptReady: r.ok || stage == 'summary',
      failedStage: r.ok
          ? null
          : (stage == 'summary'
                ? IMeetStage.summarising
                : IMeetStage.transcribing),
      message: r.message,
    );
  }

  Future<({bool ok, String? message})> _invokeStage(
    String recordingId,
    String stage,
  ) async {
    try {
      final res = await SupabaseService.client.functions.invoke(
        'imeet-transcribe',
        body: {'recording_id': recordingId, 'stage': stage},
      );
      final data = res.data is Map
          ? (res.data as Map).cast<String, dynamic>()
          : null;
      if (data == null) {
        return (
          ok: false,
          message: 'The processing service returned no result.',
        );
      }
      if (data['ok'] == true) return (ok: true, message: null);
      return (
        ok: false,
        message: '${data['message'] ?? data['error'] ?? 'Processing failed.'}',
      );
    } catch (e) {
      return (ok: false, message: 'Could not reach the processing service: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Notifications — reuses the platform's own pipeline (rule 4)
  // -------------------------------------------------------------------------

  /// Tell the user a meeting is ready, using the EXISTING notification stack
  /// rather than a second independent one.
  Future<void> notifyReady(String meetingId, String title) async {
    await NotificationService.instance.show(
      id: meetingId.hashCode & 0x7fffffff,
      title: 'Meeting ready',
      body: 'Your transcript and AI summary for "$title" are ready.',
      route: '/imeet/$meetingId',
      channel: NotificationService.channelAnnouncements,
      highPriority: false,
    );
  }

  Future<void> notifyFailed(
    String meetingId,
    String title,
    String reason,
  ) async {
    await NotificationService.instance.show(
      id: (meetingId.hashCode + 31) & 0x7fffffff,
      title: 'Meeting processing failed',
      body: '"$title": $reason',
      route: '/imeet/$meetingId',
      channel: NotificationService.channelAnnouncements,
      highPriority: true,
    );
  }

  // -------------------------------------------------------------------------
  // Realtime — the dashboard updates without a refresh
  // -------------------------------------------------------------------------

  RealtimeChannel? _channel;

  /// Watch this user's meetings and recordings.
  ///
  /// Meetings are scoped to `owner_id` so the channel carries only the
  /// caller's own rows, which is both cheaper and correct.
  void subscribe({required void Function() onChange}) {
    final me = SupabaseService.userId;
    if (me == null || me.isEmpty) return;
    _channel = SupabaseService.client
        .channel('imeet:$me')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'imeet_meetings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'owner_id',
            value: me,
          ),
          callback: (_) => onChange(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'imeet_recordings',
          callback: (_) => onChange(),
        )
        .subscribe();
  }

  void unsubscribe() {
    final c = _channel;
    _channel = null;
    if (c != null) unawaited(c.unsubscribe());
  }

  // -------------------------------------------------------------------------
  // Search (section 15)
  // -------------------------------------------------------------------------

  /// Search meeting titles and descriptions.
  ///
  /// Runs in Postgres against the text index rather than pulling every meeting
  /// into memory, so this stays fast with thousands of meetings.
  Future<List<IMeetMeeting>> search(String term, {int limit = 40}) async {
    final q = term.trim();
    if (q.isEmpty) return listMeetings(limit: limit);
    final rows = _rows(
      await SupabaseService.client
          .from('imeet_meetings')
          .select(
            'id, title, description, location, folder_id, status, '
            'calendar_provider, calendar_external_id, started_at, ended_at, '
            'created_at, updated_at',
          )
          .or('title.ilike.%$q%,description.ilike.%$q%')
          .order('started_at', ascending: false)
          .limit(limit),
    );
    return [for (final r in rows) IMeetMeeting.fromRow(r)];
  }

  // -------------------------------------------------------------------------
  // helpers
  // -------------------------------------------------------------------------

  /// Normalise a PostgREST payload into plain maps.
  ///
  /// Takes the raw value rather than the response so it accepts a list result,
  /// a `.maybeSingle()` row, or a null — all three of which this service uses.
  static List<Map<String, dynamic>> _rows(Object? data) {
    if (data is List) {
      return [
        for (final r in data)
          if (r is Map) Map<String, dynamic>.from(r),
      ];
    }
    return const [];
  }

  static Map<String, dynamic> _row(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return {};
  }
}
