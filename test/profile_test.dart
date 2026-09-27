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
                onPressed: () => showPersonalDetailsSheet(
                  context,
                  profile: profile,
                ),
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

      expect(find.text('Staff ID Card'), findsOneWidget);
      expect(find.text('INFINITYCORE'), findsOneWidget);
      expect(find.text('Ada Nwosu'), findsOneWidget);
      expect(find.text('IC-0042'), findsOneWidget);
      expect(find.text('Ketu'), findsOneWidget);
      expect(find.text('Branch Manager'), findsOneWidget);
      expect(find.text('Operations'), findsOneWidget);
    });

    testWidgets('shows the emergency contact number', (tester) async {
      await tester.pumpWidget(host(StaffIdCardSheet(profile: sample)));
      await tester.pump();
      expect(find.text('+234 803 000 0000'), findsOneWidget);
    });

    testWidgets('shows the issue and expiry dates', (tester) async {
      await tester.pumpWidget(host(StaffIdCardSheet(profile: sample)));
      await tester.pump();
      expect(find.text('Issued'), findsOneWidget);
      expect(find.text('Expires'), findsOneWidget);
      expect(find.text('Human Resources'), findsOneWidget);
    });

    testWidgets('paints in dark mode without overflowing', (tester) async {
      await tester.pumpWidget(
        host(StaffIdCardSheet(profile: sample), mode: ThemeMode.dark),
      );
      await tester.pump();
      expect(find.text('Ada Nwosu'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('degrades gracefully with an empty record', (tester) async {
      final blank = PersonalProfile(employeeId: 'e', row: const {});
      await tester.pumpWidget(host(StaffIdCardSheet(profile: blank)));
      await tester.pump();

      // No crash, and the missing values read as explicit placeholders rather
      // than blank rows.
      expect(find.text('Staff member'), findsOneWidget);
      expect(find.text('Not assigned'), findsOneWidget);
      expect(find.text('Head Office'), findsOneWidget);
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
      expect(find.text('STF-77'), findsOneWidget);
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

    testWidgets('always offers Save, even when nothing changed', (tester) async {
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
