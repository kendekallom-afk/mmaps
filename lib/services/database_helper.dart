import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/waypoint.dart';

/// Helper Singleton untuk mengelola database SQLite `mmaps.db`.
class DatabaseHelper {
  static const String _dbName = 'mmaps.db';
  static const int _dbVersion = 1;
  static const String _tableWaypoints = 'waypoints';

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
    await db.execute('''
      CREATE TABLE $_tableWaypoints (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        description TEXT NOT NULL,
        latitude    REAL NOT NULL,
        longitude   REAL NOT NULL,
        photoPath   TEXT,
        createdAt   TEXT NOT NULL
      )
    ''');
  }

  /// Placeholder untuk migrasi skema di versi mendatang.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Tambahkan migrasi di sini jika _dbVersion dinaikkan.
  }

  // ---------------------------------------------------------------------------
  // CRUD Operations
  // ---------------------------------------------------------------------------

  /// Menyimpan [waypoint] baru ke database.
  /// Mengembalikan jumlah baris yang berhasil dimasukkan (biasanya 1).
  Future<int> insertWaypoint(Waypoint waypoint) async {
    final db = await database;
    return db.insert(
      _tableWaypoints,
      waypoint.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Mengambil semua waypoint, diurutkan dari yang terbaru.
  Future<List<Waypoint>> getAllWaypoints() async {
    final db = await database;
    final maps = await db.query(
      _tableWaypoints,
      orderBy: 'createdAt DESC',
    );
    return maps.map(Waypoint.fromMap).toList();
  }

  /// Mengambil satu waypoint berdasarkan [id]-nya.
  /// Mengembalikan `null` jika tidak ditemukan.
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

  /// Memperbarui data [waypoint] yang sudah ada.
  /// Mengembalikan jumlah baris yang terpengaruh.
  Future<int> updateWaypoint(Waypoint waypoint) async {
    final db = await database;
    return db.update(
      _tableWaypoints,
      waypoint.toMap(),
      where: 'id = ?',
      whereArgs: [waypoint.id],
    );
  }

  /// Menghapus waypoint berdasarkan [id]-nya.
  /// Mengembalikan jumlah baris yang terhapus.
  Future<int> deleteWaypoint(String id) async {
    final db = await database;
    return db.delete(
      _tableWaypoints,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Menutup koneksi database. Umumnya tidak perlu dipanggil manual.
  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
