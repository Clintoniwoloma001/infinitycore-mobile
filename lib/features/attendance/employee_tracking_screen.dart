import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import 'staff_location_map_screen.dart';
import 'tracking_classifier.dart';
import 'tracking_service.dart';

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

  /// The web Live positions tab's three scope filters, applied to the rows the
  /// server already authorised. Options come from those rows, never from a
  /// separate table read, so a filter can never offer someone the caller may
  /// not see.
  String _department = '';
  String _position = '';
  String _branchId = '';

  /// The visible segment. Defaults to Inside, or the first non-empty one, and
  /// only changes when the user taps a segment.
  TrackingBucket _segment = TrackingBucket.inside;

  /// Local "HH:mm:ss" of the last successful load, like the web's stamp.
  String _updatedAt = '';

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
      setState(() {
        _people = rows;
        _updatedAt = DateFormat('HH:mm:ss').format(DateTime.now());
      });
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

  /// Every listed employee: the service already restricted these to a fix in
  /// the last 48 h (the RPC's own window).
  List<TrackedEmployee> get _listed =>
      (_people ?? const <TrackedEmployee>[])
          .where((p) => p.bucket != null)
          .toList(growable: false);

  /// After the department / position / branch filters. The counts are computed
  /// from this set, exactly like the web, so a filter can never make the
  /// header disagree with the list.
  List<TrackedEmployee> get _scoped => _listed
      .where(
        (p) =>
            (_department.isEmpty || p.department == _department) &&
            (_position.isEmpty || p.position == _position) &&
            (_branchId.isEmpty || p.branchId == _branchId),
      )
      .toList(growable: false);

  Map<TrackingBucket, int> get _counts =>
      countTrackingBuckets(_scoped.map((p) => p.bucket));

  /// The segment to show: the tap, or Inside, or the first non-empty one.
  TrackingBucket get _activeSegment {
    if (_counts[_segment]! > 0) return _segment;
    for (final b in TrackingBucket.values) {
      if (_counts[b]! > 0) return b;
    }
    return _segment;
  }

  List<TrackedEmployee> get _visible {
    final scoped = _scoped.where((p) => p.bucket == _activeSegment);
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return scoped.toList(growable: false);
    return scoped
        .where(
          (p) =>
              p.name.toLowerCase().contains(q) ||
              p.employeeNumber.toLowerCase().contains(q) ||
              p.position.toLowerCase().contains(q) ||
              p.branchName.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  /// Filter option values, derived from the rows on screen (the web derives
  /// them the same way).
  List<String> get _departmentOptions =>
      _listed.map((p) => p.department).where((d) => d.isNotEmpty).toSet().toList()
        ..sort();
  List<String> get _positionOptions =>
      _listed.map((p) => p.position).where((d) => d.isNotEmpty).toSet().toList()
        ..sort();
  List<({String id, String label})> get _branchOptions {
    final seen = <String, String>{};
    for (final p in _listed) {
      if (p.branchId.isNotEmpty) seen[p.branchId] = p.branchName.isEmpty ? p.branchId : p.branchName;
    }
    final out = seen.entries.map((e) => (id: e.key, label: e.value)).toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return out;
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
    final listed = _listed;
    final counts = _counts;
    final segment = _activeSegment;
    final rows = _visible;
    if (listed.isEmpty) {
      return const PageEmptyView(
        title: 'No one has reported in the last 48 h',
        description:
            'This screen lists only employees whose app recorded a location '
            'in that window.',
      );
    }

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
          // Header summary, matching the web Live positions tab exactly.
          Text(
            '${listed.length} reporting in the last $trackingRecentHours h',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary(context),
            ),
          ),
          if (_updatedAt.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              'updated $_updatedAt',
              style: TextStyle(
                fontSize: 10.5,
                color: AppColors.textTertiary(context),
              ),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Search by name, number, role or branch',
              prefixIcon: Icon(Icons.search, size: 20),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 10),
          // The web's three scope filters. Counts and segments respect them,
          // because they narrow the same rows the counts are computed from.
          _ScopeFilters(
            departments: _departmentOptions,
            positions: _positionOptions,
            branches: _branchOptions,
            department: _department,
            position: _position,
            branchId: _branchId,
            onDepartment: (v) => setState(() => _department = v ?? ''),
            onPosition: (v) => setState(() => _position = v ?? ''),
            onBranch: (v) => setState(() => _branchId = v ?? ''),
          ),
          const SizedBox(height: 12),
          // Segments with their counts. One bucket per row, so the four counts
          // sum to the scoped total — the same invariant the web header keeps.
          _SegmentBar(
            counts: counts,
            active: segment,
            onSelect: (b) => setState(() => _segment = b),
          ),
          const SizedBox(height: 12),
          if (listed.isNotEmpty && counts[segment]! > 0 && rows.isEmpty)
            PageEmptyView(
              title: 'No match',
              description: 'No employee in this segment matches "$_query".',
            )
          else if (counts[segment]! == 0)
            _SegmentEmpty(bucket: segment)
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
              _VerdictPill(bucket: person.bucket, delayed: person.isDelayed),
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
          if (person.isLowAccuracy) ...[
            const SizedBox(height: 3),
            Text(
              '${person.place} (low GPS accuracy)',
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
/// as though it were live. Driven by the classifier's bucket, so the badge can
/// never disagree with the segment the row sits in.
class _VerdictPill extends StatelessWidget {
  const _VerdictPill({required this.bucket, this.delayed = false});

  final TrackingBucket? bucket;
  final bool delayed;

  @override
  Widget build(BuildContext context) {
    // A delayed fix keeps its verdict but is marked, so "Inside" can still mean
    // "nine minutes ago" rather than "now".
    final delayedSuffix = delayed && bucket != TrackingBucket.stale ? ' · delayed' : '';
    final (Color bg, Color fg, String text) = switch (bucket) {
      TrackingBucket.inside => (AppColors.green, Colors.white, 'Inside'),
      TrackingBucket.outside => (AppColors.amber, Colors.white, 'Outside'),
      TrackingBucket.stale => (
        AppColors.border(context),
        AppColors.textSecondary(context),
        'Stale',
      ),
      TrackingBucket.noGeofence => (
        AppColors.border(context),
        AppColors.textSecondary(context),
        'No geofence',
      ),
      null => (
        AppColors.border(context),
        AppColors.textSecondary(context),
        '—',
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$text$delayedSuffix',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}
/// The web Live positions tab's three scope filters: department, position and
/// branch. Each option comes from the rows currently listed, so a filter can
/// never offer (or hide) an employee the caller is not allowed to see.
class _ScopeFilters extends StatelessWidget {
  const _ScopeFilters({
    required this.departments,
    required this.positions,
    required this.branches,
    required this.department,
    required this.position,
    required this.branchId,
    required this.onDepartment,
    required this.onPosition,
    required this.onBranch,
  });

  final List<String> departments;
  final List<String> positions;
  final List<({String id, String label})> branches;
  final String department;
  final String position;
  final String branchId;
  final ValueChanged<String?> onDepartment;
  final ValueChanged<String?> onPosition;
  final ValueChanged<String?> onBranch;

  @override
  Widget build(BuildContext context) {
    if (departments.length <= 1 &&
        positions.length <= 1 &&
        branches.length <= 1) {
      // Nothing worth a filter row.
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (departments.length > 1)
          DropdownButtonFormField<String?>(
            initialValue: department.isEmpty ? null : department,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Department'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('All departments'),
              ),
              for (final d in departments)
                DropdownMenuItem<String?>(value: d, child: Text(d)),
            ],
            onChanged: onDepartment,
          ),
        if (positions.length > 1) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: position.isEmpty ? null : position,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Position'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('All positions'),
              ),
              for (final p in positions)
                DropdownMenuItem<String?>(value: p, child: Text(p)),
            ],
            onChanged: onPosition,
          ),
        ],
        if (branches.length > 1) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: branchId.isEmpty ? null : branchId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Branch'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('All branches'),
              ),
              for (final b in branches)
                DropdownMenuItem<String?>(
                  value: b.id,
                  child: Text(b.label),
                ),
            ],
            onChanged: onBranch,
          ),
        ],
      ],
    );
  }
}

