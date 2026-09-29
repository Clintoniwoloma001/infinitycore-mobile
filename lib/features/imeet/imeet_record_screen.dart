import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';
import 'imeet_models.dart';
import 'imeet_recorder.dart';
import 'imeet_session.dart';

/// The recording experience.
///
/// Section 7 asks for simple and reliable, not a spectacle: a state word, a
/// timer, and four obvious controls. Every state is communicated by BOTH an
/// icon and a word, so the screen is still unambiguous for a user who cannot
/// rely on colour (section 33).
class IMeetRecordScreen extends StatefulWidget {
  const IMeetRecordScreen({super.key, this.args = const {}});

  /// Optional context: `meetingId` (a follow-up), `title`, `location`,
  /// `folderId`, and calendar identifiers when the meeting came from an event.
  final Map<String, dynamic> args;

  @override
  State<IMeetRecordScreen> createState() => _IMeetRecordScreenState();
}

class _IMeetRecordScreenState extends State<IMeetRecordScreen> {
  final IMeetSession _session = IMeetSession();
  final IMeetRecorder _recorder = IMeetRecorder.instance;

  /// Set once recording has begun, so the meeting id is known.
  String? _meetingId;
  int _sequence = 1;
  bool _starting = false;
  bool _stopping = false;

  /// True when this recording is a follow-up on an existing meeting.
  bool get _isFollowUp =>
      (widget.args['meetingId'] ?? '').toString().isNotEmpty;

