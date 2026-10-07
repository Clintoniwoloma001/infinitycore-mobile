import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Durable offline location queue (SQLite, WAL mode).
/// Replaces the previous encrypted JSON blob in flutter_secure_storage.
class OfflineLocationQueue {
  OfflineLocationQueue._();
  static final OfflineLocationQueue instance = OfflineLocationQueue._();

  Database? _db;

  static const String _dbName = 'offline_location_queue.db';
  static const int _version = 1;

  Future<Database> get _database async {
    if (_db != null && _db!.isOpen) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      join(dbPath, _dbName),
      version: _version,
      singleInstance: true,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE offline_location_queue (
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
            created_at INTEGER DEFAULT (strftime('%s','now'))
          )
        ''');
        await db.execute('CREATE INDEX idx_offline_unsynced ON offline_location_queue(is_synced, recorded_at ASC)');
        await db.execute('PRAGMA journal_mode = WAL');
      },
      onUpgrade: (db, oldV, newV) async {
        await db.execute('PRAGMA journal_mode = WAL');
      },
    );
    await _db!.execute('PRAGMA journal_mode');
    return _db!;
  }

  /// Insert a captured location point (always before attempting upload).
  Future<int> enqueue({
    required double latitude,
    required double longitude,
    double? accuracy,
    double? batteryLevel,
    String? networkStatus,
    String? employeeId,
  }) async {
    final db = await _database;
    return await db.insert('offline_location_queue', {
      'employee_id': employeeId,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'battery_level': batteryLevel,
      'network_status': networkStatus,
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
      'is_synced': 0,
      'attempts': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Select unsynced rows ordered by recorded_at ASC, capped.
  Future<List<Map<String, dynamic>>> getUnsynced({int limit = 200}) async {
    final db = await _database;
    final rows = await db.query(
      'offline_location_queue',
      where: 'is_synced = ?',
      whereArgs: [0],
      orderBy: 'recorded_at ASC',
      limit: limit,
    );
    return rows;
  }

  /// Mark rows as synced (by their DB id).
  Future<void> markSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final batch = db.batch();
    for (final id in ids) {
      batch.update('offline_location_queue', {'is_synced': 1}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Increment attempts for unsynced rows.
  Future<void> incrementAttempts(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final batch = db.batch();
    for (final id in ids) {
      batch.rawUpdate('UPDATE offline_location_queue SET attempts = attempts + 1 WHERE id = ?', [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Purge rows synced longer than 24h (older than now - 24h, is_synced=1).
  Future<int> purgeOldSynced() async {
    final db = await _database;
    final cutoff = DateTime.now().toUtc().subtract(const Duration(hours: 24)).toIso8601String();
    return await db.delete('offline_location_queue',
        where: 'is_synced = ? AND recorded_at < ?', whereArgs: [1, cutoff]);
  }

  /// Cap queue at 2000 rows (drop oldest sync'd first, then oldest unsynced).
  Future<void> capQueue() async {
    final db = await _database;
    // Count total.
    final total = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM offline_location_queue')) ?? 0;
    if (total <= 2000) return;
    // Delete oldest rows (oldest recorded_at first) regardless of sync status.
    await db.rawDelete('DELETE FROM offline_location_queue WHERE id IN (SELECT id FROM offline_location_queue ORDER BY recorded_at ASC LIMIT ?)', [(total - 2000)]);
  }

  /// Count unsynced + count total (for status display).
  Future<(int unsynced, int total)> counts() async {
    final db = await _database;
    final unsynced = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM offline_location_queue WHERE is_synced = 0')) ?? 0;
    final total = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM offline_location_queue')) ?? 0;
    return (unsynced, total);
  }
}
