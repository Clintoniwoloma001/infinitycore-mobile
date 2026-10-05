// Compact executive scorecard. Deliberately NOT a wall of cards: this is one
// dense, scannable strip used across the Director screens.
//
// A missing figure renders as an em dash. It is never defaulted to zero,
// because "no data" and "zero" mean completely different things to a director.
import 'package:flutter/material.dart';

import 'director_service.dart';
import '../../core/theme/app_theme.dart';

/// A single metric tile. [delta] is the server-supplied period-over-period
/// change; when the server sent none, nothing is drawn rather than guessing.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.delta,
    this.icon,
    this.caption,
    this.onTap,
  });

  final String label;
  final String? value;
  final double? delta;
  final IconData? icon;

  /// Opens the detail this figure summarises. Null for a tile with no
  /// drill-down, in which case the tile is not tappable and must not LOOK
  /// tappable - a dead tap that looks live is worse than an obvious summary.
  final VoidCallback? onTap;

  /// Small non-numeric qualifier shown under the value, e.g. "staff · this
  /// month".
  ///
  /// This is deliberately NOT [delta]. `delta` renders as a signed percentage
  /// ("+12% vs previous"), which is a period-over-period movement. Some figures
  /// instead need to say WHAT they count and over WHICH window - an attendance
  /// headcount of 34 is a different quantity from 34 expected days, and only the
  /// caption keeps those two readings apart. The caption is suppressed when a
  /// delta is present so the tile never stacks two competing sub-lines.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final up = (delta ?? 0) > 0;
    final down = (delta ?? 0) < 0;
    final flat = delta == null || delta == 0;

    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 12, color: AppColors.textSecondary(context)),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary(context),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value ?? '--',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary(context),
            ),
          ),
          if (!flat)
            Text(
              '${up ? '+' : ''}${delta!.toStringAsFixed(0)}% vs previous',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: up
                    ? const Color(0xFF047857)
                    : down
                    ? const Color(0xFFB91C1C)
                    : AppColors.textSecondary(context),
              ),
            )
          else if (caption != null)
            Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary(context),
              ),
            ),
        ],
      ),
    );

    // Only wrap when there is somewhere to go, so a summary-only tile keeps its
    // plain surface and never promises a detail it cannot show.
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: body,
      ),
    );
  }
}

/// A horizontally scrolling strip of metric tiles.
class MetricStrip extends StatelessWidget {
  const MetricStrip({super.key, required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 74,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: tiles.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => SizedBox(width: 132, child: tiles[i]),
      ),
    );
  }
}

/// Horizontal progress bar. A null [value] renders an empty track rather than
/// a full or zero bar, so "not measured" is visually distinct from "0%".
class MetricBar extends StatelessWidget {
  const MetricBar({super.key, required this.value, this.color});

  final double? value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final v = (value ?? 0).clamp(0.0, 100.0) / 100.0;
    final has = value != null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: LinearProgressIndicator(
          value: has ? v : null,
          backgroundColor: AppColors.border(context),
          valueColor: AlwaysStoppedAnimation<Color>(
            color ?? const Color(0xFF009944),
          ),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: AppColors.textPrimary(context),
              ),
            ),
          ),
          if (trailing case final Widget t) t,
        ],
      ),
    );
  }
}

String? fmtInt(Object? v) {
  final i = asInt(v);
  return i?.toString();
}

String? fmtPct(Object? v) => percent(v);
