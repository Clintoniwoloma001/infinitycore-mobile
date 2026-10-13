import 'package:flutter/material.dart';

import 'package:intl/intl.dart';

import '../../shared/widgets/common.dart';
import 'lateness_service.dart';

/// HR-head review screen for lateness reasons (Head of HR, HR Officer, Super
/// Admin).
///
/// The entry is hidden from everyone else and the route redirects before this
/// mounts, but the real boundary is RLS on `public.lateness_reasons`: an
/// unauthorized user who deep-links here sees only their own rows.
class LatenessReasonsScreen extends StatefulWidget {
  const LatenessReasonsScreen({super.key});

  @override
  State<LatenessReasonsScreen> createState() => _LatenessReasonsScreenState();
}

class _LatenessReasonsScreenState extends State<LatenessReasonsScreen> {
  final _search = TextEditingController();
  LatenessRange _range = LatenessRange.today;
  DateTime? _customFrom;
  DateTime? _customTo;
  String? _branch;

  List<LatenessReason> _rows = const [];
  List<String> _branches = const [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _total = 0;
  bool _canLoadMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  ({DateTime from, DateTime to}) get _window => latenessWindow(
    _range,
    customFrom: _customFrom,
    customTo: _customTo,
  );

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final window = _window;
      final rows = await LatenessService.instance.list(
        from: window.from,
        to: window.to,
        query: _search.text,
        branch: _branch,
      );
      final branches = await LatenessService.instance.branches(
        from: window.from,
        to: window.to,
      );
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _branches = branches;
        _total = rows.length;
        _canLoadMore = rows.length >= 25;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_canLoadMore) return;
    setState(() => _loadingMore = true);
    try {
      final window = _window;
      final more = await LatenessService.instance.list(
        from: window.from,
        to: window.to,
        query: _search.text,
        branch: _branch,
        offset: _rows.length,
      );
      if (!mounted) return;
      setState(() {
        _rows = [..._rows, ...more];
        _canLoadMore = more.length >= 25;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: _customFrom == null || _customTo == null
          ? null
          : DateTimeRange(start: _customFrom!, end: _customTo!),
    );
    if (picked == null) return;
    setState(() {
      _range = LatenessRange.custom;
      _customFrom = picked.start;
      _customTo = picked.end;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final window = _window;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lateness Reasons'),
        leading: const BackButton(),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Summary count for the current window.
                Text(
                  _loading
                      ? 'Loading…'
                      : '$_total ${_total == 1 ? 'reason' : 'reasons'} '
                        '${formatterRange(window.from, window.to)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 10),
                // Range filter chips: Today / This week / This month / Custom.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Today'),
                      selected: _range == LatenessRange.today,
                      onSelected: (_) => setState(() {
                        _range = LatenessRange.today;
                        _load();
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('This week'),
                      selected: _range == LatenessRange.week,
                      onSelected: (_) => setState(() {
                        _range = LatenessRange.week;
                        _load();
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('This month'),
                      selected: _range == LatenessRange.month,
                      onSelected: (_) => setState(() {
                        _range = LatenessRange.month;
                        _load();
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('Custom range'),
                      selected: _range == LatenessRange.custom,
                      onSelected: (_) => _pickCustomRange(),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _load(),
                  decoration: InputDecoration(
                    hintText: 'Search by employee or branch…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () {
                              _search.clear();
                              _load();
                            },
                          ),
                  ),
                ),
                if (_branches.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    initialValue: _branch,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Branch',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All branches'),
                      ),
                      for (final b in _branches)
                        DropdownMenuItem<String?>(value: b, child: Text(b)),
                    ],
                    onChanged: (value) {
                      setState(() => _branch = value);
                      _load();
                    },
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const PageLoadingView(label: 'Loading lateness reasons…')
                : _error != null
                ? PageErrorView(message: _error!, onRetry: _load)
                : _rows.isEmpty
                ? const PageEmptyView(
                    title: 'No lateness reasons',
                    description: 'No reason was submitted in this period.',
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(12),
                      itemCount: _rows.length + (_canLoadMore ? 1 : 0),
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        if (i >= _rows.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: _loadingMore
                                  ? const CircularProgressIndicator()
                                  : OutlinedButton(
                                      onPressed: _loadMore,
                                      child: const Text('Load more'),
                                    ),
                            ),
                          );
                        }
                        return _ReasonCard(reason: _rows[i]);
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// "today" / "1 Oct – 7 Oct 2026" style label for the summary line.
  String formatterRange(DateTime from, DateTime to) {
    final fmt = DateFormat('d MMM yyyy');
    if (from == to) return 'today';
    return 'from ${fmt.format(from)} to ${fmt.format(to)}';
  }
}

class _ReasonCard extends StatelessWidget {
  const _ReasonCard({required this.reason});

  final LatenessReason reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    reason.employeeName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${reason.minutesLate} min late',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (reason.branch.isNotEmpty) reason.branch,
                if (reason.workDate != null)
                  DateFormat('d MMM yyyy').format(reason.workDate!),
                if (reason.clockedInAt != null)
                  'in ${DateFormat('HH:mm').format(reason.clockedInAt!.toLocal())}',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              reason.category == 'others'
                  ? 'Others — ${reason.text}'
                  : reason.categoryLabel,
              style: theme.textTheme.bodyMedium,
            ),
            if (reason.category == 'others' && reason.text.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                reason.text,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
