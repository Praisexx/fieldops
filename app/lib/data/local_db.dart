import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/outbox.dart';

/// SQLite cache + outbox. Server JSON is stored as received so the model layer stays the only parser.
class LocalDb {
  LocalDb._(this._db);
  final Database _db;

  static Future<LocalDb> open(String path, {DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE jobs (id TEXT PRIMARY KEY, json TEXT NOT NULL)');
          await db.execute('CREATE TABLE outbox ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT NOT NULL, type TEXT NOT NULL, '
              'client_id TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL, error TEXT, created_at TEXT NOT NULL)');
          await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
        },
      ),
    );
    return LocalDb._(db);
  }

  Future<void> close() => _db.close();

  // ---- job cache ----
  Future<List<Map<String, dynamic>>> jobs() async {
    final rows = await _db.query('jobs');
    return [for (final r in rows) Map<String, dynamic>.from(jsonDecode(r['json'] as String) as Map)];
  }

  Future<Map<String, dynamic>?> job(String id) async {
    final rows = await _db.query('jobs', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Map<String, dynamic>.from(jsonDecode(rows.first['json'] as String) as Map);
  }

  /// Replaces the whole cache with the server's list, but keeps already-fetched detail for jobs still present.
  Future<void> replaceJobs(List<Map<String, dynamic>> list) => _db.transaction((txn) async {
        final existing = {
          for (final r in await txn.query('jobs')) r['id'] as String: jsonDecode(r['json'] as String) as Map,
        };
        await txn.delete('jobs');
        for (final j in list) {
          final old = existing[j['id']];
          final merged = (old != null && old.containsKey('notes') && old['updatedAt'] == j['updatedAt']) ? {...j, ...old} : j;
          await txn.insert('jobs', {'id': j['id'], 'json': jsonEncode(merged)});
        }
      });

  Future<void> upsertJob(Map<String, dynamic> j) =>
      _db.insert('jobs', {'id': j['id'], 'json': jsonEncode(j)}, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---- outbox ----
  Future<OutboxItem> enqueue({
    required String jobId,
    required OutboxType type,
    required String clientId,
    required Map<String, dynamic> payload,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final id = await _db.insert('outbox', {
      'job_id': jobId,
      'type': type.name,
      'client_id': clientId,
      'payload': jsonEncode(payload),
      'state': OutboxState.pending.name,
      'created_at': now,
    });
    return (await outboxItem(id))!;
  }

  Future<OutboxItem?> outboxItem(int id) async {
    final rows = await _db.query('outbox', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : OutboxItem.fromRow(rows.first);
  }

  Future<List<OutboxItem>> outbox({OutboxState? state}) async {
    final rows = await _db.query('outbox',
        where: state == null ? null : 'state = ?', whereArgs: state == null ? null : [state.name], orderBy: 'id');
    return rows.map(OutboxItem.fromRow).toList();
  }

  Future<void> setOutboxState(int id, OutboxState state, {String? error}) =>
      _db.update('outbox', {'state': state.name, 'error': error}, where: 'id = ?', whereArgs: [id]);

  /// A run that crashed mid-send leaves rows as `syncing`; make them eligible again.
  Future<void> resetSyncing() =>
      _db.update('outbox', {'state': OutboxState.pending.name}, where: 'state = ?', whereArgs: [OutboxState.syncing.name]);

  Future<void> deleteOutbox(int id) => _db.delete('outbox', where: 'id = ?', whereArgs: [id]);

  // ---- meta / lifecycle ----
  Future<String?> meta(String key) async {
    final rows = await _db.query('meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) =>
      _db.insert('meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> clearAll() => _db.transaction((txn) async {
        await txn.delete('jobs');
        await txn.delete('outbox');
        await txn.delete('meta');
      });
}
