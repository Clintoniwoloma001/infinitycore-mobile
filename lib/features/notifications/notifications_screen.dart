import 'package:flutter/material.dart';

import '../../core/services/notification_deep_link.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = SupabaseService.client.auth.currentUser;
      if (user == null) {
        setState(() {
          _items = [];
          _loading = false;
        });
        return;
      }
      // `source_id` / `source_type` are NOT selected on purpose: the live
      // `notifications` table (see `infinitycore-sara/schema.sql`) only has
      // id, user_id, title, message, type, read, link and created_at. Asking
      // for the missing columns fails the whole query with Postgres 42703
      // ("column notifications.source_id does not exist") and the screen
      // shows a bare error instead of the user's notifications. The deep link
      // is resolved from `type` + `link`, which do exist.
      final res = await SupabaseService.client
          .from('notifications')
          .select('id, title, message, link, read, type, created_at')
          .eq('user_id', user.id)
          .order('created_at', ascending: false)
          .limit(100);
      if (!mounted) return;
      setState(
        () => _items = (res as List<dynamic>? ?? [])
            .map(AppNotification.fromJson)
            .toList(),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Marks the notification read and opens whatever it points at.
  ///
  /// `link` alone is not enough: the backend writes browser URLs, and a
  /// significant number of rows carry no link at all. Falling back to
  /// `type` + `source_id` is what makes a tap land on the exact message,
  /// record or task rather than back on this list.
  void _open(AppNotification n) async {
    if (!n.read) {
      await SupabaseService.client
          .from('notifications')
          .update({'read': true})
          .eq('id', n.id);
    }
    if (!mounted) return;
    if (!n.read) _load();
    final sourceType = (n.sourceType ?? '').trim();
    final sourceId = (n.sourceId ?? '').trim();
    NotificationDeepLink.open(
      context,
      type: sourceType.isEmpty ? n.type : sourceType,
      link: n.link,
      sourceId: sourceId.isEmpty ? null : sourceId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: 'Notifications'),
      body: _loading
          ? const PageLoadingView(label: 'Loading notifications…')
          : _error != null && _items.isEmpty
          ? PageErrorView(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? const PageEmptyView(
              title: 'No notifications',
              description: 'New alerts and announcements will appear here.',
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final n = _items[i];
                  return _NotificationTile(
                    notification: n,
                    onTap: () => _open(n),
                  );
                },
              ),
            ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  IconData get _icon {
    switch (notification.type) {
      case 'attendance':
        return Icons.schedule;
      case 'leave':
        return Icons.event_note;
      case 'message':
        return Icons.chat_bubble_outline;
      case 'payroll':
        return Icons.payments_outlined;
      default:
        return Icons.notifications_active_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: notification.read ? Colors.white : const Color(0xFFF0FDF4),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color:
                      (notification.read
                              ? const Color(0xFFE2E8F0)
                              : AppColors.green)
                          .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _icon,
                  size: 18,
                  color: notification.read
                      ? AppColors.textSecondary(context)
                      : AppColors.green,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notification.title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: notification.read
                            ? AppColors.textSecondary(context)
                            : Colors.black,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      notification.message,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary(context),
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (notification.createdAt.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        Fmt.dateTimeShort(notification.createdAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textTertiary(context),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!notification.read)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Icon(Icons.circle, size: 8, color: AppColors.green),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
