import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/features/messages/acknowledgement_service.dart';
import 'package:infinitycore/features/messages/communication_service.dart';

/// Cross-platform contract tests for the acknowledgement lifecycle.
///
/// These assert the rules BOTH clients share, so web and mobile cannot drift:
/// an identical audience, an identical denominator, identical wording and
/// identical push copy. The server freezes the audience at send time, so
/// everything here derives from seeded rows rather than live membership.
void main() {
  const me = 'me';
  const them = 'them';
  const other = 'other';

  const important = {
    'requires_ack': true,
    'priority': 'high',
    'sender_id': them,
  };
  const urgent = {
    'requires_ack': true,
    'priority': 'urgent',
    'sender_id': them,
  };
  const normal = {
    'requires_ack': false,
    'priority': 'normal',
    'sender_id': them,
  };

  Map<String, dynamic> ack(String id, String status) => {
    'user_id': id,
    'status': status,
  };

  group('point 12 — priority drives the requirement', () {
    test('normal never requires acknowledgment', () {
      expect(AcknowledgementService.requiresAck(normal), isFalse);
      expect(
        AcknowledgementService.ackRequiredByMe(normal, const [], me),
        isFalse,
      );
    });

    test('important and urgent both require acknowledgment', () {
      expect(AcknowledgementService.requiresAck(important), isTrue);
      expect(AcknowledgementService.requiresAck(urgent), isTrue);
    });

    test('priority is normalised across both platforms', () {
      expect(AcknowledgementService.priority({'priority': 'urgent'}), 'urgent');
      expect(
        AcknowledgementService.priority({'priority': 'important'}),
        'high',
      );
      expect(AcknowledgementService.priority({'priority': 'high'}), 'high');
      expect(AcknowledgementService.priority(const {}), 'normal');
    });
  });

  group('point 1 — the sender is never blocked', () {
    const mine = {'requires_ack': true, 'priority': 'urgent', 'sender_id': me};

    test('a sender owes nothing for their own urgent message', () {
      expect(AcknowledgementService.isOwn(mine, me), isTrue);
      expect(
        AcknowledgementService.ackRequiredByMe(mine, [ack(me, 'pending')], me),
        isFalse,
      );
    });

    test('a recipient of that same message does owe one', () {
      expect(
        AcknowledgementService.ackRequiredByMe(
          mine,
          [ack(me, 'pending')],
          them,
        ),
        isTrue,
      );
    });
  });

  group('point 2 — acknowledgment is per user and durable', () {
    test('acknowledging is sticky', () {
      expect(
        AcknowledgementService.ackRequiredByMe(
          important,
          [ack(me, 'acknowledged')],
          me,
        ),
        isFalse,
      );
    });

    test('one member acknowledging does not clear another', () {
      final rows = [ack(them, 'acknowledged'), ack(other, 'pending')];
      expect(
        AcknowledgementService.ackRequiredByMe(important, rows, them),
        isFalse,
      );
      expect(
        AcknowledgementService.ackRequiredByMe(important, rows, other),
        isTrue,
      );
    });

    test('a member with no seeded row still owes one', () {
      expect(
        AcknowledgementService.ackRequiredByMe(
          important,
          [ack(them, 'acknowledged')],
          other,
        ),
        isTrue,
      );
    });
  });

  group('point 4 — the audience is frozen at creation', () {
    test('a brand-new broadcast is outstanding, not settled', () {
      // Every recipient already holds a `pending` row, so a fresh group
      // message must read as fully outstanding.
      final s = AcknowledgementService.summarize({
        'total': 3,
        'acknowledged': 0,
        'pending': 3,
      });
      expect(s.total, 3);
      expect(s.done, 0);
      expect(s.complete, isFalse);
    });

    test('partial progress is not complete', () {
      final s = AcknowledgementService.summarize({
        'total': 3,
        'acknowledged': 2,
        'pending': 1,
      });
      expect(s.done, 2);
      expect(s.pending, 1);
      expect(s.complete, isFalse);
    });

    test('every recipient acknowledging completes the ledger', () {
      final s = AcknowledgementService.summarize({
        'total': 2,
        'acknowledged': 2,
        'pending': 0,
      });
      expect(s.complete, isTrue);
    });

    test('an empty audience is never reported as complete', () {
      // "Complete" for a message nobody was seeded for would be misleading.
      final s = AcknowledgementService.summarize({
        'total': 0,
        'acknowledged': 0,
        'pending': 0,
      });
      expect(s.complete, isFalse);
    });

    test('the two rosters come back separated', () {
      final rollup = {
        'acknowledged_list': [
          {'user_id': them, 'acknowledged_at': '2026-01-01T10:00:00Z'},
        ],
        'pending_list': [
          {'user_id': other},
        ],
      };
      final acked = AcknowledgementService.acknowledgedList(rollup);
      final waiting = AcknowledgementService.pendingList(rollup);
      expect(acked.length, 1);
      expect(acked.first['user_id'], them);
      expect(acked.first['acknowledged_at'], isNotNull);
      expect(waiting.length, 1);
      expect(waiting.first['user_id'], other);
    });
  });

  group('point 10 — push copy is identical on both platforms', () {
    test('urgent wording', () {
      final copy = AcknowledgementService.notificationCopy(
        priority: 'urgent',
        senderName: 'Priya',
      );
      expect(copy.title, 'URGENT MESSAGE');
      expect(
        copy.body,
        'Priya sent you an urgent message. Acknowledgement required.',
      );
    });

    test('important wording', () {
      final copy = AcknowledgementService.notificationCopy(
        priority: 'high',
        senderName: 'Priya',
      );
      expect(copy.title, 'IMPORTANT MESSAGE');
      expect(
        copy.body,
        'Priya sent you an important message. Acknowledgement required.',
      );
    });

    test('an unknown sender still reads as a sentence', () {
      final copy = AcknowledgementService.notificationCopy(
        priority: 'urgent',
        senderName: '',
      );
      expect(copy.body, startsWith('Someone sent you an urgent message.'));
    });
  });

  group('point 11 — deep links reach the right conversation', () {
    test('a direct message opens the thread, focused', () {
      expect(
        AcknowledgementService.deepLinkFor({
          'message_id': 'm1',
          'thread_id': 't1',
        }),
        '/messages/t1?focus=m1',
      );
    });

    test('a group message opens the group', () {
      expect(
        AcknowledgementService.deepLinkFor({
          'message_id': 'm2',
          'group_id': 'g1',
        }),
        '/messages/group/g1?focus=m2',
      );
    });

    test('a channel message opens the channel', () {
      expect(
        AcknowledgementService.deepLinkFor({
          'message_id': 'm3',
          'channel_id': 'c1',
        }),
        '/messages/channel/c1?focus=m3',
      );
    });

    test('an unresolvable message falls back to Messages, never nowhere', () {
      expect(
        AcknowledgementService.deepLinkFor(const {'message_id': 'm4'}),
        '/messages',
      );
    });
  });

  group('the shared rules match the web contract', () {
    test('ackRequired applies the same sender rule as the web client', () {
      final message = {'requires_ack': true, 'sender_id': them};
      expect(
        CommunicationService.ackRequired(message, [ack(me, 'pending')], me),
        isTrue,
      );
      expect(
        CommunicationService.ackRequired(message, [ack(me, 'pending')], them),
        isFalse,
      );
    });
  });
}
