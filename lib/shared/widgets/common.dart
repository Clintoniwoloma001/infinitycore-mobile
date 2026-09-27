import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/infinity_logo.dart';
import '../utils/formatters.dart';

/// Shared loading / empty / error states and layout cards.
class PageLoadingView extends StatelessWidget {
  const PageLoadingView({super.key, this.label = 'Loading…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            style: TextStyle(color: AppColors.textSecondary(context)),
          ),
        ],
      ),
    );
  }
}

class PageErrorView extends StatelessWidget {
  const PageErrorView({
    super.key,
    required this.message,
    this.detail,
    this.onRetry,
  });

  final String message;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 40,
              color: AppColors.iconMuted(context),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary(context),
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class PageEmptyView extends StatelessWidget {
  const PageEmptyView({
    super.key,
    this.title = 'Nothing here',
    this.description,
  });

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 40,
              color: AppColors.iconMuted(context),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (description != null) ...[
              const SizedBox(height: 6),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.detail,
    this.icon = Icons.circle,
    this.accent = AppColors.green,
  });

  final String label;
  final String value;
  final String? detail;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary(context),
                    ),
                  ),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary(context),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (detail != null && detail!.isNotEmpty)
                    Text(
                      detail!,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textTertiary(context),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
    this.children,
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final List<Widget>? children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary(context),
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            ...?children,
          ],
        ),
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.icon,
  });

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: AppColors.textTertiary(context)),
          const SizedBox(width: 8),
        ],
        SizedBox(
          width: 104,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary(context),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary(context),
            ),
          ),
        ),
      ],
    );
  }
}

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return InfinityMark(size: size);
  }
}

class AvatarCircle extends StatelessWidget {
  const AvatarCircle({
    super.key,
    required this.name,
    this.size = 40,
    this.photoUrl,
    this.onTap,
  });

  final String name;
  final double size;

  /// Optional signed photo URL. When set, the employee's photo is rendered in
  /// place of the initials, falling back to initials on load failure.
  final String? photoUrl;

  /// Destination override. Defaults to the Profile section, so every avatar in
  /// the app is a route into Profile without per-screen wiring.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final initials = Fmt.initials(name);
    final fallback = CircleAvatar(
      radius: size / 2,
      backgroundColor: AppColors.green.withValues(alpha: 0.15),
      child: Text(
        initials == '?' ? '∞' : initials,
        style: TextStyle(
          color: AppColors.greenDark,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.34,
        ),
      ),
    );
    final url = photoUrl?.trim() ?? '';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap ?? () => _openProfile(context),
      child: url.isEmpty ? fallback : _photo(url, fallback),
    );
  }

  void _openProfile(BuildContext context) {
    try {
      context.push('/profile');
    } catch (_) {
      // No router in scope (e.g. a bare widget test) — the avatar still renders.
    }
  }

  Widget _photo(String url, Widget fallback) {
    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: size,
            height: size,
            color: AppColors.green.withValues(alpha: 0.10),
            child: const Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        },
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c =
        color ??
        switch (label.toLowerCase()) {
          'active' || 'present' || 'complete' || 'approved' => AppColors.green,
          'late' || 'pending' || 'in_progress' => AppColors.amber,
          'absent' ||
          'rejected' ||
          'suspended' ||
          'terminated' => AppColors.rose,
          _ => AppColors.blue,
        };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label.isEmpty ? '—' : Fmt.titleCase(label),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c),
      ),
    );
  }
}
