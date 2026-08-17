import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:latlong2/latlong.dart';

import '../models/gps_data.dart';

class DatabaseHelper {
  DatabaseHelper._privateConstructor();

  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();

  static Database? _database;

  // ---------------------------------------------------------------------------
  // LIVE ANIMAL PERSISTENCE
  // ---------------------------------------------------------------------------
  // Single entry point called by LivestockWebSocketService for every
  // incoming animal packet. Writes both the "current snapshot" row
  // (dashboard) and an append-only historical row (dashboard_history).
  //
  // geofence_id is intentionally nullable here: the websocket service has
  // no access to GeofenceController (it's per-screen state, not a
  // singleton), so it can't attach a real geofence at write time. If you
  // later want history rows tied to a specific fence, that association
  // needs to happen elsewhere (e.g. when the fence is saved) rather than
  // here.

  Future<void> recordLiveAnimalUpdate(GpsData animal) async {
    final timestamp = animal.timestamp.toString();

    await updateDashboard(
      animalId: animal.deviceId,
      latitude: animal.latitude,
      longitude: animal.longitude,
      status: '-',
      battery: animal.battery,
      timestamp: timestamp,
      geofenceId: null,
    );

    await insertDashboardHistory(
      animalId: animal.deviceId,
      latitude: animal.latitude,
      longitude: animal.longitude,
      status: '-',
      battery: animal.battery,
      timestamp: timestamp,
      geofenceId: null,
    );
  }

  Future<void> updateDashboard({
    required String animalId,
    required double latitude,
    required double longitude,
    required String status,
    required double battery,
    required String timestamp,
    int? geofenceId,
  }) async {
    final db = await database;

    final data = {
      "Animal_ID": animalId,
      "Latitude": latitude,
      "Longitude": longitude,
      "Geofence_Status": status,
      "Timestamp": timestamp,
      "Battery": battery,
      "geofence_id": geofenceId,
    };

    final rows = await db.update(
      "dashboard",
      data,
      where: "Animal_ID = ?",
      whereArgs: [animalId],
    );

    if (rows == 0) {
      await db.insert("dashboard", data);
    }
  }

  Future<void> insertDashboardHistory({
    required String animalId,
    required double latitude,
    required double longitude,
    required String status,
    required double battery,
    required String timestamp,
    int? geofenceId,
  }) async {
    final db = await database;

    await db.insert("dashboard_history", {
      "Animal_ID": animalId,
      "Latitude": latitude,
      "Longitude": longitude,
      "Geofence_Status": status,
      "Battery": battery,
      "Timestamp": timestamp,
      "geofence_id": geofenceId,
    });
  }

  Future<Map<String, Object?>?> getGeofence() async {
    final db = await database;

    final result = await db.query('geofence', limit: 1);

    if (result.isEmpty) {
      return null;
    }

    return result.first;
  }

  Future<List<LatLng>> getGeofencePoints(int geofenceId) async {
    final db = await database;

    final result = await db.query(
      'geofence_points',
      where: 'geofence_id = ?',
      whereArgs: [geofenceId],
      orderBy: 'point_order ASC',
    );

    return result.map((row) {
      return LatLng(row['latitude'] as double, row['longitude'] as double);
    }).toList();
  }

  Future<void> deleteAllGeofences() async {
    final db = await database;

    // Delete points first because they reference geofence
    await db.delete('geofence_points');

    // Then delete the geofence
    await db.delete('geofence');
  }

  Future<int> insertGeofence({
    required String name,
    required List<LatLng> points,
  }) async {
    final db = await database;
    await deleteAllGeofences();

    // Insert the geofence
    int geofenceId = await db.insert('geofence', {'name': name});

    // Insert each point
    for (int i = 0; i < points.length; i++) {
      await db.insert('geofence_points', {
        'geofence_id': geofenceId,
        'latitude': points[i].latitude,
        'longitude': points[i].longitude,
        'point_order': i,
      });
    }

    return geofenceId;
  }

