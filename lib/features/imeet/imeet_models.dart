/// Plain, server-shaped models for I-Meet.
///
/// Every field mirrors a real column, so nothing here has to be reconciled with
/// the server later. `fromRow` is total: a missing or unparseable value becomes
/// a sensible default rather than throwing, because a malformed row must not
/// take down the whole meeting list.
library;

/// Where a meeting is in the pipeline. Mirrors the DB check constraint.
enum IMeetStatus {
  draft,

  /// A future meeting with no recording yet. Reachable now that
  /// `imeet_schedule_meeting` exists; previously nothing could set this.
  scheduled,
  recording,
  processing,
  ready,
  failed,

  /// Deliberately called off. The row is kept for the audit trail, and the
  /// default queries filter it out so it never clutters the list.
  cancelled,
  archived,
}

/// Per-recording pipeline state. Transcribe and summarise are separate on
/// purpose, so one failing never destroys the other's output.
enum IMeetStage {
  transcribing,
  transcribed,
  summarising,
  completed,
  failed,
  summaryFailed,
}

extension IMeetStatusX on IMeetStatus {
  String get label => switch (this) {
    IMeetStatus.draft => 'Draft',
    IMeetStatus.scheduled => 'Scheduled',
    IMeetStatus.recording => 'Recording',
    IMeetStatus.processing => 'Processing',
    IMeetStatus.ready => 'Ready',
    IMeetStatus.failed => 'Failed',
    IMeetStatus.cancelled => 'Cancelled',
    IMeetStatus.archived => 'Archived',
  };

  static IMeetStatus parse(String? v) => IMeetStatus.values.firstWhere(
    (s) => s.name == v,
    orElse: () => IMeetStatus.draft,
  );
}

class IMeetMeeting {
  const IMeetMeeting({
    required this.id,
    required this.title,
    this.description,
    this.location,
    this.folderId,
    this.status = IMeetStatus.draft,
    this.calendarProvider,
    this.calendarExternalId,
    this.startedAt,
    this.endedAt,
  });

  final String id;
  final String title;
  final String? description;
  final String? location;
  final String? folderId;
  final IMeetStatus status;
  final String? calendarProvider;

  /// The stable join key back to the calendar event. Never matched on title.
  final String? calendarExternalId;
  final DateTime? startedAt;
  final DateTime? endedAt;

  bool get isFromCalendar => calendarExternalId?.isNotEmpty == true;

  /// True while a recording is still moving through the pipeline.
  bool get isProcessing =>
      status == IMeetStatus.processing || status == IMeetStatus.recording;

  /// A meeting that has been planned but has not happened yet. The "Upcoming"
  /// list is built from these.
  bool get isUpcoming =>
      status == IMeetStatus.scheduled &&
      (startedAt?.toLocal().isAfter(DateTime.now()) ?? false);

  /// True once the meeting's start time has passed, whether or not anything was
  /// recorded. Used to decide whether a scheduled meeting is now recordable.
  bool get hasStarted => startedAt?.toLocal().isBefore(DateTime.now()) ?? false;

  factory IMeetMeeting.fromRow(Map<String, dynamic> r) => IMeetMeeting(
    id: '${r['id'] ?? ''}',
    title: '${r['title'] ?? 'Untitled meeting'}',
    description: r['description'] as String?,
    location: r['location'] as String?,
    folderId: r['folder_id'] as String?,
    status: IMeetStatusX.parse(r['status'] as String?),
    calendarProvider: r['calendar_provider'] as String?,
    calendarExternalId: r['calendar_external_id'] as String?,
    startedAt: DateTime.tryParse('${r['started_at'] ?? ''}'),
    endedAt: DateTime.tryParse('${r['ended_at'] ?? ''}'),
  );
}

class IMeetRecording {
  const IMeetRecording({
    required this.id,
    required this.meetingId,
    required this.sequence,
    this.label,
    this.isFollowUp = false,
    this.durationSeconds,
    this.recordedAt,
    this.transcriptionStatus = 'pending',
    this.summaryStatus = 'pending',
    this.summaryOverview,
    this.summaryKeyPoints = const [],
    this.summaryDecisions = const [],
    this.summaryIssues = const [],
    this.errorMessage,
  });

  final String id;
  final String meetingId;

  /// 1 is the main recording; 2+ are follow-ups under the SAME meeting.
  final int sequence;
  final String? label;
  final bool isFollowUp;
  final int? durationSeconds;
  final DateTime? recordedAt;
  final String transcriptionStatus;
  final String summaryStatus;
  final String? summaryOverview;
  final List<String> summaryKeyPoints;
  final List<String> summaryDecisions;
  final List<String> summaryIssues;
  final String? errorMessage;

  bool get transcriptReady => transcriptionStatus == 'ready';
  bool get summaryReady => summaryStatus == 'ready';

  /// A failed stage never implies the audio is gone.
  bool get canRetryTranscription => transcriptionStatus == 'failed';
  bool get canRetrySummary =>
      summaryStatus == 'failed' && transcriptionStatus == 'ready';

  /// '12m 30s' style label, or an em dash when the duration is unknown.
  String get durationLabel {
    final s = durationSeconds;
    if (s == null || s <= 0) return '—';
    final m = s ~/ 60;
    final sec = s % 60;
    return m == 0 ? '${sec}s' : '${m}m ${sec.toString().padLeft(2, '0')}s';
  }

