// ============================================================================
// PEOPLE DIRECTORY — the "See all" view behind the PEOPLE header
// ============================================================================
// WHY THIS IS A SEPARATE SCREEN
// The dashboard shows the first five people so the card stays glanceable. An
// executive asking "who is in Credit Control at Ikeja?" had no way to answer
// that on a phone: the full roster was fetched but never displayed.
//
// The rows come from the SAME snapshot the dashboard already loaded, so opening
// this sheet issues no new query and cannot disagree with the figures above it.
// No second directory, no second source of truth.
//
// PAGINATION IS DELIBERATE
// A company-wide roster is thousands of rows. Rendering them all to find one
// person is slow and needlessly expensive, so filtering happens on the already
// -fetched list and the page size is a fixed constant.
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// How many people are shown per page.
const int _kPeoplePageSize = 50;

/// Opens the directory. [onOpen] receives the raw person row, exactly as the
/// dashboard's own drill-down receives it.
Future<void> showPeopleDirectory(
  BuildContext context, {
  required List<Map<String, dynamic>> staff,
  void Function(Map<String, dynamic> person)? onOpen,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PeopleDirectoryScreen(staff: staff, onOpen: onOpen),
    ),
  );
}

/// Alphabetical order for the name sort. Case-insensitive so "adeyemi" and
/// "Adeyemi" sort together.
int _comparePeopleByName(Map<String, dynamic> a, Map<String, dynamic> b) {
  final an = (a['full_name']?.toString() ?? '').toLowerCase().trim();
  final bn = (b['full_name']?.toString() ?? '').toLowerCase().trim();
  return an.compareTo(bn);
}

class PeopleDirectoryScreen extends StatefulWidget {
  const PeopleDirectoryScreen({super.key, required this.staff, this.onOpen});

  final List<Map<String, dynamic>> staff;
  final void Function(Map<String, dynamic> person)? onOpen;

  @override
  State<PeopleDirectoryScreen> createState() => _PeopleDirectoryScreenState();
}

class _PeopleDirectoryScreenState extends State<PeopleDirectoryScreen> {
  final TextEditingController _search = TextEditingController();

  String _query = '';
  bool _ascending = true;
  String? _department;
  String? _branch;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      // Any change to the text can alter the result count, so a new query has
      // to return to page one — otherwise the user lands on an empty page.
      setState(() {
        _query = _search.text.trim();
        _page = 0;
      });
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Distinct values for a filter, taken from the data actually present, so
  /// the menu can never offer a department or branch that has no staff.
  List<String> _facets(String key) {
    final seen = <String>{};
    for (final p in widget.staff) {
      final v = p[key]?.toString().trim();
      if (v != null && v.isNotEmpty) seen.add(v);
    }
    return seen.toList()..sort();
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.toLowerCase();
    final out = widget.staff.where((p) {
      if (_department != null && p['department']?.toString() != _department) {
        return false;
      }
      if (_branch != null && p['branch']?.toString() != _branch) return false;
      if (q.isEmpty) return true;
      // Search the name, but also department and branch: an executive typing
      // "marketing" is looking for a person in that department.
      return p.values
          .map((v) => v?.toString().toLowerCase() ?? '')
          .any((v) => v.contains(q));
    }).toList();

    out.sort((a, b) {
      final c = _comparePeopleByName(a, b);
      return _ascending ? c : -c;
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final all = _filtered;
    final pages = (all.length / _kPeoplePageSize).ceil().clamp(1, 9999);
    final page = _page.clamp(0, pages - 1);
    final start = page * _kPeoplePageSize;
    final visible = all.skip(start).take(_kPeoplePageSize).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('People (${all.length})'),
        actions: [
          IconButton(
            tooltip: _ascending ? 'Sort Z to A' : 'Sort A to Z',
            onPressed: () => setState(() {
              _ascending = !_ascending;
              _page = 0;
            }),
            icon: const Icon(Icons.sort_by_alpha),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search name, department or branch',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: _search.clear,
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          // Horizontally scrollable rather than a Row: a long department name
          // would otherwise overflow the width and throw a layout error instead
          // of simply scrolling.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _FilterChip(
                  label: _department ?? 'All departments',
                  active: _department != null,
                  options: _facets('department'),
                  onSelected: (v) => setState(() {
                    _department = v;
                    _page = 0;
                  }),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: _branch ?? 'All branches',
                  active: _branch != null,
                  options: _facets('branch'),
                  onSelected: (v) => setState(() {
                    _branch = v;
                    _page = 0;
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      'No people match these filters.',
                      style: TextStyle(color: AppColors.textSecondary(context)),
                    ),
                  )
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => _PersonTile(
                      person: visible[i],
                      onTap: () {
                        final onOpen = widget.onOpen;
                        if (onOpen == null) return;
                        Navigator.of(context).pop();
                        onOpen(visible[i]);
                      },
                    ),
                  ),
          ),
          if (pages > 1)
            _Pager(
              page: page,
              pages: pages,
              onStep: (delta) => setState(() => _page += delta),
            ),
        ],
      ),
    );
  }
}

/// One person. Split out so the long department/branch string is a single
/// ellipsised line and can never overflow the tile.
class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.person, required this.onTap});

  final Map<String, dynamic> person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      person['designation_title'] ?? person['position'],
      person['department'],
      person['branch'],
    ].where((e) => e != null && '$e'.isNotEmpty).map((e) => '$e').join(' · ');

    return ListTile(
      dense: true,
      title: Text(
        person['full_name']?.toString() ?? 'Unnamed',
        style: const TextStyle(fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: onTap,
    );
  }
}

/// Previous / next with a page counter, so a long roster is navigable.
class _Pager extends StatelessWidget {
  const _Pager({required this.page, required this.pages, required this.onStep});

  final int page;
  final int pages;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Flexible on both sides: the counter plus two labelled buttons must
          // not overflow on a narrow phone or with a long translation.
          Flexible(
            child: TextButton.icon(
              onPressed: page == 0 ? null : () => onStep(-1),
              icon: const Icon(Icons.chevron_left),
              label: const Text('Previous', overflow: TextOverflow.ellipsis),
            ),
          ),
          Text(
            'Page ${page + 1} of $pages',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary(context),
            ),
          ),
          Flexible(
            child: TextButton.icon(
              onPressed: page >= pages - 1 ? null : () => onStep(1),
              icon: const Icon(Icons.chevron_right),
              label: const Text('Next', overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single-select filter opening a menu of the values actually present, so a
/// filter can never offer a department or branch that has no staff.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    required this.options,
    required this.onSelected,
  });

  final String label;
  final bool active;
  final List<String> options;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String?>(
      onSelected: onSelected,
      itemBuilder: (context) => [
        const PopupMenuItem<String?>(value: null, child: Text('All')),
        for (final o in options)
          PopupMenuItem<String?>(value: o, child: Text(o)),
      ],
      child: Chip(
        label: Text(label),
        avatar: Icon(active ? Icons.check : Icons.arrow_drop_down, size: 18),
        // A small font keeps a long department name inside the chip instead of
        // stretching the horizontally scrolling row.
        labelStyle: const TextStyle(fontSize: 12),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
