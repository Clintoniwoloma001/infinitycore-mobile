# INFNTYCORE-MOBILE

Saved session handoff for the InfinityCore Flutter mobile application.

## Snapshot

- Saved: 2026-09-25 11:19 WAT
- Repository: `/Users/clintoniwolomaimaginr/Developer/InfinityBank/infinitycore-mobile`
- Branch: `main`
- Base commit: `df0d30971e2f12b4c3569f1a6e9df52a5fbefb78`
- Flutter: 3.47.4 (stable)
- Dart: 3.13.3
- Supabase CLI: 2.117.0
- At snapshot creation, the working tree was preserved without a stash or commit.
- The stray final `$$;` delimiter in the new migration was subsequently removed.

## Work In Progress

The current uncommitted work improves Android attendance reminders and makes
notification actions execute the real, geofence-checked clock-in/out flow.

### Changed files

- `android/app/src/main/AndroidManifest.xml`
  - Adds notification, exact-alarm, and boot-completed permissions.
  - Registers flutter_local_notifications scheduled/action/boot receivers.
- `lib/core/services/notification_service.dart`
  - Adds separate clock-in and clock-out notification actions.
  - Queues cold-start and foreground quick actions for the attendance screen.
  - Requests Android notification and exact-alarm permissions.
  - Attempts exact reminders and falls back to inexact scheduling with logging.
  - Uses the foreground launcher icon for Android notifications.
- `lib/core/services/reminder_service.dart`
  - Re-syncs reminders when the app resumes.
  - Continues re-arming on auth changes and after attendance writes.
- `lib/features/attendance/attendance_screen.dart`
  - Listens for notification quick actions and invokes normal clock actions.
  - Uses one fresh-location/geofence path for preview, clock-in, and clock-out.
  - Re-syncs reminders after successful punches.
- `lib/features/attendance/attendance_service.dart`
  - Converts geolocation timeout, disabled-service, and generic failures into
    user-facing errors.
- `lib/main.dart`
  - Awaits notification/exact-alarm permission requests before starting
    reminder synchronization.
- `pubspec.yaml`
  - Bumps the app from `1.0.0+1` to `1.0.1+3`.
- `supabase/migrations/20260925000000_fix_attendance_verification_method.sql`
  - New, untracked migration intended to allow `BIOMETRIC+GPS`,
    `BIOMETRIC+GPS+QR`, and `GPS+QR` in the verification-method checks on both
    `attendance_records` and `attendance_events`.

Diff size before this handoff was 7 tracked files changed, 223 insertions, and
65 deletions, plus the untracked Supabase migration.

## Validation

- `git diff --check`: passed.
- `flutter test`: passed; 47 tests passed.
- `flutter analyze`: completed with 5 info-level lints and no warnings/errors:
  - modified file: `attendance_screen.dart:188` and `:197` (braces);
  - existing files: `chat_screen.dart:118`,
    `conversation_screen.dart:172`, and `settings_screen.dart:25` (braces).
- The Supabase migration was not applied or database-tested. No production data
  or credentials were changed during validation.

## Known Risks / Resume Point

1. The migration's stray final `$$;` delimiter has been removed. The migration
   still requires review and database testing before it is applied.
2. Run the two attendance lint fixes in `attendance_screen.dart`, then rerun
   `flutter analyze` if a zero-info analysis is required.
3. Manually test on an Android physical device:
   - notification and exact-alarm permission paths;
   - reboot rescheduling;
   - clock-in and clock-out reminder actions in foreground and cold-start;
   - that quick actions still require biometric verification, trusted device
     binding, a fresh GPS fix, and a valid geofence;
   - reminder cancellation/rescheduling after successful attendance writes.
4. Build Android after the manifest changes, then release through the project's
   established Shorebird workflow when all checks pass.
5. Review and commit the tracked Dart/Android changes and the migration together
   only after database migration validation.

## Resume Prompt

Read this file first, inspect `git status` and the full diff, database-test the
corrected migration, address the two lints in the modified attendance screen,
then complete Android device testing before applying the migration or releasing.
