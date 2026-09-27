import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/app_router.dart';
import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/notification_badge.dart';
import '../../core/theme/app_theme.dart';
import '../messages/messaging_hub.dart';

/// One row in the top-right overflow menu.
///
/// The menu is intentionally data-driven: adding a future destination means
/// appending an [AppMenuAction] to [_menuActions], not editing layout code.
class AppMenuAction {
  const AppMenuAction({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.route,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final String route;
}

List<AppMenuAction> _menuActions() {
  final role = AuthService.instance.role;
  return [
    const AppMenuAction(
      label: 'Profile',
      subtitle: 'Personal details, documents and device security',
      icon: Icons.person_outline,
      route: '/profile',
    ),
    const AppMenuAction(
      label: 'Notifications',
      subtitle: 'Updates, approvals and operational alerts',
      icon: Icons.notifications_none,
      route: '/notifications',
    ),
    if (canAccessCommAdmin(role))
      const AppMenuAction(
        label: 'Communication Admin',
        subtitle: 'Channels, groups and announcement audiences',
        icon: Icons.campaign_outlined,
        route: '/comm-admin',
      ),
  ];
}

/// Opens the top-right list menu.
Future<void> showAppMenu(BuildContext context) {
  final actions = _menuActions();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: AppColors.surface(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Text(
              'Menu',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(sheetContext),
              ),
            ),
          ),
          for (final action in actions)
            ListTile(
              leading: Icon(
                action.icon,
                color: AppColors.accent(sheetContext),
              ),
              title: Text(
                action.label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary(sheetContext),
                ),
              ),
              subtitle: Text(
                action.subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary(sheetContext),
                ),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.push(action.route);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Three-line horizontal menu trigger.
class AppMenuButton extends StatelessWidget {
  const AppMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.menu),
      tooltip: 'Menu',
      onPressed: () => showAppMenu(context),
    );
  }
}

/// Animated notification bell.
///
/// Shakes when the combined unread count rises and toasts what arrived, so an
/// unread notification or message cannot be missed while the user is on a
/// different tab. Tapping opens the notifications list.
class NotificationBellButton extends StatefulWidget {
  const NotificationBellButton({super.key});

  @override
  State<NotificationBellButton> createState() => _NotificationBellButtonState();
}

class _NotificationBellButtonState extends State<NotificationBellButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  int _messages = 0;
  int _notifications = 0;
  int _seenTotal = 0;
  bool _primed = false;

  @override
  void initState() {
    super.initState();
    _messages = MessagingHub.instance.unreadTotal.value;
    _notifications = NotificationBadge.instance.unreadNotifications.value;
    _seenTotal = _messages + _notifications;
    MessagingHub.instance.unreadTotal.addListener(_onCountsChanged);
    NotificationBadge.instance.unreadNotifications.addListener(
      _onCountsChanged,
    );
    unawaited(NotificationBadge.instance.refresh());
  }

  @override
  void dispose() {
    MessagingHub.instance.unreadTotal.removeListener(_onCountsChanged);
    NotificationBadge.instance.unreadNotifications.removeListener(
      _onCountsChanged,
    );
    _shake.dispose();
    super.dispose();
  }

  void _onCountsChanged() {
    if (!mounted) return;
    final messages = MessagingHub.instance.unreadTotal.value;
    final notifications = NotificationBadge.instance.unreadNotifications.value;
    final total = messages + notifications;
    final increased = total > _seenTotal;
    setState(() {
      _messages = messages;
      _notifications = notifications;
    });
    if (increased && _primed) {
      _shake.forward(from: 0);
      _toast();
    }
    _primed = true;
    _seenTotal = total;
  }

  void _toast() {
    final parts = <String>[];
    if (_notifications > 0) {
      parts.add(
        '$_notifications unread notification${_notifications == 1 ? '' : 's'}',
      );
    }
    if (_messages > 0) {
      parts.add('$_messages unread message${_messages == 1 ? '' : 's'}');
    }
    if (parts.isEmpty) return;
    rootScaffoldMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('You have ${parts.join(' and ')}'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final total = _messages + _notifications;
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        // Damped oscillation: a short "vibrate" rather than a bouncy wobble.
        final t = _shake.value;
        final angle = t == 0 ? 0.0 : (1 - t) * 0.28 * _oscillation(t * 4);
        return Transform.rotate(angle: angle, child: child);
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          IconButton(
            icon: const Icon(Icons.notifications_none),
            tooltip: 'Notifications',
            onPressed: () {
              _seenTotal = 0;
              context.push('/notifications');
            },
          ),
          if (total > 0)
            Positioned(
              right: 6,
              top: 6,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  constraints: const BoxConstraints(minWidth: 16),
                  decoration: BoxDecoration(
                    color: AppColors.rose,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    total > 99 ? '99+' : '$total',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  double _oscillation(double phase) {
    final p = phase % 2.0;
    return p < 1.0 ? p : 2.0 - p;
  }
}

/// Header actions: the animated notification bell, then the overflow menu.
List<Widget> appHeaderActions(BuildContext context) => const [
  NotificationBellButton(),
  AppMenuButton(),
];

