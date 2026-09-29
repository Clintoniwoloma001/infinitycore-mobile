// ============================================================================
// I-Meet contract guards
// ============================================================================
// The recording pipeline's product rules are easy to regress silently, because
// most of them are about what the code does NOT do. These tests pin the rules
// that must never break, using the same source-reading approach as
// navigation_wiring_test.dart for the parts that are structural.
//
// The rules under test:
//   9  — a follow-up adds a RECORDING to the same meeting, never a second one
//   10 — a failed summary does not destroy the transcript
//   11 — a failed transcription does not destroy the audio
//   12 — every pipeline stage is observable
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// [haystack] with all runs of whitespace collapsed to a single space.
///
/// The assertions below describe LOGIC, not layout, so they must survive
/// `dart format` reflowing an expression across lines.
String _flat(String haystack) => haystack.replaceAll(RegExp(r'\s+'), ' ');

/// True when [flatNeedle] appears in the whitespace-collapsed [haystack].
bool _has(String haystack, String flatNeedle) =>
    _flat(haystack).contains(flatNeedle);

void main() {
  final sessionSrc = _read('lib/features/imeet/imeet_session.dart');
  final serviceSrc = _read('lib/features/imeet/imeet_service.dart');
  final routerSrc = _read('lib/core/routing/app_router.dart');
  final recordScreenSrc = _read('lib/features/imeet/imeet_record_screen.dart');
  final homeScreenSrc = _read('lib/features/imeet/imeet_home_screen.dart');
  final destSrc = _read('lib/core/routing/app_destinations.dart');
  final recorderSrc = _read('lib/features/imeet/imeet_recorder.dart');
  final meetingScreenSrc = _read(
    'lib/features/imeet/imeet_meeting_screen.dart',
  );

  group('A follow-up stays inside its meeting (rule 9)', () {
    test('the follow-up route carries the meeting id, not a new one', () {
      expect(
        _has(meetingScreenSrc, "'/imeet/record'"),
        isTrue,
        reason: 'the recording screen must be reachable to attach a follow-up',
      );
      expect(
        _has(meetingScreenSrc, "'meetingId': widget.meetingId"),
        isTrue,
        reason:
            'the meeting id must be forwarded so the server appends a recording '
            'instead of opening a second meeting',
      );
    });

    test('a supplied meeting id suppresses the new-meeting open', () {
      expect(
        recordScreenSrc,
        contains('_isFollowUp'),
        reason:
            'the screen must branch on whether a meeting id was supplied, or a '
            'follow-up would silently fork a duplicate meeting',
      );
    });

    test('the meeting screen offers a follow-up on the same meeting', () {
      expect(
        meetingScreenSrc,
        contains('_recordFollowUp'),
        reason: 'a completed meeting must be able to take a follow-up',
      );
    });
  });

  group('A failed stage never destroys the work that succeeded (10/11)', () {
    test('the summary is retried independently of transcription', () {
      expect(
        _has(sessionSrc, "stage == 'summary' ? IMeetStage.summarising"),
        isTrue,
        reason:
            'a summary retry must not re-run transcription; the transcript is '
            'already good and re-running it risks a different answer',
      );
    });

    test('a partial success is distinguished from a total failure', () {
      expect(
        sessionSrc,
        contains('transcriptSurvived'),
        reason:
            'when only the summary failed, the UI must be able to say the '
            'transcript is safe rather than reporting a blanket failure',
      );
    });

    test('a failed upload keeps the audio on disk and says so', () {
      expect(
        sessionSrc,
        contains('saved on this device but could not be uploaded'),
        reason:
            'losing a recorded meeting to a network blip is the one outcome this '
            'module must never produce',
      );
    });

    test('failure is reported honestly through a notification', () {
      expect(
        serviceSrc,
        contains('notifyFailed'),
        reason: 'a failed pipeline must not silently look like a success',
      );
    });
  });

  group('Every stage is observable (rule 12)', () {
    test('the UI renders a per-stage progress panel', () {
      expect(
        recordScreenSrc,
        contains('PROCESSING YOUR MEETING'),
        reason:
            'the user must be able to see that work is happening rather than '
            'wondering whether the app hung',
      );
    });

    test('the progress panel follows the real pipeline order', () {
      // Upload -> transcript -> summary. Reordering these would misreport what
      // the backend is actually doing.
      final upload = recordScreenSrc.indexOf('Audio uploaded');
      final transcript = recordScreenSrc.indexOf('Transcript generated');
      final summary = recordScreenSrc.indexOf('AI summary generated');
      expect(upload, greaterThan(-1));
      expect(transcript, greaterThan(upload));
      expect(summary, greaterThan(transcript));
    });
  });

  group('A failure is always paired with a way to fix it (section 25)', () {
    test('both retry paths are offered', () {
      expect(recordScreenSrc, contains('Retry transcription'));
      expect(recordScreenSrc, contains('Retry summary'));
    });

    test(
      'discarding asks first, so a long meeting is not lost by a mis-tap',
      () {
        expect(
          recordScreenSrc,
          contains('Discard this recording?'),
          reason: 'an accidental tap must not throw away a recorded meeting',
        );
      },
    );
  });

  group('Recording state is never ambiguous (rule 12)', () {
    test('the state is an enum, not a pair of booleans', () {
      expect(
        recorderSrc,
        contains('enum IMeetRecordState'),
        reason:
            'a bool pair admits the impossible "paused and recording" state, '
            'which is exactly what rule 12 forbids',
      );
    });

    test(
      'the live microphone state is stated in words, not only by colour',
      () {
        expect(
          recordScreenSrc,
          contains("'Recording'"),
          reason: 'colour and a pulsing ring are supporting cues, not the fact',
        );
      },
    );

    test('permission is checked before recording starts', () {
      expect(
        recorderSrc,
        contains('hasPermission'),
        reason: 'a denial must be explained, not appear as a silent failure',
      );
    });
  });

  group('I-Meet is reachable from navigation', () {
    test('the menu entry exists and points at a real route', () {
      expect(destSrc, contains("id: 'imeet'"));
      expect(destSrc, contains("route: '/imeet'"));
    });

    test('all three routes are registered', () {
      expect(routerSrc, contains("path: '/imeet'"));
      expect(routerSrc, contains("path: '/imeet/record'"));
      expect(routerSrc, contains("path: '/imeet/:meetingId'"));
    });

    test('the record route is declared BEFORE the parameter route', () {
      // go_router matches in declaration order. The reverse order would let
      // `:meetingId` swallow the literal path "record", making the recording
      // screen unreachable from every entry point.
      final record = routerSrc.indexOf("path: '/imeet/record'");
      final param = routerSrc.indexOf("path: '/imeet/:meetingId'");
      expect(record, greaterThan(-1));
      expect(param, greaterThan(-1));
      expect(
        record,
        lessThan(param),
        reason: "':meetingId' would capture 'record' if declared first",
      );
    });

    test('the home screen can start a recording', () {
      expect(
        homeScreenSrc,
        contains("'/imeet/record'"),
        reason: 'the primary action of the module must be reachable',
      );
    });
  });
}
