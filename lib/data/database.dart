import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

class GopsDatabase {
  GopsDatabase._();
  static final GopsDatabase instance = GopsDatabase._();

  final _storage = const FlutterSecureStorage();
  Database? _database;

  Future<bool> get isInitialized async =>
      await _storage.read(key: 'gops_db_key') != null;

  Future<void> reset() async {
    final directory = await getApplicationDocumentsDirectory();
    final databasePath = p.join(directory.path, 'gops.sqlite');
    final openDatabase = _database;
    _database = null;
    if (openDatabase != null) await openDatabase.close();
    await deleteDatabase(databasePath);
    for (final suffix in ['-wal', '-shm']) {
      final file = File('$databasePath$suffix');
      if (await file.exists()) await file.delete();
    }
    final photos = Directory(p.join(directory.path, 'gops_photos'));
    if (await photos.exists()) await photos.delete(recursive: true);
    await _storage.delete(key: 'gops_db_key');
  }

  Future<void> initialize() async {
    if (await isInitialized) return;
    final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    await _storage.write(key: 'gops_db_key', value: base64UrlEncode(key));
  }

  Future<Database> get db async {
    if (_database != null) return _database!;
    final key = await _storage.read(key: 'gops_db_key');
    if (key == null) throw StateError('Base locale non initialisée.');
    final directory = await getApplicationDocumentsDirectory();
    final database = await openDatabase(
      p.join(directory.path, 'gops.sqlite'),
      password: key,
      version: 1,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''CREATE TABLE interventions (
          id TEXT PRIMARY KEY, reference TEXT NOT NULL, date TEXT NOT NULL,
          time TEXT NOT NULL, location TEXT NOT NULL DEFAULT '', nature TEXT NOT NULL DEFAULT '',
          report TEXT NOT NULL DEFAULT '', observations TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE identities (
          id TEXT PRIMARY KEY, intervention_id TEXT NOT NULL REFERENCES interventions(id) ON DELETE CASCADE,
          surname TEXT NOT NULL DEFAULT '', usage_name TEXT NOT NULL DEFAULT '', first_names TEXT NOT NULL DEFAULT '',
          birth_date TEXT NOT NULL DEFAULT '', birth_place TEXT NOT NULL DEFAULT '', nationality TEXT NOT NULL DEFAULT '',
          address TEXT NOT NULL DEFAULT '', postal_code TEXT NOT NULL DEFAULT '', city TEXT NOT NULL DEFAULT '',
          phone TEXT NOT NULL DEFAULT '', email TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT 'Autre',
          observations TEXT NOT NULL DEFAULT '')''');
        await db.execute('''CREATE TABLE vehicles (
          id TEXT PRIMARY KEY, intervention_id TEXT NOT NULL REFERENCES interventions(id) ON DELETE CASCADE,
          registration TEXT NOT NULL DEFAULT '', make TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '',
          color TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT '', country TEXT NOT NULL DEFAULT '',
          observations TEXT NOT NULL DEFAULT '')''');
        await db.execute('''CREATE TABLE vehicle_identities (
          vehicle_id TEXT NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
          identity_id TEXT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
          PRIMARY KEY(vehicle_id, identity_id))''');
        await db.execute('''CREATE TABLE photos (
          id TEXT PRIMARY KEY, intervention_id TEXT NOT NULL REFERENCES interventions(id) ON DELETE CASCADE,
          identity_id TEXT REFERENCES identities(id) ON DELETE CASCADE,
          vehicle_id TEXT REFERENCES vehicles(id) ON DELETE CASCADE,
          local_path TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
          category TEXT NOT NULL, created_at TEXT NOT NULL)''');
        await db.execute(
          'CREATE INDEX idx_interventions_date ON interventions(date)',
        );
        await db.execute(
          'CREATE INDEX idx_identity_intervention ON identities(intervention_id)',
        );
        await db.execute(
          'CREATE INDEX idx_vehicle_intervention ON vehicles(intervention_id)',
        );
      },
    );
    _database = database;
    return database;
  }

  Future<List<Map<String, Object?>>> interventions({String query = ''}) async {
    final database = await db;
    final q = '%${query.trim()}%';
    return database.rawQuery(
      '''SELECT i.*,
      (SELECT COUNT(*) FROM identities x WHERE x.intervention_id=i.id) AS identity_count,
      (SELECT COUNT(*) FROM vehicles v WHERE v.intervention_id=i.id) AS vehicle_count,
      (SELECT COUNT(*) FROM photos p WHERE p.intervention_id=i.id) AS photo_count
      FROM interventions i WHERE i.date LIKE ?
      OR (substr(i.date, 9, 2) || '/' || substr(i.date, 6, 2) || '/' || substr(i.date, 1, 4)) LIKE ?
      OR i.time LIKE ?
      OR i.location LIKE ? OR i.nature LIKE ? OR i.observations LIKE ? OR i.report LIKE ?
      ORDER BY i.date DESC, i.time DESC''',
      [q, q, q, q, q, q, q],
    );
  }

  Future<Map<String, Object?>?> intervention(String id) async {
    final rows = await (await db).query(
      'interventions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveIntervention(Map<String, Object?> values) async {
    final database = await db;
    final id = values['id']! as String;
    await database.transaction((txn) async {
      final updated = await txn.update(
        'interventions',
        values,
        where: 'id = ?',
        whereArgs: [id],
      );
      if (updated == 0) {
        await txn.insert('interventions', values);
      }
    });
  }

  Future<void> deleteIntervention(String id) async {
    final database = await db;
    await database.transaction((txn) async {
      final photos = await txn.query(
        'photos',
        columns: ['local_path'],
        where: 'intervention_id = ?',
        whereArgs: [id],
      );
      await txn.delete('interventions', where: 'id = ?', whereArgs: [id]);
      for (final photo in photos) {
        final file = File(photo['local_path']! as String);
        if (await file.exists()) await file.delete();
      }
    });
  }

  Future<List<Map<String, Object?>>> rows(
    String table,
    String interventionId,
  ) async => (await db).query(
    table,
    where: 'intervention_id = ?',
    whereArgs: [interventionId],
  );

  Future<void> saveRow(String table, Map<String, Object?> values) async =>
      (await db).insert(
        table,
        values,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<Set<String>> vehicleIdentityIds(String vehicleId) async {
    final rows = await (await db).query(
      'vehicle_identities',
      where: 'vehicle_id = ?',
      whereArgs: [vehicleId],
    );
    return rows.map((row) => row['identity_id']! as String).toSet();
  }

  Future<void> replaceVehicleIdentityLinks(
    String vehicleId,
    Set<String> identityIds,
  ) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete(
        'vehicle_identities',
        where: 'vehicle_id = ?',
        whereArgs: [vehicleId],
      );
      for (final identityId in identityIds) {
        await txn.insert('vehicle_identities', {
          'vehicle_id': vehicleId,
          'identity_id': identityId,
        });
      }
    });
  }

  Future<void> deleteRow(String table, String id) async =>
      (await db).delete(table, where: 'id = ?', whereArgs: [id]);

  Future<List<Map<String, Object?>>> photos(String interventionId) async =>
      (await db).query(
        'photos',
        where: 'intervention_id = ?',
        whereArgs: [interventionId],
        orderBy: 'created_at DESC',
      );

  Future<void> updatePhotoDescription(String id, String description) async =>
      (await db).update(
        'photos',
        {'description': description},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<int> storageBytes() async {
    final directory = await getApplicationDocumentsDirectory();
    var total = 0;
    await for (final entity in Directory(
      directory.path,
    ).list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }
}
