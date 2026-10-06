import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/common.dart';
import 'mpr_service.dart';

/// Branch Deep-Dive Intelligence Suite — the Drag 5 / Soaring 5 attribution.
///
/// READS `rpc_get_branch_drag_and_soaring_staff`, which ranks ONLY employees
/// whose MPR is `complete`. An unmeasured colleague is never scored zero and
/// never appears as a "drag driver" — that would be an accusation against a
/// real member of staff based on a field nobody had filled in. The coverage
/// banner is therefore not decoration: it is the difference between "this is
/// the branch" and "this is the 12 people we have data for".
///
/// The top performer and the bottom performer get the spotlight treatment
/// because those are the two an executive actually acts on.
class BranchDeepDiveScreen extends StatefulWidget {
  const BranchDeepDiveScreen({
    super.key,
    required this.branchId,
    required this.branchName,
    required this.periodLabel,
    this.windowLabel = '',
  });

  final String branchId;
  final String branchName;

  /// The exact `mpr_targets.period_label` being queried. Shown in the UI so an
  /// empty result is diagnosable rather than mysterious.
  final String periodLabel;

  /// Human label for the window, e.g. "This quarter".
  final String windowLabel;

  @override
  State<BranchDeepDiveScreen> createState() => _BranchDeepDiveScreenState();
}

class _BranchDeepDiveScreenState extends State<BranchDeepDiveScreen> {
  BranchAttribution? _data;
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

    // Defence in depth: `p_branch_id` is a uuid, and Postgres would answer a
    // branch NAME with `invalid input syntax for type uuid: "Head Office"` —
    // a raw engine error the user should never read. The Branch Performance
    // screen resolves names to UUIDs before navigating here; if any other
    // caller ever passes a non-UUID, explain honestly instead of making a
    // request that can only fail.
    if (!isUuid(widget.branchId)) {
      if (!mounted) return;
      setState(() {
        _error =
            'This entry is not linked to a branch record, so there is '
            'nothing to rank. Go back, refresh the branch list, and open '
            'a branch that has a real record.';
        _loading = false;
      });
      return;
    }

