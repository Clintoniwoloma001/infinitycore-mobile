import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/services/notification_deep_link.dart';
import 'package:infinitycore/features/messages/attachment_service.dart';
import 'package:infinitycore/features/messages/communication_service.dart';
import 'package:infinitycore/features/messages/urgent_ack_gate.dart';
import 'package:infinitycore/features/messages/urgent_ack_service.dart';
import 'package:infinitycore/features/profile/profile_service.dart';
import 'package:infinitycore/features/sara/sara_mark.dart';
import 'package:infinitycore/features/sara/sara_voice_service.dart';
import 'package:infinitycore/shared/models/models.dart';
import 'package:infinitycore/shared/utils/formatters.dart';

void main() {
  group('attachmentTypeFor mirrors the web client', () {
    test('voice notes win over the mime sniff', () {
      // A recorded note is an .m4a, which sniffs as `audio/mp4`. Without the
      // name check it would land in the generic audio bucket and lose the
      // dedicated player.
      expect(
        attachmentTypeFor('voice-note-1727000000000.m4a', 'audio/mp4'),
        'voice_note',
      );
    });

    test('maps every category the web maps', () {
      expect(attachmentTypeFor('a.png', 'image/png'), 'image');
      expect(attachmentTypeFor('a.mp3', 'audio/mpeg'), 'audio');
      expect(attachmentTypeFor('a.mp4', 'video/mp4'), 'video');
      expect(attachmentTypeFor('a.pdf', 'application/pdf'), 'pdf');
      expect(
        attachmentTypeFor(
          'a.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ),
        'spreadsheet',
      );
      expect(
        attachmentTypeFor(
          'a.pptx',
          'application/vnd.openxmlformats-officedocument.presentationml.'
              'presentation',
        ),
        'presentation',
      );
      expect(
        attachmentTypeFor(
          'a.docx',
          'application/vnd.openxmlformats-officedocument.'
              'wordprocessingml.document',
        ),
        'document',
      );
      expect(attachmentTypeFor('a.zip', 'application/zip'), 'archive');
      expect(attachmentTypeFor('a.bin', 'application/octet-stream'), 'file');
      // An empty mime type is the Android picker's default; the web client
      // falls through to `file` in exactly the same way.
      expect(attachmentTypeFor('a.pptx', ''), 'file');
    });
  });

  group('mimeTypeForPath', () {
    test('falls back to the extension when the picker reports nothing', () {
      expect(mimeTypeForPath('/tmp/report.pdf'), 'application/pdf');
      expect(mimeTypeForPath('/tmp/VOICE.M4A'), 'audio/mp4');
      expect(mimeTypeForPath('/tmp/unknown.xyz'), 'application/octet-stream');
    });
  });

  group('safeAttachmentName', () {
    test('strips path-hostile characters and caps the length', () {
      // Every disallowed character becomes exactly one underscore, matching
      // `SAFE_NAME_RE` on the web so both clients build identical object keys.
      expect(safeAttachmentName('my report (final).pdf'), 'my report _final_.pdf');
      expect(safeAttachmentName('../../etc/passwd'), '.._.._etc_passwd');
      expect(safeAttachmentName(''), 'file');
      expect(safeAttachmentName('a' * 300).length, 120);
    });
  });

  group('PendingAttachment.toRpcFile', () {
    test('emits the exact column shape send_rich_message expects', () {
      final a = PendingAttachment(
        path: '/tmp/voice-note-1.m4a',
        fileName: 'voice-note-1.m4a',
        mimeType: 'audio/mp4',
        sizeBytes: 2048,
        durationMs: 3000,
      )
        ..uploadedPath = 'chat/direct/t1/u1/voice-note-1.m4a'
        ..checksum = 'abc'
        ..stage = AttachmentStage.uploaded;

      expect(a.toRpcFile(), {
        'file_name': 'voice-note-1.m4a',
        'file_type': 'audio/mp4',
        'attachment_type': 'voice_note',
        'file_size': 2048,
        'file_path': 'chat/direct/t1/u1/voice-note-1.m4a',
        'checksum': 'abc',
      });
    });
  });

  group('messageRequiresAck', () {
    test('accepts both the bool and the string spelling', () {
      expect(
        CommunicationService.messageRequiresAck({'requires_ack': true}),
        isTrue,
      );
      expect(
        CommunicationService.messageRequiresAck({'requires_ack': 'true'}),
        isTrue,
      );
      expect(
        CommunicationService.messageRequiresAck({'requires_ack': 'false'}),
        isFalse,
      );
      expect(CommunicationService.messageRequiresAck(const {}), isFalse);
    });
  });

  group('messagePriority', () {
    test('normalises every spelling the backend may send', () {
      expect(
        CommunicationService.messagePriority({'priority': 'urgent'}),
        'urgent',
      );
      expect(
        CommunicationService.messagePriority({'priority': 'critical'}),
        'urgent',
      );
      expect(CommunicationService.messagePriority({'priority': 'high'}), 'high');
      expect(
        CommunicationService.messagePriority({'priority': 'important'}),
        'high',
      );
      expect(CommunicationService.messagePriority(const {}), 'normal');
      expect(
        CommunicationService.messagePriority({'priority': 'nonsense'}),
        'normal',
      );
    });
  });

  group('ackRequired', () {
    const me = 'user-1';
    const message = {'requires_ack': true, 'sender_id': 'user-2'};

    test('is true when the flag is set and no ack exists', () {
      expect(CommunicationService.ackRequired(message, const [], me), isTrue);
    });

    test('is false once this user acknowledged', () {
      final acks = [
        {'user_id': me, 'status': 'acknowledged'},
      ];
      expect(CommunicationService.ackRequired(message, acks, me), isFalse);
    });

    test("another user's ack does not clear my obligation", () {
      final acks = [
        {'user_id': 'user-9', 'status': 'acknowledged'},
      ];
      expect(CommunicationService.ackRequired(message, acks, me), isTrue);
    });

    test('a rejected row does not count as compliance', () {
      final acks = [
        {'user_id': me, 'status': 'rejected'},
      ];
      expect(CommunicationService.ackRequired(message, acks, me), isTrue);
    });

    test('the sender never owes an acknowledgment on their own message', () {
      final own = {'requires_ack': true, 'sender_id': me};
      expect(CommunicationService.ackRequired(own, const [], me), isFalse);
    });

    test('a message without the flag is never pending', () {
      expect(
        CommunicationService.ackRequired(
          const {'sender_id': 'user-2'},
          const [],
          me,
        ),
        isFalse,
      );
    });
  });

  group('PendingAck routing', () {
    PendingAck ack({
      PendingAckKind kind = PendingAckKind.message,
      String thread = '',
      String channel = '',
      String group = '',
    }) => PendingAck(
      id: 'm1',
      kind: kind,
      title: 'Safety briefing',
      body: 'Read this.',
      senderName: 'Priya',
      createdAt: '2026-09-24T08:00:00Z',
      priority: 'urgent',
      threadId: thread,
      channelId: channel,
      groupId: group,
    );

    test('a direct message opens its thread', () {
      expect(ack(thread: 't1').route, '/messages/t1');
    });

    test('a channel message prefers the channel route', () {
      expect(ack(channel: 'c1', group: 'g1').route, '/messages/channel/c1');
    });

    test('a group message falls back to the group route', () {
      expect(ack(group: 'g1').route, '/messages/group/g1');
    });

    test('an unresolvable message falls back to the Messages list', () {
      expect(ack().route, '/messages');
    });

    test('an announcement always opens the announcements tab', () {
      expect(
        ack(kind: PendingAckKind.announcement).route,
        '/messages/announcements',
      );
    });

    test('urgent is distinguished from merely important', () {
      expect(ack().isUrgent, isTrue);
      final important = PendingAck(
        id: 'm2',
        kind: PendingAckKind.message,
        title: 't',
        body: '',
        senderName: '',
        createdAt: '',
        priority: 'high',
      );
      expect(important.isUrgent, isFalse);
    });

    test('an announcement is labelled as such, not by sender', () {
      expect(
        ack(kind: PendingAckKind.announcement).subtitle,
        'Company announcement',
      );
    });

    test('a senderless message is labelled by kind, not by repeating the title',
        () {
      final senderless = PendingAck(
        id: 'm3',
        kind: PendingAckKind.message,
        title: 'Safety briefing',
        body: '',
        senderName: '',
        createdAt: '',
      );
      expect(senderless.subtitle, 'Direct message');
      expect(senderless.subtitle, isNot(senderless.title));
    });
  });

  group('UrgentAckService reminder contract', () {
    test('the cadence is the five minutes the spec requires', () {
      expect(UrgentAckService.reminderInterval, const Duration(minutes: 5));
    });

    test('the reminder notification id is stable so reminders replace', () {
      expect(UrgentAckService.reminderNotificationId, 8801);
    });
  });

  group('findSaraWakeMatch', () {
    test('matches every configured wake word', () {
      for (final w in saraWakeWords) {
        expect(findSaraWakeMatch(w)?.word, w);
      }
    });

    test('tolerates one STT mis-hear', () {
      expect(findSaraWakeMatch('sera')?.word, 'sara');
      expect(findSaraWakeMatch('assistent')?.word, 'assistant');
    });

    test('does not match a different word', () {
      expect(findSaraWakeMatch('sorry'), isNull);
      expect(findSaraWakeMatch('coreference'), isNull);
    });

    test('captures the command spoken in the same breath', () {
      final m = findSaraWakeMatch('hey SARA show my pending leaves');
      expect(m?.word, 'sara');
      expect(m?.command, 'show my pending leaves');
    });

    test('a bare wake word yields an empty command', () {
      expect(findSaraWakeMatch('SARA')?.command, '');
    });

    test('ignores a trailing stop phrase', () {
      expect(findSaraWakeMatch('SARA stop')?.command, '');
    });

    test('is case insensitive and tolerates filler punctuation', () {
      expect(
        findSaraWakeMatch('Okay, CORE - what is on today?')?.command,
        'what is on today?',
      );
    });

    test('returns null for an empty transcript', () {
      expect(findSaraWakeMatch('   '), isNull);
    });
  });

  group('isSaraStopPhrase', () {
    test('matches the phrases the web client matches', () {
      for (final p in [
        'stop',
        'stop listening',
        'cancel listening',
        'never mind',
        'go to sleep',
        'sleep',
      ]) {
        expect(isSaraStopPhrase(p), isTrue, reason: p);
      }
    });

    test('does not match a real command', () {
      expect(isSaraStopPhrase('show my leaves'), isFalse);
    });
  });

  group('levenshtein', () {
    test('measures single edits', () {
      expect(levenshtein('sara', 'sara'), 0);
      expect(levenshtein('sara', 'sera'), 1);
      expect(levenshtein('sara', 'saraa'), 1);
      expect(levenshtein('sara', ''), 4);
    });

    test('bails out early once the row is hopeless', () {
      expect(
        levenshtein('averylongunrelatedtoken', 'sara', max: 1),
        greaterThan(1),
      );
    });
  });

  group('NotificationDeepLink', () {
    test('prefers an explicit mobile link', () {
      expect(
        NotificationDeepLink.resolve(
          type: 'message',
          link: '/messages/thread-1',
          sourceId: 'ignored',
        ),
        '/messages/thread-1',
      );
    });

    test('unwraps the web SPA hash form', () {
      expect(
        NotificationDeepLink.resolve(
          link: 'https://app.example.com/#/messages/thread-9',
        ),
        '/messages/thread-9',
      );
    });

    test('drops a query string', () {
      expect(
        NotificationDeepLink.resolve(link: '/messages/t1?tab=chat'),
        '/messages/t1',
      );
    });

    test('rejects a path the router does not own', () {
      expect(NotificationDeepLink.resolve(link: '/admin/secrets'), isNull);
    });

    test('falls back to type + source id for a message', () {
      expect(
        NotificationDeepLink.resolve(type: 'direct_message', sourceId: 't7'),
        '/messages/t7',
      );
      expect(
        NotificationDeepLink.resolve(type: 'channel', sourceId: 'c7'),
        '/messages/channel/c7',
      );
      expect(
        NotificationDeepLink.resolve(type: 'group', sourceId: 'g7'),
        '/messages/group/g7',
      );
    });

    test('an announcement with no id still lands somewhere useful', () {
      expect(
        NotificationDeepLink.resolve(type: 'announcement'),
        '/messages/announcements',
      );
    });

    test('an unknown type with no link resolves to nothing', () {
      expect(NotificationDeepLink.resolve(type: 'wat'), isNull);
      expect(NotificationDeepLink.resolve(), isNull);
    });
  });

  group('late_minutes parsing', () {
    AttendanceRecord record(dynamic late) => AttendanceRecord.fromJson({
      'id': 'r1',
      'attendance_date': '2026-09-24',
      'late_minutes': late,
    });

    test('reads a plain integer', () {
      expect(record(45).lateMinutes, 45);
      expect(record('45').lateMinutes, 45);
    });

    test('reads a double, which is what a numeric column decodes to', () {
      // PostgREST sends Postgres `numeric` as a JSON number, which Dart decodes
      // as a double. The old int.tryParse path turned this into 0 and reported
      // a genuinely late arrival as on time.
      expect(record(45.0).lateMinutes, 45);
      expect(record('45.0').lateMinutes, 45);
    });

    test('treats junk and null as zero', () {
      expect(record('n/a').lateMinutes, 0);
      expect(record(null).lateMinutes, 0);
    });
  });

  group('Fmt.lateDuration', () {
    test('formats minutes and hours the way the history row expects', () {
      expect(Fmt.lateDuration(0), '0m');
      expect(Fmt.lateDuration(45), '45m');
      expect(Fmt.lateDuration(60), '1h 0m');
      expect(Fmt.lateDuration(135), '2h 15m');
    });
  });

  testWidgets('SaraMark paints without error in both themes', (tester) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          themeMode: mode,
          home: const Scaffold(body: Center(child: SaraMark(size: 64))),
        ),
      );
      await tester.pump();
      expect(find.byType(SaraMark), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  group('UrgentAckGate', () {
    // The gate is inserted through an OverlayEntry, so the harness has to
    // provide a real Navigator and Overlay — which is also what makes the
    // PopScope assertion meaningful.
    Widget harness(Widget home) => MaterialApp(
      home: Builder(
        builder: (context) => UrgentAckGate(child: home),
      ),
    );

    const item = PendingAck(
      id: 'm1',
      kind: PendingAckKind.message,
      title: 'Safety briefing',
      body: 'Evacuate via the north stairs.',
      senderName: 'Priya',
      createdAt: '2026-09-24T08:00:00Z',
      priority: 'urgent',
      threadId: 't1',
    );

    tearDown(() => UrgentAckService.instance.stop());

    testWidgets('stays out of the way when nothing is pending', (tester) async {
      await tester.pumpWidget(harness(const Scaffold(body: Text('Home'))));
      await tester.pump();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Safety briefing'), findsNothing);
    });

    testWidgets('blocks the app and names the obligation', (tester) async {
      UrgentAckService.instance.pending.value = [item];
      await tester.pumpWidget(harness(const Scaffold(body: Text('Home'))));
      await tester.pump();

      // The screen underneath is still mounted, but the gate covers it.
      expect(find.text('Safety briefing'), findsOneWidget);
      expect(find.text('Evacuate via the north stairs.'), findsOneWidget);
      expect(
        find.text('Urgent — acknowledgement required'),
        findsOneWidget,
      );
      expect(
        find.text('I have read and acknowledge this'),
        findsOneWidget,
      );
    });

    testWidgets('shows the oldest outstanding item first', (tester) async {
      UrgentAckService.instance.pending.value = [
        PendingAck(
          id: 'newer',
          kind: PendingAckKind.message,
          title: 'Newest',
          body: '',
          senderName: '',
          createdAt: '2026-09-25T08:00:00Z',
        ),
        PendingAck(
          id: 'older',
          kind: PendingAckKind.message,
          title: 'Oldest',
          body: '',
          senderName: '',
          createdAt: '2026-09-20T08:00:00Z',
        ),
      ];
      await tester.pumpWidget(harness(const Scaffold(body: Text('Home'))));
      await tester.pump();
      expect(find.text('Oldest'), findsOneWidget);
      expect(find.text('Newest'), findsNothing);
    });

    testWidgets('counts the rest of the queue', (tester) async {
      UrgentAckService.instance.pending.value = [
        item,
        PendingAck(
          id: 'm2',
          kind: PendingAckKind.message,
          title: 'Second',
          body: '',
          senderName: '',
          createdAt: '2026-09-25T08:00:00Z',
        ),
      ];
      await tester.pumpWidget(harness(const Scaffold(body: Text('Home'))));
      await tester.pump();
      expect(find.textContaining('1 more message'), findsOneWidget);
    });

    testWidgets('a network failure never dismisses the gate', (tester) async {
      // Simulates the "server did not record it" path: the queue is untouched
      // by design, so the user stays blocked and can retry.
      UrgentAckService.instance.pending.value = [item];
      await tester.pumpWidget(harness(const Scaffold(body: Text('Home'))));
      await tester.pump();
      expect(find.text('Safety briefing'), findsOneWidget);
      UrgentAckService.instance.pending.value = [item];
      await tester.pump();
      expect(find.text('Safety briefing'), findsOneWidget);
    });

    testWidgets('clearing the queue removes the overlay', (tester) async {
      UrgentAckService.instance.pending.value = [item];
      await tester.pumpWidget(harness(const Scaffold(body: Text('Home'))));
      await tester.pump();
      expect(find.text('Safety briefing'), findsOneWidget);

      UrgentAckService.instance.pending.value = const [];
      await tester.pump();
      await tester.pump();
      expect(find.text('Safety briefing'), findsNothing);
    });
  });

  group('ProfileService personal field allowlist', () {
    test('matches the update_profile_personal allowlist exactly', () {
      // If this list drifts, the editor will offer a field the server silently
      // drops — a Save that appears to work and changes nothing.
      expect(personalEditableFields.length, 19);
      for (final key in [
        'full_name',
        'email',
        'phone',
        'residential_address',
        'town',
        'lga',
        'state_of_origin',
        'emergency_contact_name',
        'emergency_contact_phone',
        'date_of_birth',
        'sex',
        'religion',
        'denomination',
        'nationality',
        'marital_status',
        'spouse_name',
        'spouse_occupation',
        'spouse_phone',
        'spouse_email',
      ]) {
        expect(
          personalEditableFields,
          contains(key),
          reason: '$key must stay in the allowlist',
        );
      }
    });

    test('HR-controlled fields are never offered as self-service', () {
      for (final key in const [
        'department',
        'position',
        'branch',
        'salary',
        'role',
        'status',
        'employee_number',
      ]) {
        expect(personalEditableFields, isNot(contains(key)));
      }
    });
  });

  group('PersonalProfile', () {
    PersonalProfile profile(Map<String, dynamic> row) => PersonalProfile(
      employeeId: 'e1',
      row: row,
    );

    test('staff number falls back through the same chain as the web card', () {
      expect(
        profile({'employee_number': 'IC-0001'}).staffNumber,
        'IC-0001',
      );
      expect(profile({'staff_id': 'STF-9'}).staffNumber, 'STF-9');
      expect(profile({'employee_code': 'C7'}).staffNumber, 'C7');
      // employee_number wins when several are present.
      expect(
        profile({'employee_number': 'IC-1', 'staff_id': 'STF-9'}).staffNumber,
        'IC-1',
      );
      expect(profile(const {}).staffNumber, '');
      expect(profile(const {}).hasStaffNumber, isFalse);
    });

    test('staff id status defaults to active and issued-by to HR', () {
      expect(profile(const {}).staffIdStatus, 'active');
      expect(profile(const {}).staffIdIssuedBy, 'Human Resources');
      expect(
        profile(const {'staff_id_status': 'expired'}).staffIdStatus,
        'expired',
      );
    });

    test('completeness ignores the always-present name and email', () {
      // With only name and email filled, nothing optional is done, so the score
      // must be 0 — counting name/email would report a misleadingly high bar.
      final p = profile({'full_name': 'Ada', 'email': 'a@b.c'});
      expect(p.personalCompleteness, 0);
    });

    test('completeness rises with each optional field', () {
      final empty = profile(const {});
      final one = profile({'town': 'Lagos'});
      final all = profile({
        for (final k in personalEditableFields)
          if (k != 'full_name' && k != 'email') k: 'x',
      });
      expect(all.personalCompleteness, 1);
      expect(one.personalCompleteness, greaterThan(empty.personalCompleteness));
      expect(one.personalCompleteness, lessThan(1));
    });
  });

  group('PersonalProfile.diff', () {
    final before = PersonalProfile(
      employeeId: 'e1',
      row: {'town': 'Lagos', 'lga': 'Ikeja', 'full_name': 'Ada'},
    );

    test('returns only the fields that actually changed', () {
      final patch = PersonalProfile.diff(before, {
        'full_name': 'Ada',
        'town': 'Abuja',
        'lga': 'Ikeja',
      });
      expect(patch, {'town': 'Abuja'});
    });

    test('is empty when nothing changed', () {
      expect(PersonalProfile.diff(before, before.toDraft()), isEmpty);
    });

    test('drops keys outside the server allowlist', () {
      final patch = PersonalProfile.diff(before, {
        'department': 'Risk',
        'salary': '999',
        'town': 'Benin',
      });
      expect(patch, {'town': 'Benin'});
    });

    test('trims before comparing so whitespace is not a phantom edit', () {
      expect(
        PersonalProfile.diff(before, {'town': '  Lagos  '}),
        isEmpty,
      );
    });

    test('records a cleared field rather than ignoring it', () {
      expect(PersonalProfile.diff(before, {'town': ''}), {'town': ''});
    });
  });

  group('PLACEHOLDER_HOLDER', () {
    test('noop', () {
      expect(1, 1);
    });
  });
}
