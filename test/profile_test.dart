import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infinitycore/core/theme/app_theme.dart';
import 'package:infinitycore/features/profile/personal_details_sheet.dart';
import 'package:infinitycore/features/profile/profile_service.dart';
import 'package:infinitycore/features/profile/staff_id_card.dart';

void main() {
  // A representative employee record. Values are obviously synthetic and are
  // only used to drive the widgets — nothing here is persisted or sent.
  final sample = PersonalProfile(
    employeeId: 'emp-1',
    row: const {
      'id': 'emp-1',
      'full_name': 'Ada Nwosu',
      'email': 'ada@example.test',
      'phone': '+234 800 000 0000',
      'employee_number': 'IC-0042',
      'staff_id_status': 'active',
      'staff_id_issued_at': '2026-01-15',
      'staff_id_expiry': '2028-01-15',
      'department': 'Operations',
      'position': 'Branch Manager',
      'branch': 'Ketu',
      'date_of_birth': '1990-04-12',
      'sex': 'Female',
      'marital_status': 'Married',
      'nationality': 'Nigerian',
      'state_of_origin': 'Lagos',
      'lga': 'Ikeja',
      'town': 'Lagos',
      'residential_address': '12 Allen Avenue',
      'spouse_name': 'Chidi Nwosu',
      'spouse_occupation': 'Engineer',
      'spouse_phone': '+234 802 000 0000',
      'emergency_contact_name': 'Uche Nwosu',
      'emergency_contact_phone': '+234 803 000 0000',
    },
  );

  Widget host(Widget child, {ThemeMode mode = ThemeMode.light}) => MaterialApp(
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: mode,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  /// Opens the editor exactly the way the profile screen does — through
  /// `showPersonalDetailsSheet` — because the sheet relies on the bounded
  /// height that helper provides and would not lay out in a bare scroll view.
  Future<void> openEditor(WidgetTester tester, PersonalProfile profile) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    showPersonalDetailsSheet(context, profile: profile),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('StaffIdCardSheet', () {
    testWidgets('renders identity, staff number and branch', (tester) async {
      await tester.pumpWidget(host(StaffIdCardSheet(profile: sample)));
      await tester.pump();

      // The green banner label plus the sheet's own heading.
      expect(find.text('Staff ID Card'), findsNWidgets(2));
      expect(find.text('Identity & Access'), findsOneWidget);
      expect(find.text('Ada Nwosu'), findsWidgets);
      // Front meta grid and the back header both carry the number.
      expect(find.text('IC-0042'), findsNWidgets(2));
      expect(find.text('Ketu'), findsNWidgets(2));
      expect(find.text('Branch Manager'), findsOneWidget);
      expect(find.text('Operations'), findsOneWidget);
      // The web labels the meta grid in upper case.
      expect(find.text('STAFF ID'), findsOneWidget);
      expect(find.text('DEPARTMENT'), findsOneWidget);
      expect(find.text('STATUS'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
    });

    testWidgets('shows the emergency contact number', (tester) async {
      await tester.pumpWidget(host(StaffIdCardSheet(profile: sample)));
      await tester.pump();
      expect(find.text('+234 803 000 0000'), findsOneWidget);
    });

    testWidgets('shows the issue and expiry dates', (tester) async {
      await tester.pumpWidget(host(StaffIdCardSheet(profile: sample)));
      await tester.pump();
      // The front meta grid renders its labels in upper case...
      expect(find.text('ISSUE DATE'), findsOneWidget);
      expect(find.text('EXPIRY DATE'), findsOneWidget);
      // ...while the back's label/value rows keep web sentence case.
      expect(find.text('Issued By'), findsOneWidget);
      expect(find.text('Human Resources'), findsOneWidget);
      expect(find.text('HUMAN RESOURCES'), findsNWidgets(2));
    });

    testWidgets('paints in dark mode without overflowing', (tester) async {
      await tester.pumpWidget(
        host(StaffIdCardSheet(profile: sample), mode: ThemeMode.dark),
      );
      await tester.pump();
      expect(find.text('Ada Nwosu'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('degrades gracefully with an empty record', (tester) async {
      final blank = PersonalProfile(employeeId: 'e', row: const {});
      await tester.pumpWidget(host(StaffIdCardSheet(profile: blank)));
      await tester.pump();

      // No crash, and the missing values read as the web component's explicit
      // placeholders rather than blank rows. 'Head Office' appears on both
      // faces, since the branch is printed on the front grid and the back row.
      expect(find.text('—'), findsWidgets);
      expect(find.text('Head Office'), findsNWidgets(2));
      expect(find.text('Staff'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('falls back to staff_id when employee_number is absent', (
      tester,
    ) async {
      final legacy = PersonalProfile(
        employeeId: 'e',
        row: const {'full_name': 'Ada', 'staff_id': 'STF-77'},
      );
      await tester.pumpWidget(host(StaffIdCardSheet(profile: legacy)));
      await tester.pump();
      expect(find.text('STF-77'), findsNWidgets(2));
    });

    testWidgets('an expired card is labelled EXPIRED in red', (tester) async {
      final expired = PersonalProfile(
        employeeId: 'e',
        row: const {
          'full_name': 'Ada',
          'employee_number': 'IC-9',
          'staff_id_status': 'expired',
        },
      );
      await tester.pumpWidget(host(StaffIdCardSheet(profile: expired)));
      await tester.pump();
      expect(find.text('EXPIRED'), findsWidgets);
    });

    testWidgets('renders the reverse side, not just the front', (tester) async {
      await tester.pumpWidget(host(StaffIdCardSheet(profile: sample)));
      await tester.pump();

      // The back carries the emergency contact and both signature rules, which
      // is what makes this a two-sided card rather than a name badge.
      expect(find.text('Emergency Contact'), findsOneWidget);
      expect(find.text('MANAGEMENT SIGNATURE'), findsOneWidget);
      expect(find.text('CARD HOLDER SIGNATURE'), findsOneWidget);
      expect(find.text('Management / HR'), findsOneWidget);
      expect(find.text('Employee Signature'), findsOneWidget);
      expect(find.text('This card has no expiry.'), findsNothing);
    });

    testWidgets('a jsonb branch object renders the name, not raw JSON', (
      tester,
    ) async {
      // `mobile_get_my_employee` returns `branch` as a jsonb object. Printing
      // that object verbatim put "{id: 017fa140-…}" on the card.
      final withJsonBranch = PersonalProfile(
        employeeId: 'e',
        row: const {
          'full_name': 'Ada',
          'employee_number': 'IC-1',
          'branch': {'id': '017fa140-fc83', 'branch_name': 'Ikeja'},
        },
      );
      await tester.pumpWidget(host(StaffIdCardSheet(profile: withJsonBranch)));
      await tester.pump();

      expect(find.text('Ikeja'), findsNWidgets(2));
      // The raw jsonb must never reach the screen.
      expect(find.textContaining('017fa140'), findsNothing);
    });
  });

  /// Opens the card through the real entry point, so the close button is
  /// exercised the way a user reaches it - as a modal sheet that must pop.
  Future<void> openCard(WidgetTester tester, PersonalProfile p) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showStaffIdCard(context, profile: p),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('Staff ID Card close control', () {
    testWidgets('shows a back button that dismisses the card', (tester) async {
      await openCard(tester, sample);

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // The sheet is gone and the caller is visible again.
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('the close control is a real tap target', (tester) async {
      await openCard(tester, sample);
      // A visible, labelled control must exist - not just a system back gesture.
      expect(find.byType(IconButton), findsWidgets);
      expect(find.byTooltip('Close'), findsOneWidget);
    });
  });

  group('PersonalDetailsSheet', () {
    testWidgets('seeds the form from the record', (tester) async {
      await openEditor(tester, sample);

      expect(find.text('Personal details'), findsOneWidget);
      // Section labels render upper-cased in the UI.
      expect(find.text('CONTACT'), findsOneWidget);
      // Existing values are pre-filled, not blank.
      expect(find.text('Ada Nwosu'), findsWidgets);
    });

    testWidgets('the last section is reachable by scrolling', (tester) async {
      await openEditor(tester, sample);
      // The form is a scrollable list, so later sections are not built until
      // they are scrolled into view.
      expect(find.text('EMERGENCY CONTACT'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(find.text('EMERGENCY CONTACT'), findsOneWidget);
    });

    testWidgets('always offers Save, even when nothing changed', (
      tester,
    ) async {
      await openEditor(tester, sample);
      // The server, not the client, decides what it will accept, so Save is
      // never disabled on the basis of a local completeness guess.
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('renders without overflow on a small phone', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await openEditor(tester, sample);
      expect(tester.takeException(), isNull);
    });
  });
}
