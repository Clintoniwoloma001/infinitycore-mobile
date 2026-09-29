import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the messaging UI fixes that are easiest to break
/// silently: a hard-coded light colour slipping back into a popup, and
/// "mark all as read" quietly becoming a way to discharge a compliance
/// obligation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Comments explain the intent and legitimately name the table, so strip
  // them before asserting on CODE.
  String code(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  final messages = File(
    'lib/features/messages/create_sheets.dart',
  ).readAsStringSync();
  final notifications = File(
    'lib/features/notifications/notifications_screen.dart',
  ).readAsStringSync();
  final conversation = File(
    'lib/features/messages/conversation_screen.dart',
  ).readAsStringSync();
  final chatScreen = File(
    'lib/features/messages/chat_screen.dart',
  ).readAsStringSync();
  final gate = File(
    'lib/features/messages/urgent_ack_gate.dart',
  ).readAsStringSync();
  final ackService = File(
    'lib/features/messages/acknowledgement_service.dart',
  ).readAsStringSync();

  group('acknowledgement parity — groups/channels behave like DMs', () {
    test('the group/channel screen loads acknowledgment rows', () {
      // The parity defect: chat_screen did this and conversation_screen did
      // not, so a recipient opening the GROUP on mobile saw no acknowledge
      // control on the message while the web client showed one.
      assert(conversation.contains('CommunicationService.instance.acksFor(ids)'));
    });

    test('the group/channel screen offers the inline acknowledge control', () {
      assert(conversation.contains('needsMyAck'));
      assert(conversation.contains('onAcknowledge: needsMyAck'));
      assert(conversation.contains('acks: acks'));
    });

    test('both conversation surfaces acknowledge through the same RPC', () {
      // One shared RPC means the record is per USER, not per device, so web
      // and mobile can never disagree about whether it is satisfied.
      for (final src in [conversation, chatScreen]) {
        expect(
          src.contains('CommunicationService.instance.acknowledgeMessage('),
          isTrue,
          reason: 'both must acknowledge through the shared service',
        );
      }
    });

    test('both surfaces refresh the shared global queue afterwards', () {
      // Otherwise acknowledging inline would leave the global banner showing
      // an obligation the user has already discharged.
      for (final src in [conversation, chatScreen]) {
        assert(src.contains('UrgentAckService.instance.refresh()'));
      }
    });

    test('the sender is excluded, so the control is unreachable for them', () {
      // `ackRequired` already returns false for the sender, which is what
      // keeps requirement 1 ("the sender must never be blocked") true here.
      assert(conversation.contains('CommunicationService.ackRequired(raw'));
    });

    test('ack recipients are resolved so the roster shows names', () {
      assert(conversation.contains("nameFor: (uid) =>"));
      assert(conversation.contains('resolveDirectory('));
    });
  });

  group('the reminder is global, not scoped to one conversation', () {
    test('it is mounted above the router so every route shows it', () {
      final app = File(
        'lib/app/infinity_core_app.dart',
      ).readAsStringSync();
      assert(app.contains('UrgentAckGate(child:'));
    });

    test('it is a banner, not a modal that blocks the app', () {
      assert(gate.contains('class AckReminderBanner'));
      assert(!gate.contains('canPop: false'));
    });

    test('it offers both a view action and an acknowledge action', () {
      assert(gate.contains("'Acknowledge'"));
      assert(gate.contains("'View'"));
    });

    test('dismissal is recorded in the service, not the widget', () {
      // The dismissal state must outlive the banner widget, otherwise it would
      // be forgotten on the next rebuild and could never actually hide it.
      final service = File(
        'lib/features/messages/urgent_ack_service.dart',
      ).readAsStringSync();
      expect(service.contains('void dismissUntil'), isTrue);
      expect(service.contains('_dismissedUntil'), isTrue);
      expect(service.contains('_armResurface'), isTrue);
    });

    test('the resurface window is exactly five minutes', () {
      // Requirement: dismissing is not acknowledgement, and the banner returns
      // after exactly 5 minutes until the message IS acknowledged.
      expect(
        gate.contains('static const resurfaceAfter = Duration(minutes: 5)'),
        isTrue,
      );
    });

    test('dismissal never acknowledges', () {
      // A dismissal must not be able to discharge a compliance obligation.
      final service = File(
        'lib/features/messages/urgent_ack_service.dart',
      ).readAsStringSync();
      final block = service.split('void dismissUntil')[1].split('void ')[0];
      assert(!block.contains('acknowledge'));
      assert(!block.contains('SupabaseService'));
    });
  });

  group('both clients read the same server state', () {
    test('the mobile service uses the shared pending-acks RPC', () {
      assert(ackService.contains("'list_pending_acks_for_me'"));
    });

    test('the mobile service uses the shared rollup RPC', () {
      assert(ackService.contains("'get_ack_rollup'"));
    });

    test('no device-local acknowledgment store exists', () {
      // There is no local cache of acknowledgments anywhere: the server row is
      // the only source of truth, which is what makes the state per user.
      for (final src in [conversation, chatScreen, ackService, gate]) {
        expect(
          src.contains('SharedPreferences'),
          isFalse,
          reason: 'acknowledgment state must never be cached on the device',
        );
      }
    });
  });

  group('dark mode — popups must follow the theme', () {
    test('no modal bottom sheet hard-codes a white background', () {
      // A hard-coded `backgroundColor: Colors.white` on a bottom sheet renders
      // as a white slab in dark mode, which is exactly the reported symptom:
      // the person/search popup stays white and its text is unreadable.
      expect(
        messages.contains('backgroundColor: Colors.white'),
        isFalse,
        reason: 'bottom sheets must use AppColors.surface(context)',
      );
    });

    test('the sheets use the theme-aware surface token instead', () {
      final surfaceUses =
          'backgroundColor: AppColors.surface(context),'.allMatches(messages);
      expect(
        surfaceUses.length,
        greaterThanOrEqualTo(4),
        reason: 'person picker, channel, group and member sheets all themed',
      );
    });

    test('remaining literal whites are only on filled accents', () {
      // What is legitimately left: the spinner glyph and text inside a filled
      // accent-coloured button, and unread badge counts. Those are foreground-
      // on-colour and stay readable in dark mode by construction.
      final offenders = RegExp(
        r'color:\s*Colors\.white',
      ).allMatches(messages).where((m) {
        final before = messages.substring(0, m.start);
        // Look back over the enclosing widget for a filled accent.
        final window = before.split('\n').reversed.take(14).join('\n');
        return !window.contains('CircularProgressIndicator') &&
            !window.contains('backgroundColor: AppColors.accent') &&
            !window.contains('Colors.white');
      });
      expect(
        offenders.isEmpty,
        isTrue,
        reason: 'a literal white must only sit on a filled accent',
      );
    });
  });

  group('mark all as read — never discharges an acknowledgment', () {
    test('the action exists on the notifications screen', () {
      expect(notifications.contains('Mark all as read'), isTrue);
    });

    test('it only updates the read flag, never an acknowledgment', () {
      // chat_message_acks must not appear in CODE. If it ever does, marking
      // notifications read would silently mark compliance records.
      expect(
        code(notifications).contains('chat_message_acks'),
        isFalse,
        reason: 'mark-all-read must not touch acknowledgment records',
      );
      expect(
        code(notifications).contains("status': 'acknowledged'"),
        isFalse,
      );
    });

    test('it refreshes the acknowledgment queue so the obligation stays visible', () {
      // The outstanding banner is driven by UrgentAckService, so the screen
      // re-reads it rather than assuming the obligation is gone.
      expect(
        notifications.contains('UrgentAckService.instance.refresh()'),
        isTrue,
      );
    });

    test('it refreshes the shared badge so counts stay in step', () {
      expect(notifications.contains('NotificationBadge.instance.refresh()'), isTrue);
    });

    test('it is scoped to the signed-in user only', () {
      expect(notifications.contains(".eq('user_id', me)"), isTrue);
    });
  });
}