    try {
      final d = await MprService.instance.branchAttribution(
        branchId: widget.branchId,
        periodLabel: widget.periodLabel,
      );
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.branchName.isEmpty
              ? 'Branch deep-dive'
              : '${widget.branchName} · Attribution',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const PageLoadingView();

    if (_error != null) {
      return PageErrorView(
        message: 'Unable to load branch attribution.',
        detail: _error,
        onRetry: _load,
      );
    }

    final d = _data;
    if (d == null) {
      return const PageEmptyView(
        title: 'Nothing to show',
        description: 'No attribution data was returned for this branch.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _coverageCard(d),
          const SizedBox(height: 12),
          if (d.isEmpty)
            _noDataCard()
          else ...[
            _soaringSection(d),
            const SizedBox(height: 12),
            _dragSection(d),
          ],
        ],
      ),
    );
  }

  /// Coverage banner — the single most important card on this screen.
  ///
  /// It states plainly how much of the branch the ranking actually covers. A
  /// Drag 5 drawn from 4 measured people out of 34 is a very different claim
  /// from one drawn from 30, and the reader cannot tell the difference from
  /// the ranked list alone.
  Widget _coverageCard(BranchAttribution d) {
    final pct = d.coveragePct;
    final low = pct != null && pct < 50;
    final tint = low ? AppColors.amber : AppColors.accentGreen;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.brandTint(context, tint),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  d.coverageLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
              ),
              if (pct != null)
                Text(
                  '${pct.toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: tint,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (pct ?? 0).clamp(0, 100) / 100,
              minHeight: 6,
              backgroundColor: AppColors.surface(context),
              valueColor: AlwaysStoppedAnimation<Color>(tint),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Period key: ${d.periodLabel}'
            '${widget.windowLabel.isEmpty ? '' : ' · ${widget.windowLabel}'}',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary(context),
            ),
          ),
          if (d.unmeasuredCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '${d.unmeasuredCount} staff have no complete MPR for this period '
              'and are excluded from every ranking below. They are not scored '
              'zero and are not listed as drag drivers.',
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: AppColors.textTertiary(context),
              ),
            ),
          ],
        ],
      ),
    );
  }


  /// Shown when the server returned no ranked staff at all.
  Widget _noDataCard() {
    return SectionCard(
      title: 'No measured staff for ${widget.periodLabel}',
      children: [
        Text(
          'Attribution ranks staff whose disbursement, PAR and caseload are '
          'all recorded for this period. Nothing has been entered for '
          '"${widget.periodLabel}" yet, so no ranking can be produced — and '
          'none is guessed.',
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: AppColors.textSecondary(context),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'MPR actuals are keyed by the period label above. If the figures '
          'were entered under a different key, this screen will stay empty '
          'until that key is used.',
          style: TextStyle(
            fontSize: 11,
            height: 1.4,
            fontStyle: FontStyle.italic,
            color: AppColors.textTertiary(context),
          ),
        ),
      ],
    );
  }

  /// Soaring 5 — the best performers, best first.
  ///
  /// Only rendered when the branch has enough measured staff to justify a
  /// "top five". With two measured people, calling somebody #1 of a
  /// five-person list would overstate the evidence.
  Widget _soaringSection(BranchAttribution d) {
    final list = d.soaring5;
    return SectionCard(
      title: 'Soaring 5',
      trailing: Text(
        '${list.length} measured',
        style: TextStyle(
          fontSize: 11,
          color: AppColors.textTertiary(context),
        ),
      ),
      children: [
        for (var i = 0; i < list.length; i++) ...[
          if (i == 0)
            _SpotlightCard(
              person: list[i],
              rank: 1,
              positive: true,
            )
          else
            _RankRow(person: list[i], rank: i + 1, positive: true),
          if (i < list.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// Drag 5 — the lowest performers, worst first.
  Widget _dragSection(BranchAttribution d) {
    final list = d.drag5;
    return SectionCard(
      title: 'Drag 5',
      trailing: Text(
        '${list.length} measured',
        style: TextStyle(
          fontSize: 11,
          color: AppColors.textTertiary(context),
        ),
      ),
      children: [
        for (var i = 0; i < list.length; i++) ...[
          if (i == 0)
            _SpotlightCard(
              person: list[i],
              rank: list.length,
              positive: false,
            )
          else
            _RankRow(person: list[i], rank: list.length - i, positive: false),
          if (i < list.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }


  /// The #1 card in either list.
  ///
  /// These are the two rows an executive acts on, so they get a tinted panel
  /// and a border in the list's colour. The Drag card deliberately leads with
  /// the *reason* (`rootCause`) rather than the score: "why" is actionable,
  /// and a bare "-14.2%" invites the reader to invent a cause themselves.
}

class _SpotlightCard extends StatelessWidget {
  const _SpotlightCard({
    required this.person,
    required this.rank,
    required this.positive,
  });

  final RankedStaff person;
  final int rank;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final accent = positive ? AppColors.accentGreen : AppColors.rose;
    final label = positive ? 'Star contributor' : 'Primary drag driver';
    final headline =
        positive ? (person.boostNote ?? 'Top performer') : person.rootCause;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.brandTint(context, accent),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                positive ? Icons.trending_up : Icons.trending_down,
                size: 15,
                color: accent,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: accent,
                ),
              ),
              const Spacer(),
              if (person.grade != null) _GradeChip(grade: person.grade!),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            person.employeeName,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'MPR ${person.total.toStringAsFixed(1)}'
            '${person.gradeRating.isEmpty ? '' : ' · ${person.gradeRating}'}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary(context),
            ),
          ),
          if (headline != null && headline.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              headline,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: AppColors.textPrimary(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}


/// A non-spotlight row: rank, name, score and grade.
class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.person,
    required this.rank,
    required this.positive,
  });

  final RankedStaff person;
  final int rank;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final note = positive ? person.boostNote : person.rootCause;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$rank',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: AppColors.textTertiary(context),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        person.employeeName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary(context),
                        ),
                      ),
                    ),
                    if (person.grade != null)
                      _GradeChip(grade: person.grade!),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'MPR ${person.total.toStringAsFixed(1)}'
                  '${person.shareOfBranchMprPct == null ? '' : ' · ${person.shareOfBranchMprPct!.toStringAsFixed(1)}% of measured MPR'}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary(context),
                  ),
                ),
                if (note != null && note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      note,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: AppColors.textTertiary(context),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// A–E grade chip, coloured from the shared `MprGrade` table.
class _GradeChip extends StatelessWidget {
  const _GradeChip({required this.grade});

  final MprGrade grade;

  @override
  Widget build(BuildContext context) {
    final c = Color(grade.hex);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        grade.letter,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: c,
        ),
      ),
    );
  }
}

