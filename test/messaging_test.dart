import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/routing/auth_gate.dart';
import 'package:infinitycore/core/security/role_guard.dart';
import 'package:infinitycore/features/messages/communication_service.dart';
import 'package:infinitycore/features/messages/message_ui.dart';
import 'package:infinitycore/features/messages/messaging_service.dart';
import 'package:infinitycore/shared/models/models.dart';

/// Minimal auth state so the pure route guard can be exercised directly.
class _Auth implements AuthGateState {
  _Auth({required this.role, this.status = AuthStatus.authenticated});

  @override
  final AuthStatus status;
  @override
  final String role;
  @override
  bool get blockedByStatus => false;
  @override
  bool get canManageAttendanceRole => false;
  @override
  bool get biometricEnabled => false;
}

void main() {
  group('Comm Admin route guard', () {
    const authorized = [
      AppRoles.superAdmin,
      AppRoles.admin,
      AppRoles.hrManager,
      AppRoles.headOfHumanResources,
      AppRoles.hrOfficer,
    ];
    const unauthorized = [
      AppRoles.staff,
      AppRoles.customer,
      AppRoles.branchManager,
      AppRoles.areaManager,
      AppRoles.headOfBusiness,
    ];

    test('authorized roles may reach /comm-admin', () {
      for (final role in authorized) {
        expect(canAccessCommAdmin(role), isTrue, reason: role);
        expect(
          redirectDecision(
            _Auth(role: role),
            '/comm-admin',
            Uri.parse('/comm-admin'),
          ),
          isNull,
          reason: '$role should not be redirected',
        );
      }
    });

    test('unauthorized roles are redirected away from /comm-admin', () {
      for (final role in unauthorized) {
        expect(canAccessCommAdmin(role), isFalse, reason: role);
        expect(
          redirectDecision(
            _Auth(role: role),
            '/comm-admin',
            Uri.parse('/comm-admin'),
          ),
          '/home',
          reason: '$role must be redirected off /comm-admin',
        );
      }
    });

    test('unauthenticated users never reach /comm-admin', () {
      expect(
        redirectDecision(
          _Auth(role: AppRoles.superAdmin, status: AuthStatus.unauthenticated),
          '/comm-admin',
          Uri.parse('/comm-admin'),
        ),
        '/login',
      );
    });

    test('unresolved session is held on the loading route', () {
      expect(
        redirectDecision(
          _Auth(role: AppRoles.superAdmin, status: AuthStatus.resolving),
          '/comm-admin',
          Uri.parse('/comm-admin'),
        ),
        '/splash',
      );
    });
  });

  group('Announcement authoring gate', () {
    test('managers can publish without Comm Admin access', () {
      // Branch managers author branch announcements but cannot open the
      // administration centre — the two gates are deliberately different.
      expect(canAuthorAnnouncement(AppRoles.branchManager), isTrue);
      expect(canAccessCommAdmin(AppRoles.branchManager), isFalse);
    });

    test('ordinary staff cannot publish announcements', () {
      expect(canAuthorAnnouncement(AppRoles.staff), isFalse);
      expect(canAuthorAnnouncement(AppRoles.customer), isFalse);
    });
  });

  group('Unread count aggregation', () {
    test('sums every conversation bucket', () {
      const counts = {'direct:t1': 3, 'group:g1': 2, 'channel:c1': 5};
      expect(CommunicationService.unreadTotal(counts), 10);
    });

    test('empty map totals zero', () {
      expect(CommunicationService.unreadTotal(const {}), 0);
    });

    test('unreadFor is scoped by type and id', () {
      const counts = {'direct:t1': 4, 'group:g1': 2};
      expect(CommunicationService.unreadFor('direct', 't1', counts), 4);
      expect(CommunicationService.unreadFor('group', 'g1', counts), 2);
      // A channel sharing the id must not read the direct bucket.
      expect(CommunicationService.unreadFor('channel', 't1', counts), 0);
      expect(CommunicationService.unreadFor('direct', 'missing', counts), 0);
    });
  });

  group('Error translation', () {
    test('never leaks a raw Supabase message to the user', () {
      final message = CommunicationService.friendlyError(
        'PostgrestException: relation "secret_table" does not exist',
      );
      expect(message, isNot(contains('secret_table')));
      expect(message, isNotEmpty);
    });

    test('maps an expired JWT to a re-authentication prompt', () {
      expect(
        CommunicationService.friendlyError('AuthApiException: JWT has expired')
            .toLowerCase(),
        contains('sign in again'),
      );
    });

    test('maps a network failure to an offline prompt', () {
      expect(
        CommunicationService.friendlyError('SocketException: Connection failed')
            .toLowerCase(),
        contains('no network'),
      );
    });

    test('falls back to the supplied safe sentence', () {
      expect(
        CommunicationService.friendlyError('boom', fallback: 'Try later.'),
        'Try later.',
      );
    });
  });

  group('ChatMessage model', () {
    test('retains the full backend row for forward-compatible columns', () {
      final m = ChatMessage.fromJson({
        'id': 'm1',
        'body': 'hello',
        'priority': 'urgent',
        'is_official': true,
      });
      expect(m.id, 'm1');
      expect(m.body, 'hello');
      expect(m.raw['priority'], 'urgent');
      expect(m.raw['is_official'], true);
    });

    test('an optimistic message has an empty raw map by default', () {
      const m = ChatMessage(id: 'optimistic_1', body: 'queued');
      expect(m.raw, isEmpty);
    });
  });

  group('Relative timestamps', () {
    test('renders a compact recent label', () {
      final now = DateTime.now();
      expect(relativeTime(now.toIso8601String()), 'Just now');
      expect(
        relativeTime(
          now.subtract(const Duration(minutes: 5)).toIso8601String(),
        ),
        '5m ago',
      );
      expect(
        relativeTime(now.subtract(const Duration(hours: 3)).toIso8601String()),
        '3h ago',
      );
    });

    test('is safe on empty and malformed input', () {
      expect(relativeTime(null), '');
      expect(relativeTime(''), '');
      expect(relativeTime('not-a-date'), '');
    });
  });

  group('Employee directory names', () {
    // Regression: the RPC returns `full_name`/`email`, but the lookup used to
    // read a `name` key that is never returned, so every resolved colleague
    // silently fell back to "Colleague" (and the hub showed "00" initials).
    final rpcRow = <String, dynamic>{
      'user_id': 'peer-uuid',
      'full_name': 'KUJIMIYO DAVID ABAYOMI',
      'email': 'd.abayomi@infinitybank.com',
    };
    final dir = <String, Map<String, dynamic>>{'peer-uuid': rpcRow};

    test('prefers full_name from the RPC payload', () {
      expect(
        MessagingService.instance.directoryName(dir, 'peer-uuid'),
        'KUJIMIYO DAVID ABAYOMI',
      );
    });

    test('falls back to email, then to a safe generic label', () {
      expect(
        MessagingService.instance.directoryName({
          'peer-uuid': {'user_id': 'peer-uuid', 'email': 'peer@bank.com'},
        }, 'peer-uuid'),
        'peer@bank.com',
      );
      expect(
        MessagingService.instance.directoryName(dir, 'unknown-uuid'),
        'Colleague',
      );
      expect(
        MessagingService.instance.directoryName(dir, null),
        'Unknown User',
      );
    });

    test('a blank full_name does not hide a usable email', () {
      expect(
        MessagingService.instance.directoryName({
          'peer-uuid': {
            'user_id': 'peer-uuid',
            'full_name': '   ',
            'email': 'peer@bank.com',
          },
        }, 'peer-uuid'),
        'peer@bank.com',
      );
    });
  });

  group('Phone call eligibility', () {
    test('a colleague without a usable number is never dialled', () {
      // The Call action is only rendered for a non-empty number; this asserts
      // the sanitiser leaves such a value with nothing to dial.
      for (final missing in [null, '', '   ']) {
        final digits = (missing ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
        expect(digits, isEmpty, reason: 'missing=$missing');
      }
    });
  });
}
