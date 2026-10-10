// ============================================================================
// Regression guards for the offline queue PRAGMA defect
// ============================================================================
// THE DEVICE-CONFIRMED BUG THIS LOCKS OUT (logcat, SM-J415F, 1.1.8+21):
//
//   I/flutter: error DatabaseException(unknown error (code 0 SQLITE_OK[0]):
//     Queries can be performed using SQLiteDatabase query or rawQuery methods
//     only.) sql 'PRAGMA journal_mode = WAL' args [] during open, closing...
//   W/InfinityCoreLocation: offline queue sqlite insert failed: ... PRAGMA ...
//   W/InfinityCoreLocation: server rejected fix: HTTP 401
//
// `PRAGMA journal_mode = WAL` RETURNS A ROW, and Android's execSQL() rejects any
// statement that produces a result set. So the database never opened, no
// observation was ever captured or queued, and the heartbeat swallowed the
// failure and reported "Waiting for GPS". That is why offline location tracking
// appeared never to start, and why the queue-based fallback could not work.
//
// The same mistake existed natively in LocationForegroundService.kt, where it
// threw before the INSERT was ever prepared.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const _queueSource = 'lib/core/services/offline_location_queue.dart';
const _nativeSource =
    'android/app/src/main/kotlin/com/infinitybank/infinitycore/'
    'LocationForegroundService.kt';

void main() {
  group('Offline queue PRAGMA handling', () {
    test('WAL is READ, never executed, on the Dart side', () {
      final source = File(_queueSource).readAsStringSync();

      expect(
        source,
        contains("rawQuery('PRAGMA journal_mode = WAL')"),
        reason: 'journal_mode returns a row, so it must be read with rawQuery',
      );
      expect(
        source,
        isNot(contains("execute('PRAGMA journal_mode = WAL')")),
        reason: 'execSQL on a returning statement aborts the database open',
      );
      expect(
        source,
        contains("rawQuery('PRAGMA busy_timeout = 5000')"),
        reason: 'treat busy_timeout identically so the failure cannot return',
      );
      expect(
        source,
        isNot(contains("execute('PRAGMA busy_timeout = 5000')")),
      );
    });

    test('WAL is READ, never executed, natively too', () {
      final source = File(_nativeSource).readAsStringSync();

      expect(
        source,
        contains('rawQuery("PRAGMA journal_mode = WAL", null)'),
        reason: 'the native service writes to the SAME file and hit the same '
            'exception before its INSERT was even prepared',
      );
      expect(
        source,
        isNot(contains('execSQL("PRAGMA journal_mode = WAL")')),
      );
      expect(
        source,
        isNot(contains('execSQL("PRAGMA busy_timeout = 5000")')),
      );
    });

    test('the native catch no longer blames the INSERT for every failure', () {
      // The old catch logged "insert failed" for the PRAGMA exception, which
      // pointed every operator at the wrong line for an entire release cycle.
      final source = File(_nativeSource).readAsStringSync();
      expect(
        source,
        isNot(contains('offline queue sqlite insert failed')),
        reason: 'the message must name the stage that actually failed',
      );
    });

    test('user_version is still stamped so schema upgrades are detected', () {
      // This PRAGMA is a write with no result set, so execute() is correct for
      // it - do not "fix" it the same way and break nothing.
      final source = File(_queueSource).readAsStringSync();
      expect(source, contains("PRAGMA user_version = 1"));
    });
  });
}