  Future<void> insertLog(
    String type,
    String message,
    DateTime timestamp,
  ) async {
    final db = await database;
    await db.insert('logs', {
      'type': type,
      'message': message,
      'timestamp': timestamp.toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> getLogs() async {
    final db = await database;
    return await db.query('logs', orderBy: 'timestamp DESC');
  }

  Future<List<Map<String, Object?>>> getDashboard() async {
    final db = await database;

    return await db.query("dashboard", orderBy: "Timestamp DESC");
  }

  Future<List<Map<String, Object?>>> getDashboardLast15Days() async {
    final db = await database;

    return await db.query(
      "dashboard_history",
      where: "Timestamp >= datetime('now','-15 day')",
      orderBy: "Timestamp DESC",
    );
  }

  Future<List<Map<String, Object?>>> getDashboardLast30Days() async {
    final db = await database;

    return await db.query(
      "dashboard_history",
      where: "Timestamp >= datetime('now','-30 day')",
      orderBy: "Timestamp DESC",
    );
  }

  Future<List<Map<String, Object?>>> getDashboardHistory() async {
    final db = await database;

    return await db.query("dashboard_history", orderBy: "Timestamp DESC");
  }

  Future<Database> get database async {
    if (_database != null) return _database!;

    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'livestock.db');

    return await openDatabase(
      path,
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE geofence (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE geofence_points (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        geofence_id INTEGER NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        point_order INTEGER NOT NULL,
        FOREIGN KEY (geofence_id) REFERENCES geofence(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE dashboard (
        Animal_ID TEXT PRIMARY KEY,
        Latitude REAL NOT NULL,
        Longitude REAL NOT NULL,
        Geofence_Status TEXT NOT NULL DEFAULT '-',
        Timestamp TEXT NOT NULL,
        Battery REAL NOT NULL,
        geofence_id INTEGER,
        FOREIGN KEY (geofence_id) REFERENCES geofence(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE dashboard_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        Animal_ID TEXT NOT NULL,
        Latitude REAL NOT NULL,
        Longitude REAL NOT NULL,
        Geofence_Status TEXT NOT NULL DEFAULT '-',
        Timestamp TEXT NOT NULL,
        Battery REAL NOT NULL,
        geofence_id INTEGER,
        FOREIGN KEY (geofence_id) REFERENCES geofence(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        message TEXT NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE logs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type TEXT NOT NULL,
          message TEXT NOT NULL,
          timestamp TEXT NOT NULL
        )
      ''');
    }

    if (oldVersion < 3) {
      // dashboard/dashboard_history previously had geofence_id NOT NULL
      // and Battery as INTEGER. Neither was ever actually populated (no
      // code wrote to these tables), so this drop+recreate is safe — it
      // does not remove any real data, only fixes the schema.
      await db.execute('DROP TABLE IF EXISTS dashboard');
      await db.execute('DROP TABLE IF EXISTS dashboard_history');

      await db.execute('''
        CREATE TABLE dashboard (
          Animal_ID TEXT PRIMARY KEY,
          Latitude REAL NOT NULL,
          Longitude REAL NOT NULL,
          Geofence_Status TEXT NOT NULL DEFAULT '-',
          Timestamp TEXT NOT NULL,
          Battery REAL NOT NULL,
          geofence_id INTEGER,
          FOREIGN KEY (geofence_id) REFERENCES geofence(id)
        )
      ''');

      await db.execute('''
        CREATE TABLE dashboard_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          Animal_ID TEXT NOT NULL,
          Latitude REAL NOT NULL,
          Longitude REAL NOT NULL,
          Geofence_Status TEXT NOT NULL DEFAULT '-',
          Timestamp TEXT NOT NULL,
          Battery REAL NOT NULL,
          geofence_id INTEGER,
          FOREIGN KEY (geofence_id) REFERENCES geofence(id)
        )
      ''');
    }
  }

  Future<void> clearDashboardHistory() async {
    final db = await database;
    await db.delete("dashboard_history");
  }

  Future<void> clearLogs() async {
    final db = await database;
    await db.delete("logs");
  }
}
