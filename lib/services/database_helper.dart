import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/basemap.dart';
import '../models/waypoint.dart';

/// Helper Singleton untuk mengelola database SQLite `mmaps.db`.
class DatabaseHelper {
  static const String _dbName = 'mmaps.db';
  static const int _dbVersion = 3;
  static const String _tableWaypoints = 'waypoints';
  static const String _tableCustomBasemaps = 'custom_basemaps';

  // Singleton instance
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

  Database? _database;

  /// Mengembalikan instance database (membuat jika belum ada).
  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Membuat skema tabel saat pertama kali database dibuat.
  Future<void> _onCreate(Database db, int version) async {
    await _createWaypointsTable(db);
    await _createCustomBasemapsTable(db);
  }

  Future<void> _createWaypointsTable(Database db) async {
    await db.execute('''
      CREATE TABLE $_tableWaypoints (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        description TEXT NOT NULL,
        latitude    REAL NOT NULL,
        longitude   REAL NOT NULL,
        photoPaths  TEXT,
        createdAt   TEXT NOT NULL
      )
    ''');
  }

  /// Logika migrasi saat versi database dinaikkan.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Karena data lama mungkin tidak terlalu penting di tahap pengembangan,
      // cara paling mudah adalah menghapus tabel lama dan membuat yang baru.
      await db.execute('DROP TABLE IF EXISTS $_tableWaypoints');
      await _createWaypointsTable(db);

      // Catatan: Jika Anda ingin mempertahankan data lama (hanya menambah kolom),
      // gunakan kode ini sebagai gantinya:
      // await db.execute('ALTER TABLE $_tableWaypoints ADD COLUMN photoPaths TEXT');
    }
    if (oldVersion < 3) {
      await _createCustomBasemapsTable(db);
    }
  }

  Future<void> _createCustomBasemapsTable(Database db) async {
    await db.execute('''
      CREATE TABLE $_tableCustomBasemaps (
        id     TEXT PRIMARY KEY,
        name   TEXT NOT NULL,
        xyzUrl TEXT NOT NULL
      )
    ''');
  }

  // ---------------------------------------------------------------------------
  // CRUD Operations
  // ---------------------------------------------------------------------------

  Future<int> insertWaypoint(Waypoint waypoint) async {
    final db = await database;
    return db.insert(
      _tableWaypoints,
      waypoint.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Waypoint>> getAllWaypoints() async {
    final db = await database;
    final maps = await db.query(_tableWaypoints, orderBy: 'createdAt DESC');
    return maps.map(Waypoint.fromMap).toList();
  }

  Future<Waypoint?> getWaypointById(String id) async {
    final db = await database;
    final maps = await db.query(
      _tableWaypoints,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Waypoint.fromMap(maps.first);
  }

  Future<int> updateWaypoint(Waypoint waypoint) async {
    final db = await database;
    return db.update(
      _tableWaypoints,
      waypoint.toMap(),
      where: 'id = ?',
      whereArgs: [waypoint.id],
    );
  }

  Future<int> deleteWaypoint(String id) async {
    final db = await database;
    return db.delete(_tableWaypoints, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Basemap>> getCustomBasemaps() async {
    final db = await database;
    final rows = await db.query(_tableCustomBasemaps, orderBy: 'rowid ASC');
    return rows.map(Basemap.fromMap).toList();
  }

  Future<void> saveCustomBasemap(Basemap basemap) async {
    if (!basemap.isCustom) {
      throw ArgumentError.value(basemap, 'basemap', 'Must be a custom basemap');
    }
    final db = await database;
    await db.insert(
      _tableCustomBasemaps,
      basemap.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
