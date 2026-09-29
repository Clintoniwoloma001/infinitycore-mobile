import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';
import 'imeet_models.dart';
import 'imeet_service.dart';
import 'widgets/imeet_widgets.dart';

/// Meeting details — summary, transcript and recordings in ONE place.
///
/// Section 7 is explicit that the transcript and summary must not be hidden
/// behind modal sheets or separate screens: the user should reach the summary,
/// then the transcript, then the recordings, without navigating away. So all
/// three are stacked here, and the transcript for a selected recording is
/// fetched lazily rather than pulled with the page.
class IMeetMeetingScreen extends StatefulWidget {
  const IMeetMeetingScreen({super.key, required this.meetingId});

  final String meetingId;

  @override
  State<IMeetMeetingScreen> createState() => _IMeetMeetingScreenState();
}

class _IMeetMeetingScreenState extends State<IMeetMeetingScreen> {
  final IMeetService _service = IMeetService.instance;

  IMeetMeetingDetail? _detail;
  bool _loading = true;
  String? _error;

  /// Which recording's transcript is expanded, if any.
  String? _openTranscriptId;
  String? _transcript;
  bool _transcriptLoading = false;
  bool _transcriptFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _service.loadMeeting(widget.meetingId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _error = d == null ? 'This meeting is not available.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Load one recording's transcript on demand.
  ///
  /// Never fetched for every recording at once: a meeting with a long history
  /// would otherwise transfer every transcript to render a list (section 30).
  Future<void> _toggleTranscript(IMeetRecording r) async {
    if (_openTranscriptId == r.id) {
      setState(() {
        _openTranscriptId = null;
        _transcript = null;
      });
      return;
    }
    setState(() {
      _openTranscriptId = r.id;
      _transcriptLoading = true;
      _transcriptFailed = false;
      _transcript = null;
    });
    try {
      final text = await _service.loadTranscript(r.id);
      if (!mounted) return;
      setState(() {
        _transcript = text;
        _transcriptFailed = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _transcriptFailed = true);
    } finally {
      if (mounted) setState(() => _transcriptLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: _detail?.meeting.title ?? 'Meeting'),
      body: _loading
          ? const PageLoadingView(label: 'Loading meeting…')
          : _error != null
          ? PageErrorView(message: _error!, onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 96),
                children: [
                  _HeaderCard(detail: _detail!),
                  const SizedBox(height: 16),
                  _RecordingsSection(
                    detail: _detail!,
                    openTranscriptId: _openTranscriptId,
                    transcript: _transcript,
                    transcriptLoading: _transcriptLoading,
                    transcriptFailed: _transcriptFailed,
                    onToggleTranscript: _toggleTranscript,
                    onRecordFollowUp: _recordFollowUp,
                  ),
                  const SizedBox(height: 16),
                  _ActionItemsSection(detail: _detail!),
                  const SizedBox(height: 16),
                  _ParticipantsSection(detail: _detail!),
                ],
              ),
            ),
      floatingActionButton: _detail == null
          ? null
          : FloatingActionButton.extended(
              heroTag: 'imeet_followup',
              onPressed: _recordFollowUp,
              backgroundColor: AppColors.accent(context),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Record Follow-up'),
            ),
    );
  }

  /// Add a follow-up recording to THIS meeting (rule 9).
  ///
  /// The meeting id is passed through, so the server appends a recording rather
  /// than creating a second meeting.
  Future<void> _recordFollowUp() async {
    final done = await context.push<bool>(
      '/imeet/record',
      extra: {'meetingId': widget.meetingId},
    );
    if (done == true && mounted) _load();
  }
}

