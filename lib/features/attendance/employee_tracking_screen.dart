import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import 'staff_location_map_screen.dart';
import 'tracking_service.dart'
    show
        TrackedEmployee,
        TrackingService,
        kCategoryInside,
        kCategoryOutside,
        kCategoryStale,
        kCategoryUnconfigured,
        kTrackedCategories;

/// Employee Tracking — SUPER ADMIN ONLY.
///
/// Deliberately stricter than the web, which also admits a delegated tracking
/// grantee. A phone is far easier to lose or lend than a managed desktop, and
/// precise staff location is the most sensitive data the bank holds, so only
/// Super Admin opens this on mobile.
///
/// Every verdict shown here comes from the server's own geofence engine. This
/// screen never computes a distance or decides that a point is inside a fence.
class EmployeeTrackingScreen extends StatefulWidget {
  const EmployeeTrackingScreen({super.key});

  @override
  State<EmployeeTrackingScreen> createState() =>
      _EmployeeTrackingScreenState();
}

class _EmployeeTrackingScreenState extends State<EmployeeTrackingScreen> {
  List<TrackedEmployee>? _people;
  bool _loading = true;
  String? _error;
  String _query = '';

  /// The active category chip, or null for "no chip". Selecting a chip filters
  /// to that category only; selecting it again clears the filter.
  String? _chip;

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
      final rows = await TrackingService.instance.livePositions();
      if (!mounted) return;
      // The server already ordered them live-first then newest; the phone must
      // NOT re-sort, or it can drift away from the web again.
      setState(() => _people = rows);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The in-client check. The server re-checks on every RPC regardless, so this
  /// is about not offering the screen at all, not about security on its own.
  bool get _permitted =>
      canAccessEmployeeTracking(AuthService.instance.profile?.role ?? '');

  /// Counts take ONE field — the server's `display_category` — and count the
  /// SAME rows that are rendered. The categories are mutually exclusive, so
  /// inside + outside + stale + unconfigured always equals the number of rows,
  /// which is the invariant the chips below rely on.
  Map<String, int> get _counts {
    final counts = <String, int>{
      kCategoryInside: 0,
      kCategoryOutside: 0,
      kCategoryStale: 0,
      kCategoryUnconfigured: 0,
    };
    for (final p in _people ?? const <TrackedEmployee>[]) {
      counts[p.category] = (counts[p.category] ?? 0) + 1;
    }
    return counts;
  }

  /// Filtered by the text query and then by the active chip. Both operate on the
  /// same server-authorised rows; neither recomputes a verdict.
  List<TrackedEmployee> get _visible {
    final all = _people ?? const <TrackedEmployee>[];
    final q = _query.trim().toLowerCase();
    Iterable<TrackedEmployee> rows = all;
    if (q.isNotEmpty) {
      rows = rows.where(
        (p) =>
            p.name.toLowerCase().contains(q) ||
            p.employeeNumber.toLowerCase().contains(q) ||
            p.position.toLowerCase().contains(q) ||
            p.branchName.toLowerCase().contains(q),
      );
    }
    if (_chip != null) {
      rows = rows.where((p) => p.category == _chip);
    }
    return rows.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Employee Tracking'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: !_permitted
          ? const PageEmptyView(
              title: 'Not available for your role',
              description:
                  'Employee Tracking is restricted to Super Admin on mobile. '
                  'Precise staff location is not delegated to a phone.',
            )
          : _body(),
    );
  }

  Widget _body() {
    if (_loading) return const PageLoadingView();
    if (_error != null) {
      return PageErrorView(
        message: 'Unable to load live positions.',
        detail: _error,
        onRetry: _load,
      );
    }
    final rows = _visible;
    if ((_people ?? const []).isEmpty) {
      return PageEmptyView(
        title: 'No one has reported in the last 48 h',
        description:
            'This list holds only employees whose app has recorded a location '
            'in that window. Everyone else is not shown, rather than listed '
            'with no location.',
      );
    }

    final counts = _counts;
    final listed = _people?.length ?? 0;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.amber.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.shield_outlined,
                  size: 16,
                  color: AppColors.amber,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Super Admin view. Every inside/outside verdict is made by '
                    'the server geofence engine, not by this app.',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // The reporting count, not the size of the staff list. This screen
          // used to say "N tracked · M current", where N was the whole company
          // because the RPC returned everyone.
          Text(
            '$listed reporting in the last 48 h',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 10),
          // ONE source for the counts and the badges: the server's
          // display_category. Four mutually exclusive chips, so they always add
          // up to the number of listed rows.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in kTrackedCategories)
                _CategoryChip(
                  category: entry,
                  count: counts[entry] ?? 0,
                  selected: _chip == entry,
                  onTap: () => setState(
                    () => _chip = _chip == entry ? null : entry,
                  ),
                ),
            ],
          ),
          if (_chip != null) ...[
            const SizedBox(height: 6),
            Text(
              'Showing only ${_chipLabel(_chip!)}. Tap the chip again to clear.',
              style: TextStyle(
                fontSize: 10,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Search by name, number, role or branch',
              prefixIcon: Icon(Icons.search, size: 20),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            PageEmptyView(
              title: 'No match',
              description: _chip == null
                  ? 'No tracked person matches "$_query".'
                  : 'No ${_chipLabel(_chip!)} employee matches "$_query".',
            )
          else
            for (final p in rows) ...[
              // Tapping a card opens the full-screen OSM map with that
              // person's live pin, breadcrumb route and movement analysis.
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => StaffLocationMapScreen(employee: p),
                  ),
                ),
                child: _PersonCard(person: p),
              ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }

}

