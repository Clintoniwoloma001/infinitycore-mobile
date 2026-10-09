import 'dart:async';

import 'package:sqflite/sqflite.dart';

/// Durable offline location queue (SQLite, WAL mode).
/// Replaces the previous encrypted JSON blob in flutter_secure_storage.
class OfflineLocationQueue {
  OfflineLocationQueue._();
  static final OfflineLocationQueue instance = OfflineLocationQueue._();

  Database? _db;

  static const String _dbName = 'offline_location_queue.db';
  static const int _version = 1;

  /// Hard upper bound on queue rows (invariant 4f). A device that stays offline
  /// for days still must not grow the file forever. Only rows the cap forces
  /// out are ever dropped past the 24h synced purge, and that is reported.
  static const int maxRows = 20000;

  /// Idempotent schema creation.
  ///
  /// Devices upgraded from earlier app generations already carry an
  /// `offline_location_queue` table in a DB file whose `user_version` is
  /// 0 (created without a version). sqflite then runs [onCreate], and a
  /// plain `CREATE TABLE` throws "table already exists" on every open —
  /// which broke the ENTIRE queue (enqueue/getUnsynced) on those devices
  /// and meant zero location rows ever reached the server. All DDL here
  /// must therefore be `IF NOT EXISTS`.
  static Future<void> _ensureSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS offline_location_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id TEXT,
        latitude REAL,
        longitude REAL,
        accuracy REAL,
        battery_level REAL,
        network_status TEXT,
        recorded_at TEXT NOT NULL,
        is_synced INTEGER DEFAULT 0,
        attempts INTEGER DEFAULT 0,
        state TEXT DEFAULT 'ok',
        created_at INTEGER DEFAULT (strftime('%s','now'))
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_offline_unsynced ON offline_location_queue(is_synced, recorded_at ASC)',
    );
    await db.execute('PRAGMA journal_mode = WAL');
    // Stamp the schema version so a future release can detect an older DB and
    // migrate it instead of dropping it (invariant 4a). sqflite persists this
    // as PRAGMA user_version.
    await db.execute('PRAGMA user_version = 1');
    // In-place migration for databases created by the previous generation,
    // which had no `state` column. Only ALTER when the column is genuinely
    // absent, so this is safe to run on every open (invariant 4e/4a).
    final cols = await db.rawQuery('PRAGMA table_info(offline_location_queue)');
    final hasState = cols.any((c) => c['name'] == 'state');
    if (!hasState) {
      await db.execute(
        "ALTER TABLE offline_location_queue ADD COLUMN state TEXT DEFAULT 'ok'",
      );
    }
  }

  /// A row that has failed this many consecutive upload attempts is poison: the
  /// server will keep rejecting it, so it must be quarantined and reported
  /// rather than blocking every later row (invariant 4e).
  static const int maxAttempts = 10;

  Future<Database> get _database async {
    if (_db != null && _db!.isOpen) return _db!;
    final dbPath = await getDatabasesPath();
    // Build the file path with a plain '/' join instead of package:path.
    // On Android getDatabasesPath() returns the app databases directory - the
    // same location the native Kotlin service opens via context.getDatabasePath
    // - so joining with '/' keeps the Dart heartbeat and the foreground service
    // pointing at ONE file. (path was a transitive-only dependency.)
    final dir = dbPath.endsWith('/') ? dbPath : '$dbPath/';
    _db = await openDatabase(
      '$dir$_dbName',
      version: _version,
      singleInstance: true,
      onCreate: (db, version) => _ensureSchema(db),
      onUpgrade: (db, oldV, newV) => _ensureSchema(db),
      onDowngrade: (db, oldV, newV) => _ensureSchema(db),
    );
    // WAL + a busy timeout: the Dart heartbeat and the native foreground
    // service open the SAME file, so a writer can hit a locked DB. WAL lets
    // readers and a writer coexist; busy_timeout makes the other side wait a
    // few seconds for the lock instead of failing with SQLITE_BUSY and dropping
    // a fix. Both belong to invariant 4a (one file, shared safely).
    await _db!.execute('PRAGMA journal_mode = WAL');
    await _db!.execute('PRAGMA busy_timeout = 5000');
    return _db!;
  }

  /// True only for a coordinate that is physically possible: within the valid
  /// lat/lng ranges and not NaN. A GPS glitch that yields (0,0) off the coast
  /// of Africa, or a NaN from a cold fix, must never reach the queue - it would
  /// be indistinguishable from a real position and poison movement history.
  /// Pure and static so it is unit-testable without a database (invariant 4c).
  static bool isValidCoordinate(double lat, double lng) {
    if (lat.isNaN || lng.isNaN) return false;
    if (lat.isInfinite || lng.isInfinite) return false;
    if (lat < -90 || lat > 90) return false;
    if (lng < -180 || lng > 180) return false;
    return true;
  }

  /// Insert a captured location point (always before attempting upload).
  ///
  /// [recordedAt] MUST be the fix's own timestamp, not now(): the online path
  /// uploads this same fix directly AND leaves the row for the batch flush, so
  /// both sends have to carry an identical recorded_at for the server's
  /// (employee_id, recorded_at, latitude, longitude) dedupe to collapse them
  /// into one row (invariant 4b). Defaulting to now() is only a safety net.
  ///
  /// Returns the new row id, or -1 if the coordinate was invalid and therefore
  /// deliberately not recorded (invariant 4c). A rejected point never enters
  /// the queue, so it can never be uploaded or shown as a live position.
  Future<int> enqueue({
    required double latitude,
    required double longitude,
    double? accuracy,
    double? batteryLevel,
    String? networkStatus,
    String? employeeId,
    DateTime? recordedAt,
  }) async {
    if (!isValidCoordinate(latitude, longitude)) return -1;
    final db = await _database;
    final recorded = (recordedAt ?? DateTime.now()).toUtc().toIso8601String();
    return await db.insert('offline_location_queue', {
      'employee_id': employeeId,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'battery_level': batteryLevel,
      'network_status': networkStatus,
      'recorded_at': recorded,
      'is_synced': 0,
      'attempts': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Select unsynced rows ordered by recorded_at ASC, capped.
  ///
  /// Quarantined (poison) rows are excluded so a permanently-failing fix can
  /// never block the rows behind it from being uploaded (invariant 4e).
  Future<List<Map<String, dynamic>>> getUnsynced({int limit = 200}) async {
    final db = await _database;
    final rows = await db.query(
      'offline_location_queue',
      where: "is_synced = ? AND state = 'ok'",
      whereArgs: [0],
      orderBy: 'recorded_at ASC',
      limit: limit,
    );
    return rows;
  }

  /// Move rows to the quarantined state so they stop being retried but are kept
  /// on disk for diagnosis. The caller reports them through
  /// record_tracking_diagnostic; the queue never deletes them silently
  /// (invariant 4e).
  Future<void> quarantine(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final batch = db.batch();
    for (final id in ids) {
      batch.update(
        'offline_location_queue',
        {'state': 'quarantined'},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Any unsynced row that has already failed [maxAttempts] times (invariant
  /// 4e). Used by the flush to quarantine poison rows before they block the
  /// queue.
  Future<List<int>> poisonIds() async {
    final db = await _database;
    final rows = await db.query(
      'offline_location_queue',
      columns: ['id'],
      where: 'is_synced = ? AND state = ? AND attempts >= ?',
      whereArgs: [0, 'ok', maxAttempts],
    );
    return rows.map((r) => r['id'] as int).toList();
  }

  /// Mark rows as synced (by their DB id).
  Future<void> markSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final batch = db.batch();
    for (final id in ids) {
      batch.update(
        'offline_location_queue',
        {'is_synced': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Increment attempts for unsynced rows.
  Future<void> incrementAttempts(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final batch = db.batch();
    for (final id in ids) {
      batch.rawUpdate(
        'UPDATE offline_location_queue SET attempts = attempts + 1 WHERE id = ?',
        [id],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Purge rows synced longer than 24h (older than now - 24h, is_synced=1).
  Future<int> purgeOldSynced() async {
    final db = await _database;
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 24))
        .toIso8601String();
    return await db.delete(
      'offline_location_queue',
      where: 'is_synced = ? AND recorded_at < ?',
      whereArgs: [1, cutoff],
    );
  }

  /// Cap the queue at [maxRows] (20,000) so it can never grow without bound on
  /// a device that stays offline for a long time (invariant 4f).
  ///
  /// Retention order is deliberately safe:
  ///   1. First drop SYNCED rows older than 24h - already on the server, so
  ///      removing them loses nothing.
  ///   2. Only if the queue is still over the cap do we drop the oldest
  ///      UNSYNCED rows, and we surface that through a diagnostic so it is
  ///      never a silent loss. Unsynced rows must survive, so this is the last
  ///      resort, not the first move.
  Future<void> capQueue() async {
    final db = await _database;
    final total =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM offline_location_queue'),
        ) ??
        0;
    if (total <= maxRows) return;

    // Step 1: synced rows older than 24h are free to drop.
    await purgeOldSynced();

    final afterSyncedPurge =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM offline_location_queue'),
        ) ??
        0;
    if (afterSyncedPurge <= maxRows) return;

    // Step 2: still over the cap. Drop the oldest rows (which may be unsynced)
    // to make room, and report it so the loss is visible rather than silent.
    final overflow = afterSyncedPurge - maxRows;
    await db.rawDelete(
      'DELETE FROM offline_location_queue WHERE id IN (SELECT id FROM offline_location_queue ORDER BY recorded_at ASC LIMIT ?)',
      [overflow],
    );
    onCapOverflow?.call(overflow);
  }

  /// Invoked when the hard cap forces oldest rows (which may be unsynced) to be
  /// dropped. Wired by the heartbeat to `record_tracking_diagnostic` so a cap
  /// overflow is reported server-side instead of disappearing (invariant 4f).
  static void Function(int dropped)? onCapOverflow;

  /// Count unsynced + count total (for status display).
  Future<(int unsynced, int total)> counts() async {
    final db = await _database;
    final unsynced =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM offline_location_queue WHERE is_synced = 0',
          ),
        ) ??
        0;
    final total =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM offline_location_queue'),
        ) ??
        0;
    return (unsynced, total);
  }
}