/// Title, time, location, folder and calendar provenance.
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.detail});
  final IMeetMeetingDetail detail;

  @override
  Widget build(BuildContext context) {
    final m = detail.meeting;
    final when = m.startedAt?.toLocal();
    final date = when == null
        ? ''
        : '${when.day.toString().padLeft(2, '0')}/'
              '${when.month.toString().padLeft(2, '0')}/${when.year}';
    final time = when == null
        ? ''
        : '${when.hour.toString().padLeft(2, '0')}:'
              '${when.minute.toString().padLeft(2, '0')}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    m.title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IMeetStatusPill(status: m.status),
              ],
            ),
            if (date.isNotEmpty) ...[
              const SizedBox(height: 8),
              _MetaRow(icon: Icons.schedule, text: '$date · $time'),
            ],
            if (m.location?.isNotEmpty == true)
              _MetaRow(icon: Icons.location_on, text: m.location!),
            if (m.description?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                m.description!,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ],
            if (m.isFromCalendar) ...[
              const SizedBox(height: 10),
              _MetaRow(
                icon: Icons.event_available,
                text: 'Linked to a calendar event',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.textTertiary(context)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Recordings, each with its own AI summary and transcript.
///
/// The meeting is the parent; recordings are children. Follow-ups appear in the
/// same list, numbered, so a user can see at a glance that "Weekly Management"
/// has a main capture plus two follow-ups rather than three unrelated meetings.
class _RecordingsSection extends StatelessWidget {
  const _RecordingsSection({
    required this.detail,
    required this.openTranscriptId,
    required this.transcript,
    required this.transcriptLoading,
    required this.transcriptFailed,
    required this.onToggleTranscript,
    required this.onRecordFollowUp,
  });

  final IMeetMeetingDetail detail;
  final String? openTranscriptId;
  final String? transcript;
  final bool transcriptLoading;
  final bool transcriptFailed;
  final ValueChanged<IMeetRecording> onToggleTranscript;
  final VoidCallback onRecordFollowUp;

  @override
  Widget build(BuildContext context) {
    final recs = detail.recordings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.graphic_eq, size: 15, color: AppColors.accent(context)),
            const SizedBox(width: 6),
            Text(
              'RECORDINGS (${recs.length})',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (recs.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    'No recordings yet.',
                    style: TextStyle(color: AppColors.textSecondary(context)),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: onRecordFollowUp,
                    icon: const Icon(Icons.graphic_eq, size: 18),
                    label: const Text('Record now'),
                  ),
                ],
              ),
            ),
          )
        else
          for (final r in recs)
            _RecordingCard(
              recording: r,
              expanded: openTranscriptId == r.id,
              transcript: transcript,
              transcriptLoading: transcriptLoading,
              transcriptFailed: transcriptFailed,
              onToggle: () => onToggleTranscript(r),
            ),
      ],
    );
  }
}

/// One recording: its own pipeline state, summary and transcript.
class _RecordingCard extends StatelessWidget {
  const _RecordingCard({
    required this.recording,
    required this.expanded,
    required this.transcript,
    required this.transcriptLoading,
    required this.transcriptFailed,
    required this.onToggle,
  });

  final IMeetRecording recording;
  final bool expanded;
  final String? transcript;
  final bool transcriptLoading;
  final bool transcriptFailed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final r = recording;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  r.isFollowUp ? Icons.refresh : Icons.fiber_manual_record,
                  size: 14,
                  color: r.isFollowUp
                      ? AppColors.accent(context)
                      : AppColors.rose,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    r.label ?? (r.isFollowUp ? 'Follow-up' : 'Main recording'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  r.durationLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textTertiary(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StageChip(
                  label: r.transcriptReady
                      ? 'Transcript ready'
                      : r.transcriptionStatus == 'failed'
                      ? 'Transcription failed'
                      : r.transcriptionStatus == 'processing'
                      ? 'Transcribing…'
                      : 'Transcript pending',
                  ok: r.transcriptReady,
                  failed: r.transcriptionStatus == 'failed',
                ),
                _StageChip(
                  label: r.summaryReady
                      ? 'Summary ready'
                      : r.summaryStatus == 'failed'
                      ? 'Summary failed'
                      : r.summaryStatus == 'processing'
                      ? 'Summarising…'
                      : 'Summary pending',
                  ok: r.summaryReady,
                  failed: r.summaryStatus == 'failed',
                ),
              ],
            ),
            if (r.errorMessage != null && r.errorMessage!.isNotEmpty) ...[
              const SizedBox(height: 8),
              _FailureNote(message: r.errorMessage!),
            ],
            if (r.summaryOverview != null && r.summaryOverview!.isNotEmpty) ...[
              const SizedBox(height: 12),
              _SummaryBlock(recording: r),
            ],
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onToggle,
                icon: Icon(
                  expanded
                      ? Icons.keyboard_double_arrow_up_rounded
                      : Icons.description_outlined,
                  size: 18,
                ),
                label: Text(expanded ? 'Hide transcript' : 'View transcript'),
              ),
            ),
            if (expanded)
              _TranscriptBlock(
                loading: transcriptLoading,
                failed: transcriptFailed,
                text: transcript,
              ),
          ],
        ),
      ),
    );
  }
}

/// The AI summary for one recording.
///
/// Sections the model did not fill are OMITTED rather than shown empty, so the
/// user can tell "nothing was decided" from "we haven't looked yet".
class _SummaryBlock extends StatelessWidget {
  const _SummaryBlock({required this.recording});
  final IMeetRecording recording;

  @override
  Widget build(BuildContext context) {
    final r = recording;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome,
                size: 14,
                color: AppColors.accent(context),
              ),
              const SizedBox(width: 5),
              const Text(
                'AI SUMMARY',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          if (r.summaryOverview != null && r.summaryOverview!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              r.summaryOverview!,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ],
          if (r.summaryKeyPoints.isNotEmpty)
            _SummaryList(
              title: 'Key discussion',
              items: r.summaryKeyPoints,
              color: AppColors.accent(context),
            ),
          if (r.summaryDecisions.isNotEmpty)
            _SummaryList(
              title: 'Decisions',
              items: r.summaryDecisions,
              color: AppColors.green,
            ),
          if (r.summaryIssues.isNotEmpty)
            _SummaryList(
              title: 'Issues raised',
              items: r.summaryIssues,
              color: AppColors.amber,
            ),
        ],
      ),
    );
  }
}