  @override
  void initState() {
    super.initState();
    // A follow-up does not need a new meeting: open the existing one so the
    // server appends a recording to it (rule 9).
    if (_isFollowUp) {
      _meetingId = '${widget.args['meetingId']}';
      _start();
    }
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      if (_isFollowUp) {
        // The meeting already exists; sequence is resolved server-side when the
        // recording is registered, so just start capturing.
        final ok = await _recorder.start(_meetingId!);
        if (!ok) {
          _fail(_recorder.error ?? 'Recording could not be started.');
        }
        return;
      }
      final opened = await _session.beginRecording(
        title: widget.args['title'] as String?,
        location: widget.args['location'] as String?,
        calendarProvider: widget.args['calendarProvider'] as String?,
        calendarExternalId: widget.args['calendarExternalId'] as String?,
        startedAt: DateTime.now(),
        folderId: widget.args['folderId'] as String?,
      );
      _meetingId = opened.meetingId;
      _sequence = opened.sequence;
      if (_recorder.error != null) {
        _fail(_recorder.error!);
        return;
      }
      // A reuse is not a new meeting: say so rather than silently duplicating
      // (rule 8).
      if (opened.reused && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Continuing the existing meeting for this event.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _stop() async {
    if (_stopping || _meetingId == null) return;
    setState(() => _stopping = true);
    final id = await _session.stopAndProcess(
      meetingId: _meetingId!,
      sequence: _sequence,
    );
    if (!mounted) return;
    setState(() => _stopping = false);
    if (id != null) {
      // Straight to the meeting, where the summary and transcript are.
      context.go('/imeet/${_meetingId!}');
    }
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this recording?'),
        content: const Text(
          'The audio will be deleted and nothing will be transcribed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _recorder.cancel();
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(
        context,
        title: _isFollowUp ? 'Follow-up recording' : 'Record meeting',
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_recorder, _session]),
        builder: (context, _) {
          final state = _recorder.state;
          final processing = _session.busy;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: [
              Center(
                child: _TimerDial(state: state, label: _recorder.elapsedLabel),
              ),
              const SizedBox(height: 18),
              Center(
                child: _StateBanner(state: state, processing: processing),
              ),
              if (_session.failure != null) ...[
                const SizedBox(height: 16),
                _FailurePanel(
                  message: _session.failure!,
                  transcriptSurvived: _session.transcriptSurvived,
                  recordingId: _session.lastRecordingId,
                  busy: _session.busy,
                  onRetryTranscription: _retryTranscription,
                  onRetrySummary: _retrySummary,
                ),
              ],
              if (processing) ...[
                const SizedBox(height: 18),
                _PipelinePanel(stage: _session.stage),
              ],
              const SizedBox(height: 26),
              _Controls(
                state: state,
                starting: _starting,
                stopping: _stopping,
                onStart: _start,
                onPause: _recorder.pause,
                onResume: _recorder.resume,
                onStop: _stop,
                onCancel: _cancel,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _retryTranscription() async {
    final id = _session.lastRecordingId;
    if (id == null) return;
    await _session.retry(id, 'transcription');
  }

  Future<void> _retrySummary() async {
    final id = _session.lastRecordingId;
    if (id == null) return;
    await _session.retry(id, 'summary');
  }
}

/// The elapsed-time dial.
///
/// A plain, slowly-pulsing ring while recording. Section 15 warns against an
/// over-elaborate animation, and section 37 says reliability outranks visual
/// effects — so the pulse is the only motion, and it stops entirely when
/// paused, which doubles as a second "you are not recording" cue.
class _TimerDial extends StatefulWidget {
  const _TimerDial({required this.state, required this.label});
  final IMeetRecordState state;
  final String label;

  @override
  State<_TimerDial> createState() => _TimerDialState();
}

class _TimerDialState extends State<_TimerDial>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.state == IMeetRecordState.recording) _pulse.repeat();
  }

  @override
  void didUpdateWidget(_TimerDial old) {
    super.didUpdateWidget(old);
    final live = widget.state == IMeetRecordState.recording;
    if (live && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!live && _pulse.isAnimating) {
      // Stop the pulse when paused: a moving ring while paused would be a lie.
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.state == IMeetRecordState.recording;
    final color = switch (widget.state) {
      IMeetRecordState.recording => AppColors.rose,
      IMeetRecordState.paused => AppColors.amber,
      IMeetRecordState.processing => AppColors.accent(context),
      _ => AppColors.textTertiary(context),
    };
    return SizedBox(
      width: 190,
      height: 190,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final t = live ? _pulse.value : 0.0;
          return Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.10 + 0.06 * t),
              border: Border.all(
                color: color.withValues(alpha: 0.35 + 0.35 * t),
                width: 3,
              ),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    live
                        ? Icons.mic
                        : widget.state == IMeetRecordState.paused
                        ? Icons.pause_circle_filled
                        : widget.state == IMeetRecordState.processing
                        ? Icons.hourglass_top
                        : Icons.mic_none,
                    size: 26,
                    color: color,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The current state, in words.
///
/// Section 7/12: the user must ALWAYS know whether the microphone is live.
/// Colour and the pulsing dial are supporting cues; this word is the fact.
class _StateBanner extends StatelessWidget {
  const _StateBanner({required this.state, required this.processing});
  final IMeetRecordState state;
  final bool processing;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (state) {
      IMeetRecordState.recording => (Icons.mic, 'Recording', AppColors.rose),
      IMeetRecordState.paused => (Icons.pause, 'Paused', AppColors.amber),
      IMeetRecordState.stopping => (
        Icons.stop_circle_outlined,
        'Finishing…',
        AppColors.amber,
      ),
      IMeetRecordState.processing => (
        Icons.hourglass_top,
        'Processing your meeting…',
        AppColors.accent(context),
      ),
      IMeetRecordState.idle => (
        Icons.mic_none,
        processing ? 'Starting…' : 'Ready to record',
        AppColors.textTertiary(context),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// The four recording controls, sized for a thumb.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.state,
    required this.starting,
    required this.stopping,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onCancel,
  });

  final IMeetRecordState state;
  final bool starting;
  final bool stopping;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final recording = state == IMeetRecordState.recording;

    if (state == IMeetRecordState.idle) {
      return Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: starting ? null : onStart,
              icon: const Icon(Icons.mic, size: 22),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 15),
                child: Text(starting ? 'Starting…' : 'Start recording'),
              ),
            ),
          ),
        ],
      );
    }