  static List<String> _strings(Object? raw) {
    if (raw is List) {
      return [for (final x in raw) '$x'.trim()]
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }

  factory IMeetRecording.fromRow(Map<String, dynamic> r) => IMeetRecording(
    id: '${r['id'] ?? ''}',
    meetingId: '${r['meeting_id'] ?? ''}',
    sequence: (r['sequence'] as num?)?.toInt() ?? 1,
    label: r['label'] as String?,
    isFollowUp: r['is_follow_up'] == true,
    durationSeconds: (r['duration_seconds'] as num?)?.toInt(),
    recordedAt: DateTime.tryParse('${r['recorded_at'] ?? ''}'),
    transcriptionStatus: '${r['transcription_status'] ?? 'pending'}',
    summaryStatus: '${r['summary_status'] ?? 'pending'}',
    summaryOverview: r['summary_overview'] as String?,
    summaryKeyPoints: _strings(r['summary_key_points']),
    summaryDecisions: _strings(r['summary_decisions']),
    summaryIssues: _strings(r['summary_issues']),
    errorMessage: r['error_message'] as String?,
  );
}

class IMeetParticipant {
  const IMeetParticipant({
    required this.displayName,
    this.userId,
    this.email,
    this.isOrganiser = false,
  });

  final String displayName;
  final String? userId;
  final String? email;
  final bool isOrganiser;

  factory IMeetParticipant.fromRow(Map<String, dynamic> r) => IMeetParticipant(
    displayName: '${r['display_name'] ?? 'Participant'}',
    userId: r['user_id'] as String?,
    email: r['email'] as String?,
    isOrganiser: r['is_organiser'] == true,
  );
}

class IMeetActionItem {
  const IMeetActionItem({
    required this.id,
    required this.title,
    this.detail,
    this.assigneeId,
    this.dueAt,
    this.status = 'open',
    this.isInferred = false,
  });

  final String id;
  final String title;
  final String? detail;
  final String? assigneeId;
  final DateTime? dueAt;
  final String status;

  /// True when the model inferred the owner rather than hearing it assigned.
  final bool isInferred;

  bool get isOpen => status == 'open' || status == 'in_progress';

  factory IMeetActionItem.fromRow(Map<String, dynamic> r) => IMeetActionItem(
    id: '${r['id'] ?? ''}',
    title: '${r['title'] ?? ''}',
    detail: r['detail'] as String?,
    assigneeId: r['assignee_id'] as String?,
    dueAt: DateTime.tryParse('${r['due_at'] ?? ''}'),
    status: '${r['status'] ?? 'open'}',
    isInferred: r['is_inferred'] == true,
  );
}

class IMeetFolder {
  const IMeetFolder({
    required this.id,
    required this.name,
    this.colour,
    this.meetingCount = 0,
    this.isOwner = true,
    this.canDownload = true,
    this.memberCount = 0,
  });

  final String id;
  final String name;
  final String? colour;
  final int meetingCount;

  /// True when the signed-in user owns this folder. A folder shared WITH the
  /// user is read-only: only the owner may share, revoke or delete.
  final bool isOwner;

  /// False when the owner shared the folder for reading only. The UI must not
  /// offer a download button in that case — the server refuses it too, but the
  /// button should never be shown in the first place.
  final bool canDownload;

  /// How many people currently have access (owner-only view).
  final int memberCount;

  /// A folder the user was given, rather than one they created.
  bool get isShared => !isOwner;

  factory IMeetFolder.fromRow(Map<String, dynamic> r) => IMeetFolder(
    id: '${r['id'] ?? ''}',
    name: '${r['name'] ?? ''}',
    colour: r['colour'] as String?,
    meetingCount: (r['meeting_count'] as num?)?.toInt() ?? 0,
    isOwner: r['is_owner'] != false,
    canDownload: r['can_download'] != false,
    memberCount: (r['member_count'] as num?)?.toInt() ?? 0,
  );
}

/// One person who has been given access to a shared folder.
///
/// `canDownload` is independent of `canView` so an owner can let someone read
/// a summary while withholding the audio (for example a sensitive HR or
/// disciplinary meeting).
class IMeetFolderMember {
  const IMeetFolderMember({
    required this.userId,
    required this.fullName,
    this.email,
    this.canView = true,
    this.canDownload = true,
    this.addedAt,
  });

  final String userId;
  final String fullName;
  final String? email;
  final bool canView;
  final bool canDownload;
  final DateTime? addedAt;

  bool get isViewOnly => canView && !canDownload;

  factory IMeetFolderMember.fromRow(Map<String, dynamic> r) =>
      IMeetFolderMember(
        userId: '${r['user_id'] ?? ''}',
        fullName: '${r['full_name'] ?? 'Unknown user'}',
        email: r['email'] as String?,
        canView: r['can_view'] != false,
        canDownload: r['can_download'] != false,
        addedAt: DateTime.tryParse('${r['added_at'] ?? ''}'),
      );
}

/// A meeting plus everything the details page renders in one place.
class IMeetMeetingDetail {
  const IMeetMeetingDetail({
    required this.meeting,
    this.recordings = const [],
    this.participants = const [],
    this.actionItems = const [],
  });

  final IMeetMeeting meeting;
  final List<IMeetRecording> recordings;
  final List<IMeetParticipant> participants;
  final List<IMeetActionItem> actionItems;

  bool get hasFollowUps => recordings.any((r) => r.isFollowUp);
  int get openActionCount => actionItems.where((a) => a.isOpen).length;
}

/// Outcome of running the AI pipeline over one recording.
class IMeetPipelineResult {
  const IMeetPipelineResult({
    required this.ok,
    this.transcriptReady = false,
    this.failedStage,
    this.message,
  });

  final bool ok;

  /// A transcript can be ready even when the overall result is a failure —
  /// that is precisely the "summary failed but nothing was lost" case.
  final bool transcriptReady;
  final IMeetStage? failedStage;
  final String? message;
}
