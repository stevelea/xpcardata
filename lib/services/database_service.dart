import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/vehicle_data.dart';
import '../models/alert.dart';
import '../models/charging_session.dart';

/// Singleton service for SQLite database operations
class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;

  DatabaseService._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('vehicle_data.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 2,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Vehicle data table
    await db.execute('''
      CREATE TABLE vehicle_data (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        stateOfCharge REAL,
        stateOfHealth REAL,
        batteryCapacity REAL,
        batteryVoltage REAL,
        batteryCurrent REAL,
        batteryTemperature REAL,
        range REAL,
        speed REAL,
        odometer REAL,
        power REAL,
        additionalProperties TEXT
      )
    ''');

    // Alerts table
    await db.execute('''
      CREATE TABLE alerts (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        message TEXT NOT NULL,
        severity INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        isRead INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Indexes for better query performance
    await db.execute('''
      CREATE INDEX idx_vehicle_data_timestamp ON vehicle_data(timestamp DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_alerts_timestamp ON alerts(timestamp DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_alerts_unread ON alerts(isRead, timestamp DESC)
    ''');

    // Charging sessions table (version 2)
    await _createChargingSessionsTable(db);
  }

  /// Upgrade database schema
  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createChargingSessionsTable(db);
    }
  }

  /// Create charging sessions table
  Future<void> _createChargingSessionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS charging_sessions (
        id TEXT PRIMARY KEY,
        startTime INTEGER NOT NULL,
        endTime INTEGER,
        startCumulativeCharge REAL NOT NULL,
        endCumulativeCharge REAL,
        startSoc REAL NOT NULL,
        endSoc REAL,
        startOdometer REAL NOT NULL,
        endOdometer REAL,
        isActive INTEGER NOT NULL DEFAULT 0,
        chargingType TEXT,
        maxPowerKw REAL,
        energyAddedKwh REAL,
        distanceSinceLastCharge REAL,
        consumptionKwhPer100km REAL,
        previousSessionOdometer REAL,
        locationName TEXT,
        chargingCost REAL,
        notes TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_charging_sessions_time ON charging_sessions(startTime DESC)
    ''');
  }

  // ==================== Vehicle Data Operations ====================

  /// Insert vehicle data into database
  Future<int> insertVehicleData(VehicleData data) async {
    final db = await database;
    return await db.insert(
      'vehicle_data',
      data.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get vehicle data with optional filters
  Future<List<VehicleData>> getVehicleData({
    DateTime? startTime,
    DateTime? endTime,
    int? limit,
  }) async {
    final db = await database;

    String? where;
    List<dynamic>? whereArgs;

    if (startTime != null && endTime != null) {
      where = 'timestamp BETWEEN ? AND ?';
      whereArgs = [
        startTime.millisecondsSinceEpoch,
        endTime.millisecondsSinceEpoch,
      ];
    }

    final maps = await db.query(
      'vehicle_data',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'timestamp DESC',
      limit: limit,
    );

    return maps.map((map) => VehicleData.fromMap(map)).toList();
  }

  /// Get the most recent vehicle data
  Future<VehicleData?> getLatestVehicleData() async {
    final data = await getVehicleData(limit: 1);
    return data.isNotEmpty ? data.first : null;
  }

  /// Get vehicle data count
  Future<int> getVehicleDataCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM vehicle_data');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ==================== Alert Operations ====================

  /// Insert an alert into database
  Future<void> insertAlert(VehicleAlert alert) async {
    final db = await database;
    await db.insert(
      'alerts',
      alert.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get alerts with optional filter
  Future<List<VehicleAlert>> getAlerts({bool? unreadOnly}) async {
    final db = await database;

    final maps = await db.query(
      'alerts',
      where: unreadOnly == true ? 'isRead = 0' : null,
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => VehicleAlert.fromMap(map)).toList();
  }

  /// Get unread alerts count
  Future<int> getUnreadAlertsCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM alerts WHERE isRead = 0');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Mark an alert as read
  Future<void> markAlertAsRead(String alertId) async {
    final db = await database;
    await db.update(
      'alerts',
      {'isRead': 1},
      where: 'id = ?',
      whereArgs: [alertId],
    );
  }

  /// Mark all alerts as read
  Future<void> markAllAlertsAsRead() async {
    final db = await database;
    await db.update(
      'alerts',
      {'isRead': 1},
      where: 'isRead = 0',
    );
  }

  /// Delete an alert
  Future<void> deleteAlert(String alertId) async {
    final db = await database;
    await db.delete(
      'alerts',
      where: 'id = ?',
      whereArgs: [alertId],
    );
  }

  // ==================== Charging Session Operations ====================

  /// Insert or update a charging session
  Future<void> insertChargingSession(ChargingSession session) async {
    final db = await database;
    await db.insert(
      'charging_sessions',
      session.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all charging sessions with optional limit
  Future<List<ChargingSession>> getChargingSessions({int? limit}) async {
    final db = await database;
    final maps = await db.query(
      'charging_sessions',
      orderBy: 'startTime DESC',
      limit: limit,
    );
    return maps.map((map) => ChargingSession.fromMap(map)).toList();
  }

  /// Get the most recent completed charging session
  Future<ChargingSession?> getLastCompletedSession() async {
    final db = await database;
    final maps = await db.query(
      'charging_sessions',
      where: 'isActive = 0',
      orderBy: 'endTime DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return ChargingSession.fromMap(maps.first);
  }

  /// Get a charging session by ID
  Future<ChargingSession?> getChargingSessionById(String id) async {
    final db = await database;
    final maps = await db.query(
      'charging_sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return ChargingSession.fromMap(maps.first);
  }

  /// Update a charging session (for manual edits)
  Future<void> updateChargingSession(ChargingSession session) async {
    final db = await database;
    await db.update(
      'charging_sessions',
      session.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }

  /// Delete a charging session
  Future<void> deleteChargingSession(String id) async {
    final db = await database;
    await db.delete(
      'charging_sessions',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Get charging sessions count
  Future<int> getChargingSessionsCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM charging_sessions');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Get total energy charged (kWh)
  Future<double> getTotalEnergyCharged() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT SUM(energyAddedKwh) as total FROM charging_sessions WHERE energyAddedKwh IS NOT NULL'
    );
    final value = result.first['total'];
    if (value == null) return 0.0;
    return (value as num).toDouble();
  }

  /// Get average consumption (kWh/100km)
  Future<double?> getAverageConsumption() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT AVG(consumptionKwhPer100km) as avg FROM charging_sessions WHERE consumptionKwhPer100km IS NOT NULL AND consumptionKwhPer100km > 0'
    );
    final value = result.first['avg'];
    if (value == null) return null;
    return (value as num).toDouble();
  }

  /// Clear all charging sessions
  Future<void> clearAllChargingSessions() async {
    final db = await database;
    await db.delete('charging_sessions');
  }

  // ==================== Data Maintenance ====================

  /// Delete old vehicle data older than specified duration
  Future<int> deleteOldData(Duration maxAge) async {
    final db = await database;
    final cutoffTime = DateTime.now().subtract(maxAge);

    return await db.delete(
      'vehicle_data',
      where: 'timestamp < ?',
      whereArgs: [cutoffTime.millisecondsSinceEpoch],
    );
  }

  /// Delete old alerts older than specified duration
  Future<int> deleteOldAlerts(Duration maxAge) async {
    final db = await database;
    final cutoffTime = DateTime.now().subtract(maxAge);

    return await db.delete(
      'alerts',
      where: 'timestamp < ?',
      whereArgs: [cutoffTime.millisecondsSinceEpoch],
    );
  }

  /// Clear all vehicle data
  Future<void> clearAllVehicleData() async {
    final db = await database;
    await db.delete('vehicle_data');
  }

  /// Clear all alerts
  Future<void> clearAllAlerts() async {
    final db = await database;
    await db.delete('alerts');
  }

  /// Get database size in bytes
  Future<int> getDatabaseSize() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'vehicle_data.db');
    final file = await databaseFactory.openDatabase(path);
    await file.close();
    // Note: This is a simplified version. For accurate size, use dart:io File
    return 0; // Placeholder
  }

  /// Close database connection
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