    if (state == IMeetRecordState.processing) {
      return const SizedBox(
        height: 52,
        child: Center(
          child: PageLoadingView(label: 'Uploading and processing…'),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CircleButton(
          icon: Icons.delete_outline,
          label: 'Discard',
          color: AppColors.textTertiary(context),
          onTap: stopping ? null : onCancel,
        ),
        const SizedBox(width: 22),
        _CircleButton(
          icon: recording ? Icons.pause : Icons.play_arrow,
          label: recording ? 'Pause' : 'Resume',
          color: AppColors.amber,
          // 72dp: comfortably above the 48dp minimum touch target.
          size: 72,
          onTap: stopping ? null : (recording ? onPause : onResume),
        ),
        const SizedBox(width: 22),
        _CircleButton(
          icon: Icons.stop,
          label: 'Stop',
          color: AppColors.rose,
          size: 72,
          onTap: stopping ? null : onStop,
        ),
      ],
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.size = 56,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: Material(
            color: color.withValues(alpha: 0.14),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Icon(icon, size: size * 0.45, color: color),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Labels, not just icons: an icon alone is not an accessible control.
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary(context),
          ),
        ),
      ],
    );
  }
}

/// The processing pipeline, shown step by step.
///
/// Section 8: the user must see that something is happening, not wonder. Each
/// stage is ticked as it completes, so the panel doubles as a progress log.
class _PipelinePanel extends StatelessWidget {
  const _PipelinePanel({required this.stage});
  final IMeetStage? stage;

  @override
  Widget build(BuildContext context) {
    // Order matters: this is the real pipeline, not a decorative list.
    final steps = <(String, IMeetStage)>[
      ('Audio uploaded', IMeetStage.transcribing),
      ('Transcript generated', IMeetStage.transcribed),
      ('AI summary generated', IMeetStage.completed),
    ];
    final activeIndex = stage == null
        ? -1
        : steps.indexWhere((s) => s.$2 == stage);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PROCESSING YOUR MEETING',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    if (i < activeIndex)
                      const Icon(
                        Icons.check_circle,
                        size: 16,
                        color: AppColors.green,
                      )
                    else if (i == activeIndex)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        Icons.radio_button_unchecked,
                        size: 16,
                        color: AppColors.textTertiary(context),
                      ),
                    const SizedBox(width: 8),
                    Text(
                      steps[i].$1,
                      style: TextStyle(
                        fontSize: 13,
                        color: i <= activeIndex
                            ? AppColors.textPrimary(context)
                            : AppColors.textTertiary(context),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A failure, with the retry that actually fixes it.
///
/// Section 25: "Recording saved, but transcription could not be completed"
/// plus [Retry] — never a message that forces the user to re-record.
class _FailurePanel extends StatelessWidget {
  const _FailurePanel({
    required this.message,
    required this.transcriptSurvived,
    required this.recordingId,
    required this.busy,
    required this.onRetryTranscription,
    required this.onRetrySummary,
  });

  final String message;

  /// True when the transcript is intact and only the summary failed. The panel
  /// says so explicitly, because "processing failed" would understate it.
  final bool transcriptSurvived;
  final String? recordingId;
  final bool busy;
  final VoidCallback onRetryTranscription;
  final VoidCallback onRetrySummary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.rose.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.rose.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: AppColors.rose,
              ),
              const SizedBox(width: 7),
              Text(
                transcriptSurvived
                    ? 'Summary could not be generated'
                    : 'Processing could not be completed',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(message, style: const TextStyle(fontSize: 12, height: 1.35)),
          if (transcriptSurvived) ...[
            const SizedBox(height: 6),
            Text(
              'Your recording and transcript are safe — only the summary is '
              'missing.',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: busy || recordingId == null
                    ? null
                    : (transcriptSurvived
                          ? onRetrySummary
                          : onRetryTranscription),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(
                  transcriptSurvived ? 'Retry summary' : 'Retry transcription',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
