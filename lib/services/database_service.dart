import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/vehicle_data.dart';
import '../models/alert.dart';
import '../models/charging_session.dart';
import 'debug_logger.dart';

/// Singleton service for SQLite database operations
class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;
  static final _logger = DebugLogger.instance;
  static bool _databaseAvailable = true;
  static bool _initializationAttempted = false;

  DatabaseService._init();

  /// Check if database is available (sqflite plugin works on this device)
  bool get isAvailable => _databaseAvailable;

  Future<Database> get database async {
    if (!_databaseAvailable && _initializationAttempted) {
      throw Exception('Database not available on this device');
    }
    if (_database != null) return _database!;

    // Retry up to 3 times with increasing delays
    const maxRetries = 3;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        _logger.log('[Database] Initialization attempt $attempt of $maxRetries');
        _database = await _initDB('vehicle_data.db');
        _databaseAvailable = true;
        _initializationAttempted = true;
        return _database!;
      } catch (e) {
        _logger.log('[Database] Attempt $attempt failed: $e');
        if (attempt < maxRetries) {
          // Wait before retrying (200ms, 500ms)
          await Future.delayed(Duration(milliseconds: attempt * 200 + 100));
        } else {
          _databaseAvailable = false;
          _initializationAttempted = true;
          rethrow;
        }
      }
    }

    // Should never reach here, but satisfy the compiler
    throw Exception('Database initialization failed after $maxRetries attempts');
  }

  Future<Database> _initDB(String filePath) async {
    // Try multiple paths to find one that works
    final pathsToTry = <String>[];

    // 1. First try: Application documents directory (most reliable on AI boxes)
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      pathsToTry.add(join(documentsDir.path, filePath));
      _logger.log('[Database] Documents path: ${documentsDir.path}');
    } catch (e) {
      _logger.log('[Database] getApplicationDocumentsDirectory failed: $e');
    }

    // 2. Second try: Application support directory
    try {
      final supportDir = await getApplicationSupportDirectory();
      pathsToTry.add(join(supportDir.path, filePath));
      _logger.log('[Database] Support path: ${supportDir.path}');
    } catch (e) {
      _logger.log('[Database] getApplicationSupportDirectory failed: $e');
    }

    // 3. Third try: Default sqflite path
    try {
      final dbPath = await getDatabasesPath();
      pathsToTry.add(join(dbPath, filePath));
      _logger.log('[Database] Default databases path: $dbPath');
    } catch (e) {
      _logger.log('[Database] getDatabasesPath failed: $e');
    }

    // Try each path until one works
    Exception? lastError;
    for (final path in pathsToTry) {
      try {
        _logger.log('[Database] Attempting to open database at: $path');

        // Ensure parent directory exists
        final dbFile = File(path);
        final parentDir = dbFile.parent;
        if (!await parentDir.exists()) {
          _logger.log('[Database] Creating directory: ${parentDir.path}');
          await parentDir.create(recursive: true);
        }

        // Try to open the database
        final db = await openDatabase(
          path,
          version: 2,
          onCreate: _createDB,
          onUpgrade: _upgradeDB,
        );

        _logger.log('[Database] Successfully opened database at: $path');
        return db;
      } catch (e) {
        _logger.log('[Database] Failed to open at $path: $e');
        lastError = e is Exception ? e : Exception(e.toString());
      }
    }

    // If all paths failed, throw the last error
    throw lastError ?? Exception('No valid database path found');
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
    final map = session.toMap();
    // Log the data being inserted for debugging
    _logger.log('[Database] Inserting charging session: id=${session.id}, startSoc=${session.startSoc}, endSoc=${session.endSoc}, energyKwh=${session.energyAddedKwh}');
    await db.insert(
      'charging_sessions',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _logger.log('[Database] Session ${session.id} inserted successfully');
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
    try {
      // Try to find the database file
      final pathsToCheck = <String>[];

      try {
        final documentsDir = await getApplicationDocumentsDirectory();
        pathsToCheck.add(join(documentsDir.path, 'vehicle_data.db'));
      } catch (_) {}

      try {
        final supportDir = await getApplicationSupportDirectory();
        pathsToCheck.add(join(supportDir.path, 'vehicle_data.db'));
      } catch (_) {}

      try {
        final dbPath = await getDatabasesPath();
        pathsToCheck.add(join(dbPath, 'vehicle_data.db'));
      } catch (_) {}

      for (final path in pathsToCheck) {
        final file = File(path);
        if (await file.exists()) {
          return await file.length();
        }
      }
    } catch (e) {
      _logger.log('[Database] Error getting database size: $e');
    }
    return 0;
  }

  /// Close database connection
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