class _SummaryList extends StatelessWidget {
  const _SummaryList({
    required this.title,
    required this.items,
    required this.color,
  });

  final String title;
  final List<String> items;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        for (final i in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5, right: 6),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    i,
                    style: const TextStyle(fontSize: 13, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The transcript for the expanded recording.
class _TranscriptBlock extends StatelessWidget {
  const _TranscriptBlock({
    required this.loading,
    required this.failed,
    required this.text,
  });

  final bool loading;
  final bool failed;
  final String? text;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: PageLoadingView(label: 'Loading transcript…'),
      );
    }
    if (failed) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: _FailureNote(
          message: 'The transcript could not be loaded. Pull to refresh.',
        ),
      );
    }
    final body = text?.trim() ?? '';
    if (body.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          'No transcript available for this recording yet.',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textTertiary(context),
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TRANSCRIPT',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 8),
          // Selectable so a user can copy a passage out of a long meeting.
          SelectableText(
            body,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// An honest failure note.
///
/// Always paired with a retry where the action exists, so a user is never told
/// something failed and then given no way to fix it without re-recording.
class _FailureNote extends StatelessWidget {
  const _FailureNote({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.rose.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.rose.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: AppColors.rose),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Action items extracted from the transcript.
///
/// Inference is always labelled. A model-guessed owner is shown as
/// "Owner not stated", never as a fact the meeting never agreed to.
class _ActionItemsSection extends StatelessWidget {
  const _ActionItemsSection({required this.detail});
  final IMeetMeetingDetail detail;

  @override
  Widget build(BuildContext context) {
    final items = detail.actionItems;
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.done_all_rounded,
              size: 15,
              color: AppColors.accent(context),
            ),
            const SizedBox(width: 6),
            Text(
              'ACTION ITEMS (${items.where((a) => a.isOpen).length} open)',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final a in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  a.isOpen ? Icons.radio_button_unchecked : Icons.check_circle,
                  size: 15,
                  color: a.isOpen ? AppColors.amber : AppColors.green,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ActionItemTitle(item: a),
                      if (a.detail != null && a.detail!.isNotEmpty)
                        Text(
                          a.detail!,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textTertiary(context),
                          ),
                        ),
                      if (a.isInferred)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            'Owner not stated in the meeting',
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: AppColors.textTertiary(context),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One action item's title.
///
/// Extracted so the strikethrough decoration and the two ink colours live in
/// their own small widget. A done item is struck through and dimmed; an open
/// one is full-strength. Nothing about state is conveyed by colour alone — the
/// strike and the tick icon beside it both say it.
class _ActionItemTitle extends StatelessWidget {
  const _ActionItemTitle({required this.item});
  final IMeetActionItem item;

  @override
  Widget build(BuildContext context) {
    final open = item.isOpen;
    // `color` is listed before `decoration` deliberately: the app-wide
    // dark-mode guard walks upwards from an ink helper looking for a container
    // `decoration:`, and only a `style:`/`TextStyle` marker above it proves the
    // colour is text. Keeping the ink on the first line makes that unambiguous.
    final ink = open
        ? AppColors.textPrimary(context)
        : AppColors.textTertiary(context);
    return Text(
      item.title,
      style: TextStyle(
        color: ink,
        fontSize: 13,
        decoration: open ? null : TextDecoration.lineThrough,
      ),
    );
  }
}

/// Who was on the meeting, as supplied by the calendar.
///
/// Section 16: these are calendar facts, never inferred from voices. Speaker
/// identification is explicitly out of scope for this release.
class _ParticipantsSection extends StatelessWidget {
  const _ParticipantsSection({required this.detail});
  final IMeetMeetingDetail detail;

  @override
  Widget build(BuildContext context) {
    final people = detail.participants;
    if (people.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.groups_outlined,
              size: 15,
              color: AppColors.accent(context),
            ),
            const SizedBox(width: 6),
            Text(
              'PARTICIPANTS (${people.length})',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final p in people)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.surface(context),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Text(
                  p.displayName,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A pipeline stage's state, as a small pill.
///
/// Word + icon + colour together, so state is never conveyed by colour alone
/// (section 33).
class _StageChip extends StatelessWidget {
  const _StageChip({
    required this.label,
    required this.ok,
    required this.failed,
  });

  final String label;
  final bool ok;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final color = failed
        ? AppColors.rose
        : ok
        ? AppColors.green
        : AppColors.amber;
    final icon = failed
        ? Icons.error_outline
        : ok
        ? Icons.check_circle_outline
        : Icons.hourglass_top;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