/// The four segments, each labelled with its count. Selecting one lists only
/// that bucket; selecting the active one again clears back to the default.
class _SegmentBar extends StatelessWidget {
  const _SegmentBar({
    required this.counts,
    required this.active,
    required this.onSelect,
  });

  final Map<TrackingBucket, int> counts;
  final TrackingBucket active;
  final ValueChanged<TrackingBucket> onSelect;

  static const _labels = <TrackingBucket, String>{
    TrackingBucket.inside: 'Inside',
    TrackingBucket.outside: 'Outside',
    TrackingBucket.stale: 'Stale',
    TrackingBucket.noGeofence: 'No geofence',
  };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final bucket in TrackingBucket.values) ...[
            ChoiceChip(
              label: Text('${_labels[bucket]} (${counts[bucket] ?? 0})'),
              selected: bucket == active,
              onSelected: (_) => onSelect(bucket),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _SegmentEmpty extends StatelessWidget {
  const _SegmentEmpty({required this.bucket});

  final TrackingBucket bucket;

  @override
  Widget build(BuildContext context) {
    final (String title, String description) = switch (bucket) {
      TrackingBucket.inside => (
        'No one is inside a geofence',
        'Nobody in the filtered set has a current fix inside a registered '
            'location.',
      ),
      TrackingBucket.outside => (
        'No one is outside',
        'Everybody in the filtered set is inside a registered location.',
      ),
      TrackingBucket.stale => (
        'Nothing is stale',
        'Every fix in the filtered set is recent enough to still show its '
            'verdict.',
      ),
      TrackingBucket.noGeofence => (
        'No geofence',
        'Every listed branch has a geofence configured.',
      ),
    };
    return PageEmptyView(title: title, description: description);
  }
}
