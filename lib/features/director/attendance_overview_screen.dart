// Attendance intelligence for the executive view.
//
// These figures come from the same verified attendance records the Attendance
// Management screen reads. Nothing here re-derives attendance: the server owns
// the arithmetic, this screen only displays it and lets the director drill into
// a person.
import 'package:flutter/material.dart';

import '../attendance/attendance_service.dart';
import 'director_service.dart';
import 'director_widgets.dart';
import 'employee_profile_screen.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/models.dart';

class AttendanceOverviewScreen extends StatefulWidget {
  const AttendanceOverviewScreen({super.key});

  @override
  State<AttendanceOverviewScreen> createState() =>
      _AttendanceOverviewScreenState();
}

class _AttendanceOverviewScreenState extends State<AttendanceOverviewScreen> {
  Map<String, dynamic> _summary = const {};
  List<Map<String, dynamic>> _staff = const [];

  /// The window the org-wide figures describe.
  ///
  /// Defaults to TODAY. An executive opening Attendance is asking "who is in
  /// today?", and the server's own default (no dates) resolves to an unbounded
  /// month-to-date range whose `expected_days` column is a constant, which is
  /// what produced a nonsense 4220 "absent" figure. Being explicit means the
  /// numbers are reproducible and match the period chip on screen.
  DirectorPeriod _period = DirectorPeriod.today();
  bool _loading = true;
  String? _error;

  /// Whether the person list is expanded past its 20-row cap.
  bool _showAll = false;

  // --- Personal clock-in / clock-out (Section 5, primary section) ------------
  // A Director, Chairman or MD/CEO is a person who also has to clock in. This tab
  // used to open on the org-wide staff list, so the executive's own punch was
  // only reachable by leaving the executive view and using the ordinary
  // Attendance screen. These controls reuse the SAME AttendanceService, so the
  // same geofence, device-binding and biometric rules apply — there is no
  // second, looser punch path.
  final AttendanceService _attendance = AttendanceService.instance;
  EmployeeRef? _me;
  AttendanceRecord? _myToday;
  bool _clocking = false;
  String? _clockError;

  @override
  void initState() {
    super.initState();
    _load();
    _loadMine();
  }

  Future<void> _loadMine() async {
    try {
      final me = await _attendance.getMyEmployee();
      if (me == null || !mounted) return;
      final today = await _attendance.getToday(me.id);
      if (!mounted) return;
      setState(() {
        _me = me;
        _myToday = today;
      });
    } catch (_) {
      // An executive without an employee record is legitimate — the role comes
      // from the profile, not the staff roster — so this must not break the
      // screen. The personal section simply reports that it is unavailable.
    }
  }

