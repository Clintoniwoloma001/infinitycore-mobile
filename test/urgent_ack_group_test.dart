import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/features/messages/communication_service.dart';
import 'package:infinitycore/features/messages/message_ui.dart';

/// Regression tests for group acknowledgment semantics.
///
/// `send_rich_message` pre-seeds one `chat_message_acks` row per recipient in
/// `pending` state. Anything that tallies the row *count* therefore reports a
/// broadcast as fully acknowledged the instant it is sent, and never moves
/// again. The obligation is per member and must clear per member.
void main() {
  Map<String, dynamic> pending(String id) => {
    'user_id': id,
    'status': 'pending',
  };
  Map<String, dynamic> done(String id) => {
    'user_id': id,
    'status': 'acknowledged',
    'acknowledged_at': '2026-01-01T10:00:00Z',
  };

  group('the visible tally counts real acknowledgments', () {
    testWidgets('one acknowledgment does not settle a group message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _BubbleHarness(acks: [done('a'), pending('b'), pending('c')]),
      );
      await tester.pump();

      expect(find.textContaining('All 3 acknowledged'), findsNothing);
      expect(find.textContaining('1 of 3 acknowledged'), findsOneWidget);
      // Still outstanding, so the state must not read as settled.
      expect(find.textContaining('2 pending'), findsOneWidget);
    });

    testWidgets('a fully acknowledged message reads as settled', (tester) async {
      await tester.pumpWidget(
        _BubbleHarness(acks: [done('a'), done('b'), done('c')]),
      );
      await tester.pump();

      expect(find.textContaining('All 3 acknowledged'), findsOneWidget);
      expect(find.textContaining('pending'), findsNothing);
    });

    testWidgets('a freshly sent group message is not pre-settled', (
      tester,
    ) async {
      // Every row still pending: the exact state right after sending. This must
      // read as fully outstanding, which is what the old tally got wrong.
      await tester.pumpWidget(
        _BubbleHarness(acks: [pending('a'), pending('b'), pending('c')]),
      );
      await tester.pump();

      expect(find.textContaining('All 3 acknowledged'), findsNothing);
      expect(find.textContaining('0 of 3 acknowledged'), findsOneWidget);
    });
  });

  group('the roster names who is still outstanding', () {
    testWidgets('opening the tally lists names, not ids', (tester) async {
      await tester.pumpWidget(
        _BubbleHarness(
          acks: [done('a'), pending('b'), pending('c')],
          names: {'a': 'Ada', 'b': 'Ben', 'c': 'Cara'},
        ),
      );
      await tester.pump();

      await tester.tap(find.textContaining('1 of 3 acknowledged'));
      await tester.pumpAndSettle();

      expect(find.text('Still outstanding (2)'), findsOneWidget);
      expect(find.text('Acknowledged (1)'), findsOneWidget);
      // Real names, not UUIDs: a sender must know whom to chase.
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('Cara'), findsOneWidget);
      expect(find.text('Ada'), findsOneWidget);
    });

    testWidgets('a single-recipient message is not tappable', (tester) async {
      // A one-to-one acknowledgement has nobody to chase, so the roster is
      // suppressed and the chip renders as plain text.
      await tester.pumpWidget(_BubbleHarness(acks: [pending('a')]));
      await tester.pump();

      await tester.tap(find.textContaining('0 of 1 acknowledged'));
      await tester.pumpAndSettle();
      expect(find.text('Acknowledgment status'), findsNothing);
    });
  });

  group('each recipient owes their own acknowledgment', () {
    final message = {'requires_ack': true, 'sender_id': 'sender'};

    test('one member acknowledging does not clear another', () {
      final acks = [done('a'), pending('b')];
      expect(CommunicationService.ackRequired(message, acks, 'a'), isFalse);
      expect(CommunicationService.ackRequired(message, acks, 'b'), isTrue);
    });

    test('a member with no row at all still owes one', () {
      final acks = [done('a'), pending('b')];
      expect(CommunicationService.ackRequired(message, acks, 'c'), isTrue);
    });

    test('the sender never owes themselves an acknowledgment', () {
      expect(
        CommunicationService.ackRequired(message, [pending('a')], 'sender'),
        isFalse,
      );
    });
  });
}

/// Hosts a [MessageBubble] with the minimum a bubble needs to render.
class _BubbleHarness extends StatelessWidget {
  const _BubbleHarness({required this.acks, this.names = const {}});

  final List<Map<String, dynamic>> acks;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MessageBubble(
            message: const {
              'body': 'Safety briefing at 8am, all staff.',
              'requires_ack': true,
              'priority': 'urgent',
              'sender_id': 'sender',
              'message_type': 'group',
              'created_at': '2026-01-01T09:00:00Z',
            },
            isMine: true,
            senderName: 'Manager',
            attachments: const [],
            reactions: const {},
            myUserId: 'sender',
            acks: acks,
            nameFor: (id) => names[id] ?? '',
            onLongPress: () {},
            onToggleReaction: (_, _) {},
          ),
        ),
      ),
    );
  }
}