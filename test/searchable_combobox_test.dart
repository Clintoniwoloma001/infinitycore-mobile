// Tests for the universal searchable select.
//
// The rules under test:
//   * typing filters the option list by substring,
//   * the list only appears while the field has focus,
//   * choosing an option commits its label and fires onSelected once,
//   * clearing fires onSelected(null).
//
// The label used for filtering is deliberately supplied by the caller via
// labelBuilder, so a rich option row and a searchable string cannot drift.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/shared/widgets/searchable_combobox.dart';

const _people = ['Head of HR', 'Head of FINCON', 'Branch Manager', 'MD/CEO'];

Widget host({
  String? selected,
  ValueChanged<String?>? onChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => SearchableCombobox<String>(
          label: 'Supervisor',
          value: selected,
          items: _people,
          labelBuilder: (p) => p,
          itemBuilder: (context, item, isSelected) => Text(item),
          onSelected: (v) {
            setState(() => selected = v);
            onChanged?.call(v);
          },
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows the committed label but not the list, until focused',
      (tester) async {
    await tester.pumpWidget(host(selected: 'Head of HR'));

    expect(find.text('Head of HR'), findsOneWidget); // the field's own text
    // The option list is not on screen before focus.
    expect(find.text('MD/CEO'), findsNothing);
  });

  testWidgets('focusing reveals every option', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    for (final p in _people) {
      expect(find.text(p), findsWidgets, reason: '$p should be listed');
    }
  });

  testWidgets('typing filters the list by substring', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'head of');
    await tester.pumpAndSettle();

    expect(find.text('Head of HR'), findsWidgets);
    expect(find.text('Head of FINCON'), findsWidgets);
    expect(find.text('MD/CEO'), findsNothing,
        reason: 'MD/CEO does not contain "head of"');
  });

  testWidgets('a search with no matches shows the empty message',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();

    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('choosing an option commits it and fires onSelected once',
      (tester) async {
    final picked = <String?>[];
    await tester.pumpWidget(host(onChanged: picked.add));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await tester.tap(find.text('MD/CEO').last);
    await tester.pumpAndSettle();

    expect(picked, ['MD/CEO']);
    expect(find.text('MD/CEO'), findsOneWidget,
        reason: 'the choice is committed into the field');
  });

  testWidgets('the clear button fires onSelected(null)', (tester) async {
    final picked = <String?>[];
    await tester.pumpWidget(host(selected: 'MD/CEO', onChanged: picked.add));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();

    expect(picked, [null]);
  });

  testWidgets('the filter is case-insensitive', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'fincon');
    await tester.pumpAndSettle();

    expect(find.text('Head of FINCON'), findsWidgets);
  });
}