/// The category label, as one word, for the chip.
String _chipLabel(String category) => switch (category) {
      kCategoryInside => 'inside',
      kCategoryOutside => 'outside',
      kCategoryStale => 'stale',
      kCategoryUnconfigured => 'no geofence',
      _ => category,
    };
/// One tracked person.
class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.person});

  final TrackedEmployee person;

  @override
  Widget build(BuildContext context) {
    final note = person.placeNote;
    final ago = person.minutesAgo;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      person.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    if (person.subtitle.isNotEmpty)
                      Text(
                        person.subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _VerdictPill(category: person.category),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                person.insideGeofence
                    ? Icons.location_on_outlined
                    : Icons.location_off_outlined,
                size: 15,
                color: person.insideGeofence
                    ? AppColors.green
                    : AppColors.amber,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(person.place, style: const TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 3),
            Text(
              note,
              style: TextStyle(
                fontSize: 10.5,
                fontStyle: FontStyle.italic,
                color: AppColors.textSecondary(context),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            ago == null
                ? 'No timestamp'
                : '${_ago(ago)} · ${DateFormat('d MMM, HH:mm').format(DateTime.now().subtract(Duration(minutes: ago)))}',
            style: TextStyle(
              fontSize: 10.5,
              color: AppColors.textTertiary(context),
            ),
          ),
        ],
      ),
    );
  }

  static String _ago(int minutes) {
    if (minutes < 1) return 'just now';
    if (minutes < 60) return '${minutes}m ago';
    return '${minutes ~/ 60}h ago';
  }
}

/// Inside/outside, with an explicit stale state so an old point is never shown
/// as though it were live.
///
/// Driven by the SERVER's display_category, the same field the chip row counts,
/// so the pill and the chips can never disagree — the exact bug the web had,
/// where the chips counted freshness while the badges reported geofence state.
/// A stale fix is never drawn green.
class _VerdictPill extends StatelessWidget {
  const _VerdictPill({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, String text) = switch (category) {
      kCategoryInside => (AppColors.green, Colors.white, 'Inside'),
      kCategoryOutside => (AppColors.rose, Colors.white, 'Outside'),
      kCategoryUnconfigured => (
        AppColors.border(context),
        AppColors.textSecondary(context),
        'No geofence',
      ),
      _ => (
        AppColors.border(context),
        AppColors.textSecondary(context),
        'Stale',
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

/// A category filter chip. Its number comes from the same rows the list renders,
/// so selecting it can never filter to something the count did not predict.
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.category,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String category;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (Color tint, String label) = switch (category) {
      kCategoryInside => (AppColors.green, 'Inside'),
      kCategoryOutside => (AppColors.rose, 'Outside'),
      kCategoryStale => (AppColors.textSecondary(context), 'Stale'),
      kCategoryUnconfigured => (AppColors.textTertiary(context), 'No geofence'),
      _ => (AppColors.textSecondary(context), category),
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.brandTint(context, AppColors.green)
              : tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? AppColors.green : tint),
        ),
        child: Text(
          '$count $label',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.textPrimary(context) : tint,
          ),
        ),
      ),
    );
  }
}