import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A searchable select used anywhere the app needs to pick one value from a
/// long list.
///
/// WHY THIS EXISTS: a plain `DropdownButton` cannot be typed into, so picking
/// one supervisor out of 120 executives means scrolling a list blind. Every
/// select in the app routes through this widget so filtering is the default
/// rather than a per-screen decision that someone eventually forgets.
///
/// Two behaviours worth knowing:
///
///   * The filter is a case-insensitive SUBSTRING match, not a fuzzy matcher.
///     Fuzzy search on short executive titles ("HOD", "Head of ...") produces
///     confusing near-misses, and a substring match is predictable enough that
///     a user can predict what typing will do.
///   * Options that the caller marks as not selectable are still shown, greyed
///     out. Hiding them would make the field look broken when a list is
///     legitimately empty for the current filter.
class SearchableCombobox<T> extends StatefulWidget {
  const SearchableCombobox({
    super.key,
    required this.label,
    required this.items,
    required this.labelBuilder,
    required this.itemBuilder,
    required this.onSelected,
    this.value,
    this.hint,
    this.enabled = true,
    this.emptyMessage = 'No matches',
    this.itemHeight = 48,
  });

  /// Field label, also the semantics label.
  final String label;

  /// The full option list. Order is preserved — the caller decides ranking.
  final List<T> items;

  /// The plain-text label for one option.
  ///
  /// This drives BOTH the committed text in the field and the filter, so it
  /// must be the text a user would actually type to find that option. It is
  /// deliberately separate from [itemBuilder]: the visible row may be a rich
  /// two-line card, but filtering has to run against readable text.
  final String Function(T item) labelBuilder;

  /// Renders one option row.
  final Widget Function(BuildContext context, T item, bool selected)
  itemBuilder;

  /// Fired with the chosen option, or null when the selection is cleared.
  final ValueChanged<T?> onSelected;

  final T? value;
  final String? hint;
  final bool enabled;
  final String emptyMessage;
  final double itemHeight;

  @override
  State<SearchableCombobox<T>> createState() => _SearchableComboboxState<T>();
}

class _SearchableComboboxState<T> extends State<SearchableCombobox<T>> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// The committed display text, i.e. the chosen option's own label.
  late String _display;

  /// What the user has typed. Null means "not searching".
  String? _query;

  @override
  void initState() {
    super.initState();
    _display = _labelFor(widget.value);
    // The controller must actually hold the committed label, otherwise the
    // field renders empty and a pre-selected value looks unset.
    _controller.text = _display;
    _controller.addListener(_onChanged);
    // `build` reads `_focus.hasFocus` to decide whether to show the option
    // list, so a focus change MUST schedule a rebuild. Without this listener
    // the list never appears: tapping the field does not re-run build.
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(SearchableCombobox<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-sync when the parent replaces the value (e.g. a reset button), but do
    // NOT clobber text the user is currently typing.
    if (widget.value != oldWidget.value && !_focus.hasFocus) {
      _display = _labelFor(widget.value);
      if (_controller.text != _display) _controller.text = _display;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _focus.removeListener(_onFocusChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    final text = _controller.text;
    // Typing something other than the committed label means "I am searching".
    if (text == _display) {
      if (_query != null) setState(() => _query = null);
      return;
    }
    setState(() => _query = text);
  }

  String _labelFor(T? item) => item == null ? '' : widget.labelBuilder(item);

  /// Substring filter. Empty query returns everything, unfiltered.
  List<T> get _filtered {
    final q = _query?.trim().toLowerCase() ?? '';
    if (q.isEmpty) return widget.items;
    return widget.items
        .where((i) => _labelFor(i).toLowerCase().contains(q))
        .toList(growable: false);
  }

  void _choose(T item) {
    final label = _labelFor(item);
    setState(() {
      _display = label;
      _query = null;
    });
    _controller.text = label;
    _focus.unfocus();
    widget.onSelected(item);
  }

  void _clear() {
    setState(() {
      _display = '';
      _query = null;
    });
    _controller.clear();
    widget.onSelected(null);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final hasValue = _display.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary(context),
            ),
          ),
        ),
        TextField(
          controller: _controller,
          focusNode: _focus,
          enabled: widget.enabled,
          onTap: () {
            // Tapping an already-committed value starts a fresh search rather
            // than leaving the user unable to edit it.
            if (_query == null && hasValue) {
              _controller.clear();
              setState(() => _query = '');
            }
          },
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hint ?? 'Type to search…',
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: hasValue
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 16),
                    tooltip: 'Clear',
                    onPressed: _clear,
                  )
                : null,
            border: const OutlineInputBorder(),
          ),
        ),
        // Only present the list while the field has focus, so the form does not
        // permanently grow a 120-row menu the moment it is rebuilt.
        if (_focus.hasFocus) ...[
          const SizedBox(height: 4),
          _optionList(context, filtered),
        ],
      ],
    );
  }

  Widget _optionList(BuildContext context, List<T> filtered) {
    if (filtered.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: _panelDecoration(context),
        child: Text(
          widget.emptyMessage,
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textTertiary(context),
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: Container(
        decoration: _panelDecoration(context),
        child: ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: filtered.length,
          itemBuilder: (context, i) {
            final item = filtered[i];
            return InkWell(
              onTap: () => _choose(item),
              child: Container(
                constraints: BoxConstraints(minHeight: widget.itemHeight),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: widget.itemBuilder(context, item, item == widget.value),
              ),
            );
          },
        ),
      ),
    );
  }

  BoxDecoration _panelDecoration(BuildContext context) => BoxDecoration(
    color: AppColors.surface(context),
    borderRadius: BorderRadius.circular(8),
    border: Border.all(color: AppColors.border(context)),
  );
}