  Future<void> _punch() async {
    if (_me == null || _clocking) return;
    setState(() {
      _clocking = true;
      _clockError = null;
    });
    try {
      final clockedIn = _myToday?.clockIn != null && _myToday?.clockOut == null;
      if (clockedIn) {
        await _attendance.clockOut(_myToday!.id);
      } else {
        await _attendance.clockIn(null);
      }
      if (!mounted) return;
      final me = _me;
      if (me == null) return;
      final refreshed = await _attendance.getToday(me.id);
      if (mounted) setState(() => _myToday = refreshed);
    } catch (e) {
      if (mounted) setState(() => _clockError = e.toString());
    } finally {
      if (mounted) setState(() => _clocking = false);
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Always send an explicit window. Calling the RPC with no dates lets the
      // server fall back to an unbounded range, and its `expected_days` column
      // is a fixed 20 per employee regardless of how many days were actually
      // requested - so "this month" and "today" produced the same figure.
      final snap = await DirectorService.instance.snapshot(
        from: _period.from,
        to: _period.to,
      );
      if (!mounted) return;
      setState(() {
        _summary = snap.summary;
        _staff = snap.staff;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Headline figures, recomputed from the per-person rows so they stay on one
  /// basis. See [AttendanceTotals] for why `summary.absent` is not used.
  AttendanceTotals get _metrics => AttendanceTotals.fromStaff(_staff);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // No app bar: DirectorShell supplies it, together with the menu and
      // notification bell, so the executive can reach Profile, I-Meet,
      // Training and Automation. See director_shell.dart.
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // --- PRIMARY: the executive's own punch (Section 5) --------
                  _MyClockCard(
                    me: _me,
                    today: _myToday,
                    busy: _clocking,
                    error: _clockError,
                    onPunch: _punch,
                    onRetryMine: _loadMine,
                  ),
                  const SizedBox(height: 20),
                  // --- SECONDARY: org-wide monitoring -------------------------
                  // Window first, so every number below is read against a known
                  // range. Defaults to today.
                  _AttendancePeriodSelector(
                    period: _period,
                    onChanged: (p) {
                      setState(() => _period = p);
                      _load();
                    },
                  ),
                  const SizedBox(height: 16),
                  const SectionHeader(title: 'STAFF ATTENDANCE'),
                  MetricStrip(
                    tiles: [
                      MetricTile(
                        label: 'Rate',
                        value: '${_metrics.rate.toStringAsFixed(1)}%',
                        icon: Icons.schedule_outlined,
                      ),
                      // STAFF headcounts, not attendance-DAYS. The server's
                      // `summary.absent` (4220 on this roster) is a day count -
                      // sum of a hardcoded 20 expected days per person - and
                      // reading it as people is what made the old tile look
                      // absurd. A headcount can never exceed the roster.
                      MetricTile(
                        label: 'Present staff',
                        value: fmtInt(_metrics.presentStaff),
                        icon: Icons.check_circle_outline,
                      ),
                      MetricTile(
                        label: 'Absent staff',
                        value: fmtInt(_metrics.absentStaff),
                        icon: Icons.person_off_outlined,
                      ),
                      MetricTile(
                        label: 'Total staff',
                        value: fmtInt(_metrics.totalStaff),
                        icon: Icons.groups_outlined,
                      ),
                      // Day-weighted view, kept because a multi-day window
                      // genuinely needs it. Explicitly labelled "days" so the
                      // two bases can never be confused for one another.
                      MetricTile(
                        label: 'Days worked',
                        value: fmtInt(_metrics.presentDays),
                        icon: Icons.event_available_outlined,
                      ),
                      MetricTile(
                        label: 'Days expected',
                        value: fmtInt(_metrics.expectedDays),
                        icon: Icons.event_outlined,
                      ),
                      MetricTile(
                        label: 'Late',
                        value: fmtInt(_summary['late']),
                        icon: Icons.schedule_outlined,
                      ),
                      MetricTile(
                        label: 'Not clocked in',
                        value: fmtInt(_summary['not_clocked_in']),
                        icon: Icons.timer_off_outlined,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const SectionHeader(title: 'BY PERSON'),
                  if (_staff.isEmpty)
                    Text(
                      'No attendance reported for this period.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary(context),
                      ),
                    )
                  else
                    ..._staff
                        .take(_showAll ? _staff.length : 20)
                        .map(
                          (p) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(
                              text(p['full_name']) ?? 'Unnamed',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              text(p['branch_name']) ??
                                  text(p['position']) ??
                                  '',
                              style: const TextStyle(fontSize: 10),
                            ),
                            trailing: Text(
                              fmtPct(p['attendance_rate']) ?? '--',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onTap: () {
                              final id =
                                  text(p['employee_id']) ?? text(p['id']);
                              if (id == null) return;
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => EmployeeProfileScreen(
                                    employeeId: id,
                                    fallbackName: text(p['full_name']),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                  // The list is capped at 20 so the summary stays scannable, but
                  // a silent cap hides people: state the truncation and offer the
                  // rest, rather than making the director guess how many exist.
                  if (_staff.length > 20)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _showAll = !_showAll),
                        icon: Icon(
                          _showAll ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                        ),
                        label: Text(
                          _showAll
                              ? 'Show fewer'
                              : 'See all ${_staff.length} people',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Reporting-window chips for the attendance figures.
///
/// Mirrors the Home tab's selector so both executive screens speak the same
/// vocabulary. The choices are the same `DirectorPeriod` helpers the rest of the
/// director feature uses, which is what keeps the server-side range clamping
/// (an end date after today is rejected) in one place.
class _AttendancePeriodSelector extends StatelessWidget {
  const _AttendancePeriodSelector({
    required this.period,
    required this.onChanged,
  });

  final DirectorPeriod period;
  final ValueChanged<DirectorPeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    final choices = <DirectorPeriod>[
      DirectorPeriod.today(),
      DirectorPeriod.thisWeek(),
      DirectorPeriod.thisMonth(),
      DirectorPeriod.thisQuarter(),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: choices
            .map(
              (p) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(p.label, style: const TextStyle(fontSize: 11)),
                  selected: period.label == p.label,
                  onSelected: (_) => onChanged(p),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

/// The executive's OWN clock-in / clock-out, shown above the org-wide figures.
///
/// Reports honestly when there is no employee record: an executive's authority
/// comes from the profile role, not the staff roster, so "no punch available"
/// is a legitimate state and must not look like an error.
class _MyClockCard extends StatelessWidget {
  const _MyClockCard({
    required this.me,
    required this.today,
    required this.busy,
    required this.error,
    required this.onPunch,
    required this.onRetryMine,
  });

  final EmployeeRef? me;
  final AttendanceRecord? today;
  final bool busy;
  final String? error;
  final VoidCallback onPunch;
  final VoidCallback onRetryMine;

  /// `clockIn` / `clockOut` arrive as ISO strings, not DateTime, so they are
  /// parsed rather than formatted directly.
  String _hhmm(dynamic raw) {
    if (raw == null) return '--';
    final s = raw.toString();
    if (s.isEmpty) return '--';
    final d = DateTime.tryParse(s);
    if (d == null) return s;
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    // No employee record: say so plainly. Do not render a button that cannot
    // work, and do not pretend the executive is "not clocked in".
    if (me == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'My attendance',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary(context),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'No staff record is linked to your account, so there is nothing '
                'to clock. Your executive permissions are unaffected.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary(context),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onRetryMine,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Check again'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final clockedIn = today?.clockIn != null && today?.clockOut == null;
    final open = today?.clockIn != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MY ATTENDANCE',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1,
                color: AppColors.textTertiary(context),
              ),
            ),
            const SizedBox(height: 8),
            // Wrap rather than a Row so the two times plus the status chip
            // cannot overflow a narrow phone.
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _ClockStat(label: 'Clock in', value: _hhmm(today?.clockIn)),
                _ClockStat(label: 'Clock out', value: _hhmm(today?.clockOut)),
                Chip(
                  label: Text(
                    !open
                        ? 'Not clocked in'
                        : clockedIn
                        ? 'On the clock'
                        : 'Day complete',
                  ),
                  visualDensity: VisualDensity.compact,
                  labelStyle: const TextStyle(fontSize: 11),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: const TextStyle(fontSize: 12, color: Colors.red),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                // Disabled once the day is complete, so the control never offers
                // an action the server will refuse.
                onPressed: (busy || (open && !clockedIn)) ? null : onPunch,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(clockedIn ? Icons.logout : Icons.login, size: 18),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(clockedIn ? 'Clock out' : 'Clock in'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClockStat extends StatelessWidget {
  const _ClockStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: AppColors.textTertiary(context),
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
