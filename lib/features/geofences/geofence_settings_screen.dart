import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';
import 'geofence_fence_editor.dart';
import 'geofence_models.dart';
import 'geofence_service.dart';

/// Super Admin / Head of HR screen for administering branch geofences.
///
/// The navigation gate is [canManageGeofences] in `auth_gate.dart`; the real
/// boundary is `require_geofence_admin()` inside every geofence RPC, which
/// raises SQLSTATE 42501 for anyone else.
///
/// [role] exists so the gate can be exercised in a widget test without a live
/// session; production always passes null and reads the signed-in profile.
class GeofenceSettingsScreen extends StatefulWidget {
  const GeofenceSettingsScreen({super.key, this.role});

  final String? role;

  @override
  State<GeofenceSettingsScreen> createState() => _GeofenceSettingsScreenState();
}

class _GeofenceSettingsScreenState extends State<GeofenceSettingsScreen> {
  final _service = GeofenceService.instance;

  List<BranchGeofence> _fences = [];
  bool _loading = true;
  String? _error;

  /// Branch id of the row whose toggle/delete RPC is in flight, so only that
  /// row's controls disable.
  String? _busyBranchId;

  @override
  void initState() {
    super.initState();
    if (_authorized) _load();
  }

  bool get _authorized =>
      canManageGeofences(widget.role ?? AuthService.instance.role);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _service.list();
      if (!mounted) return;
      setState(() => _fences = result.geofences);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = friendlyGeofenceError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.rose),
    );
  }

  // ---- Row actions ---------------------------------------------------------

  Future<void> _setActive(BranchGeofence fence, bool value) async {
    setState(() => _busyBranchId = fence.branchId);
    try {
      final result = await _service.setBranchActive(
        branchId: fence.branchId,
        isActive: value,
      );
      if (!mounted) return;
      setState(() => _fences = result.geofences);
    } catch (error) {
      // The switch reads its value from the state, so a failed call simply
      // reverts when _busyBranchId clears — no manual undo needed.
      _snack(friendlyGeofenceError(error));
    } finally {
      if (mounted) setState(() => _busyBranchId = null);
    }
  }

  Future<void> _confirmDelete(BranchGeofence fence) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: AppColors.rose),
        title: const Text('Delete fence?'),
        content: Text(
          'The fence for ${fence.branchName} will be removed. Attendance '
          'records keep the coordinates they were verified against — the '
          'legacy copies are disabled, never erased — but new clock-ins will '
          'no longer be checked against this branch until a fence is added '
          'again.',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary(ctx),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.rose),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyBranchId = fence.branchId);
    try {
      final result = await _service.deleteBranch(branchId: fence.branchId);
      if (!mounted) return;
      setState(() => _fences = result.geofences);
    } catch (error) {
      _snack(friendlyGeofenceError(error));
    } finally {
      if (mounted) setState(() => _busyBranchId = null);
    }
  }

  Future<void> _openEditor({
    required String branchId,
    required String branchName,
    String branchCode = '',
    LatLng? centre,
    double radiusMetres = 150,
    bool isActive = true,
  }) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => FenceEditorScreen(
          branchId: branchId,
          branchName: branchName,
          branchCode: branchCode,
          initialCentre: centre,
          initialRadiusMetres: radiusMetres,
          initialActive: isActive,
        ),
      ),
    );
    if (saved == true) _load();
  }

  /// "Add fence": every branch that has no canonical fence yet, in a picker
  /// sheet. Selecting one opens the editor on that branch.
  Future<void> _openAddFence() async {
    final pending = _service.branchesWithoutFence(
      _fences.map((f) => f.branchId),
    );
    final picked = await showModalBottomSheet<BranchOption>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
                child: Text(
                  'Add a fence',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  'Branches that do not have a fence yet.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary(ctx),
                  ),
                ),
              ),
              Flexible(
                child: FutureBuilder<List<BranchOption>>(
                  future: pending,
                  builder: (ctx, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                        ),
                      );
                    }
                    if (snap.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          friendlyGeofenceError(snap.error!),
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary(ctx),
                          ),
                        ),
                      );
                    }
                    final options = snap.data ?? const <BranchOption>[];
                    if (options.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          'Every branch already has a fence.',
                          style: TextStyle(fontSize: 13),
                        ),
                      );
                    }
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (ctx, i) {
                        final option = options[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.add_location_alt_outlined,
                            color: AppColors.green,
                          ),
                          title: Text(
                            option.branchName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            [
                              if (option.branchCode.isNotEmpty)
                                option.branchCode,
                              option.coordinatesLabel,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => Navigator.pop(ctx, option),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _openEditor(
      branchId: picked.id,
      branchName: picked.branchName,
      branchCode: picked.branchCode,
      centre: picked.hasCoordinates
          ? LatLng(picked.latitude!, picked.longitude!)
          : null,
      radiusMetres: 150,
    );
  }

  void _openTester() {
    // The tester route is self-contained (the router builder ignores state
    // and the GoRoute table is owned elsewhere), so it picks the first fence
    // by default and offers an in-screen branch selector.
    context.push('/geofences/tester');
  }

  // ---- Rendering -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_authorized) {
      return Scaffold(
        appBar: shellAppBar(context, title: 'Geofence Settings'),
        body: const PageErrorView(
          message: 'Not authorized',
          detail: 'Only Super Admin / Head of HR can manage geofences.',
        ),
      );
    }

    final activeCount = _fences.where((f) => f.isActive).length;

    return Scaffold(
      appBar: shellAppBar(
        context,
        title: 'Geofence Settings',
        actionsExtra: [
          IconButton(
            icon: const Icon(Icons.radar),
            tooltip: 'Test my coverage',
            onPressed: _openTester,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Branch geofences',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Radius 10 m – 5 km · enforced by the server at clock-in',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: StatCard(
                    label: 'Fences configured',
                    value: '${_fences.length}',
                    icon: Icons.fence_outlined,
                    accent: AppColors.blue,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatCard(
                    label: 'Active',
                    value: '$activeCount',
                    icon: Icons.check_circle_outline,
                    accent: AppColors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _openAddFence,
              icon: const Icon(Icons.add_location_alt_outlined, size: 18),
              label: const Text('Add fence'),
            ),
            const SizedBox(height: 12),
            if (_error != null && _fences.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.rose,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            Text(
              '${_fences.length} fence${_fences.length == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 8),
            if (_loading && _fences.isEmpty)
              const PageLoadingView(label: 'Loading geofences…')
            else if (_error != null && _fences.isEmpty)
              PageErrorView(message: _error!, onRetry: _load)
            else if (_fences.isEmpty)
              const PageEmptyView(
                title: 'No fences configured',
                description:
                    'Add a fence to cover a branch so clock-ins are checked '
                    'against it.',
              )
            else
              ..._fences.map(
                (fence) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _FenceRow(
                    fence: fence,
                    busy: _busyBranchId == fence.branchId,
                    onEdit: () => _openEditor(
                      branchId: fence.branchId,
                      branchName: fence.branchName,
                      branchCode: fence.branchCode,
                      centre: fence.centre,
                      radiusMetres: fence.radiusMetres,
                      isActive: fence.isActive,
                    ),
                    onToggle: (v) => _setActive(fence, v),
                    onDelete: () => _confirmDelete(fence),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FenceRow extends StatelessWidget {
  const _FenceRow({
    required this.fence,
    required this.busy,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  final BranchGeofence fence;
  final bool busy;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final active = fence.isActive;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    fence.branchName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                StatusBadge(
                  label: active ? 'active' : 'inactive',
                  color: active ? AppColors.green : AppColors.rose,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (fence.branchCode.isNotEmpty) fence.branchCode,
                fence.coordinatesLabel,
              ].join(' · '),
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${fence.radiusLabel} · ${fence.employeesLabel}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: busy ? null : onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                ),
                const SizedBox(width: 4),
                Semantics(
                  label: active
                      ? 'Disable ${fence.branchName} geofence'
                      : 'Enable ${fence.branchName} geofence',
                  toggled: active,
                  child: Switch.adaptive(
                    value: active,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: busy ? null : onToggle,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Delete fence',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: AppColors.rose,
                  onPressed: busy ? null : onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
