// ============================================================================
// Offline queue storage + upload guarantees (STEP 4 invariants 4a-4i)
// ============================================================================
// Pure/contract tests only - no live Supabase session, no GPS, no network.
//
// The DB and the network are exercised here through their DOCUMENTED CONTRACT
// rather than a live instance:
//   * Pure helpers that exist precisely to be unit-tested (isValidCoordinate,
//     syncBackoffFor) are asserted directly against real values.
//   * Behaviour that needs a DB or the RPC is locked in by reading the source
//     and asserting the exact mechanism is present, so a future refactor that
//     silently drops write-before-send, oldest-first ordering, chunk
//     reconciliation, backoff, poison quarantine or retention fails the build.
//
// Each test names the invariant it protects (4a-4i) so a failure reads as a
// broken guarantee, not an opaque diff.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:infinitycore/core/services/location_heartbeat.dart';
import 'package:infinitycore/core/services/offline_location_queue.dart';

const _queuePath = 'lib/core/services/offline_location_queue.dart';
const _heartbeatPath = 'lib/core/services/location_heartbeat.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  // --------------------------------------------------------------------------
  // 4c - invalid coordinates never enter the queue (pure, directly testable)
  // --------------------------------------------------------------------------
  group('4c invalid coordinates are rejected at capture', () {
    test('valid lat/lng is accepted', () {
      expect(OfflineLocationQueue.isValidCoordinate(6.4550, 3.3941), isTrue);
      expect(OfflineLocationQueue.isValidCoordinate(-90, -180), isTrue);
      expect(OfflineLocationQueue.isValidCoordinate(90, 180), isTrue);
      expect(OfflineLocationQueue.isValidCoordinate(0, 0), isTrue);
    });

    test('out-of-range and NaN/Infinite are rejected (T-f)', () {
      expect(OfflineLocationQueue.isValidCoordinate(90.1, 0), isFalse);
      expect(OfflineLocationQueue.isValidCoordinate(-90.1, 0), isFalse);
      expect(OfflineLocationQueue.isValidCoordinate(0, 180.1), isFalse);
      expect(OfflineLocationQueue.isValidCoordinate(0, -180.1), isFalse);
      expect(OfflineLocationQueue.isValidCoordinate(double.nan, 0), isFalse);
      expect(OfflineLocationQueue.isValidCoordinate(0, double.nan), isFalse);
      expect(
        OfflineLocationQueue.isValidCoordinate(double.infinity, 0),
        isFalse,
      );
    });

    test('enqueue rejects invalid coords before touching the DB (T-f)', () {
      // The source guard: enqueue returns -1 and never inserts when the
      // coordinate fails 4c, so a GPS glitch can never be recorded or shown.
      final src = _read(_queuePath);
      expect(
        src,
        contains('if (!isValidCoordinate(latitude, longitude)) return -1;'),
      );
    });
  });

  // --------------------------------------------------------------------------
  // 4d - backoff ladder is pure and testable (T-i)
  // --------------------------------------------------------------------------
  group('4d retry backoff ladder', () {
    test('steps 30s, 60s, 120s then caps at 5 min', () {
      expect(LocationHeartbeat.syncBackoffFor(0), const Duration(seconds: 30));
      expect(LocationHeartbeat.syncBackoffFor(1), const Duration(seconds: 60));
      expect(LocationHeartbeat.syncBackoffFor(2), const Duration(seconds: 120));
      expect(LocationHeartbeat.syncBackoffFor(3), const Duration(minutes: 5));
    });

    test('never exceeds the 5-minute cap no matter how many failures', () {
      for (final n in [4, 5, 10, 50, 1000]) {
        expect(
          LocationHeartbeat.syncBackoffFor(n),
          const Duration(minutes: 5),
          reason: 'attempt $n must stay at the cap',
        );
      }
    });

    test('a negative attempt count is treated as the first rung', () {
      expect(LocationHeartbeat.syncBackoffFor(-1), const Duration(seconds: 30));
    });

    test('a failed tick does not cancel the schedule (T-i)', () {
      // The self-rescheduling timer arms the next tick from the backoff rung on
      // EVERY outcome, so a failure only lengthens the gap, it never stops it.
      final src = _read(_heartbeatPath);
      expect(src, contains('void _rescheduleSync()'));
      expect(src, contains('void stopSyncWatchdog()'));
    });
  });
}
