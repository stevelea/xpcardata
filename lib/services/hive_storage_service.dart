import 'dart:io';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import '../models/charging_session.dart';
import 'debug_logger.dart';

/// Hive-based storage service for charging sessions
/// Hive is a lightweight NoSQL database that works on all platforms
/// without relying on native SQLite - better compatibility with AI boxes
class HiveStorageService {
  static final HiveStorageService instance = HiveStorageService._init();
  static final _logger = DebugLogger.instance;

  static const String _chargingSessionsBox = 'charging_sessions';
  static const String _settingsBox = 'settings';

  bool _initialized = false;
  bool _available = true;

  HiveStorageService._init();

  /// Check if Hive storage is available
  bool get isAvailable => _available && _initialized;

  /// Initialize Hive storage
  /// Should be called once at app startup
  Future<bool> initialize() async {
    if (_initialized) return _available;

    try {
      _logger.log('[Hive] Initializing Hive storage...');

      // Try to get the Hive storage path
      String? hivePath = await _getHivePath();

      if (hivePath == null) {
        _logger.log('[Hive] No valid path found');
        _available = false;
        _initialized = true;
        return false;
      }

      _logger.log('[Hive] Using path: $hivePath');

      // Initialize Hive with the path we found
      Hive.init(hivePath);

      // Open the boxes we need
      await Hive.openBox<Map>(_chargingSessionsBox);
      await Hive.openBox(_settingsBox);

      _initialized = true;
      _available = true;
      _logger.log('[Hive] Storage initialized successfully');
      return true;
    } catch (e) {
      _logger.log('[Hive] Initialization failed: $e');
      _available = false;
      _initialized = true; // Mark as attempted
      return false;
    }
  }

  /// Get a valid path for Hive storage
  /// Tries multiple methods, including hardcoded fallback for AI boxes
  Future<String?> _getHivePath() async {
    // 1. Try path_provider first (works on normal Android devices)
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final hivePath = '${appDocDir.path}/hive';
      final dir = Directory(hivePath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _logger.log('[Hive] path_provider succeeded: $hivePath');
      return hivePath;
    } catch (e) {
      _logger.log('[Hive] path_provider failed: $e');
    }

    // 2. Try hardcoded internal app storage (works on AI boxes)
    // This is the same path that OBDService uses successfully
    final hardcodedPaths = [
      '/data/data/com.example.carsoc/files/hive',
      '/data/data/com.stevelea.carsoc/files/hive',
      '/data/user/0/com.example.carsoc/files/hive',
      '/data/user/0/com.stevelea.carsoc/files/hive',
    ];

    for (final path in hardcodedPaths) {
      try {
        final dir = Directory(path);
        final parentDir = dir.parent;

        // Check if parent exists (the app's files directory)
        if (await parentDir.exists()) {
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          _logger.log('[Hive] Hardcoded path succeeded: $path');
          return path;
        }
      } catch (e) {
        _logger.log('[Hive] Hardcoded path failed ($path): $e');
      }
    }

    // 3. Try to find any existing app data directory
    try {
      // Look for common app data locations
      final possibleBases = [
        '/data/data',
        '/data/user/0',
      ];

      for (final base in possibleBases) {
        final baseDir = Directory(base);
        if (await baseDir.exists()) {
          await for (final entity in baseDir.list()) {
            if (entity is Directory && entity.path.contains('carsoc')) {
              final hivePath = '${entity.path}/files/hive';
              try {
                final hiveDir = Directory(hivePath);
                final filesDir = Directory('${entity.path}/files');
                if (await filesDir.exists()) {
                  if (!await hiveDir.exists()) {
                    await hiveDir.create(recursive: true);
                  }
                  _logger.log('[Hive] Found app directory: $hivePath');
                  return hivePath;
                }
              } catch (e) {
                _logger.log('[Hive] Could not use ${entity.path}: $e');
              }
            }
          }
        }
      }
    } catch (e) {
      _logger.log('[Hive] Directory scan failed: $e');
    }

    return null;
  }

  // ==================== Charging Session Operations ====================

  /// Save a charging session
  Future<void> saveChargingSession(ChargingSession session) async {
    if (!isAvailable) {
      _logger.log('[Hive] Storage not available, cannot save session');
      return;
    }

    try {
      final box = Hive.box<Map>(_chargingSessionsBox);
      await box.put(session.id, session.toMap());
      _logger.log('[Hive] Session ${session.id} saved successfully');
    } catch (e) {
      _logger.log('[Hive] Failed to save session: $e');
    }
  }

  /// Get all charging sessions
  Future<List<ChargingSession>> getChargingSessions({int? limit}) async {
    if (!isAvailable) {
      _logger.log('[Hive] Storage not available, returning empty list');
      return [];
    }

    try {
      final box = Hive.box<Map>(_chargingSessionsBox);
      final sessions = box.values
          .map((map) => ChargingSession.fromMap(_deepConvertMap(map)))
          .toList();

      // Sort by start time descending (most recent first)
      sessions.sort((a, b) => b.startTime.compareTo(a.startTime));

      if (limit != null && sessions.length > limit) {
        return sessions.take(limit).toList();
      }
      return sessions;
    } catch (e) {
      _logger.log('[Hive] Failed to get sessions: $e');
      return [];
    }
  }

  /// Recursively convert a map with dynamic keys/values to Map<String, dynamic>
  /// Hive stores nested maps as _Map<dynamic, dynamic> which causes cast errors
  Map<String, dynamic> _deepConvertMap(Map map) {
    return map.map((key, value) {
      final stringKey = key.toString();
      if (value is Map) {
        return MapEntry(stringKey, _deepConvertMap(value));
      } else if (value is List) {
        return MapEntry(stringKey, _deepConvertList(value));
      } else {
        return MapEntry(stringKey, value);
      }
    });
  }

  /// Recursively convert list items that may contain maps
  List _deepConvertList(List list) {
    return list.map((item) {
      if (item is Map) {
        return _deepConvertMap(item);
      } else if (item is List) {
        return _deepConvertList(item);
      } else {
        return item;
      }
    }).toList();
  }

  /// Get the last completed charging session
  Future<ChargingSession?> getLastCompletedSession() async {
    if (!isAvailable) return null;

    try {
      final sessions = await getChargingSessions();
      return sessions
          .where((s) => !s.isActive && s.endOdometer != null)
          .firstOrNull;
    } catch (e) {
      _logger.log('[Hive] Failed to get last completed session: $e');
      return null;
    }
  }

  /// Get a charging session by ID
  Future<ChargingSession?> getChargingSessionById(String id) async {
    if (!isAvailable) return null;

    try {
      final box = Hive.box<Map>(_chargingSessionsBox);
      final map = box.get(id);
      if (map == null) return null;
      return ChargingSession.fromMap(_deepConvertMap(map));
    } catch (e) {
      _logger.log('[Hive] Failed to get session by ID: $e');
      return null;
    }
  }

  /// Delete a charging session
  Future<void> deleteChargingSession(String id) async {
    if (!isAvailable) return;

    try {
      final box = Hive.box<Map>(_chargingSessionsBox);
      await box.delete(id);
      _logger.log('[Hive] Session $id deleted');
    } catch (e) {
      _logger.log('[Hive] Failed to delete session: $e');
    }
  }

  /// Get charging sessions count
  Future<int> getChargingSessionsCount() async {
    if (!isAvailable) return 0;

    try {
      final box = Hive.box<Map>(_chargingSessionsBox);
      return box.length;
    } catch (e) {
      _logger.log('[Hive] Failed to get sessions count: $e');
      return 0;
    }
  }

  /// Get total energy charged (kWh)
  Future<double> getTotalEnergyCharged() async {
    if (!isAvailable) return 0.0;

    try {
      final sessions = await getChargingSessions();
      double total = 0.0;
      for (final s in sessions) {
        if (s.energyAddedKwh != null) {
          total += s.energyAddedKwh!;
        }
      }
      return total;
    } catch (e) {
      _logger.log('[Hive] Failed to get total energy: $e');
      return 0.0;
    }
  }

  /// Get average consumption (kWh/100km)
  Future<double?> getAverageConsumption() async {
    if (!isAvailable) return null;

    try {
      final sessions = await getChargingSessions();
      final validSessions = sessions
          .where((s) => s.consumptionKwhPer100km != null && s.consumptionKwhPer100km! > 0)
          .toList();

      if (validSessions.isEmpty) return null;

      final sum = validSessions.fold(0.0, (sum, s) => sum + s.consumptionKwhPer100km!);
      return sum / validSessions.length;
    } catch (e) {
      _logger.log('[Hive] Failed to get average consumption: $e');
      return null;
    }
  }

  /// Clear all charging sessions
  Future<void> clearAllChargingSessions() async {
    if (!isAvailable) return;

    try {
      final box = Hive.box<Map>(_chargingSessionsBox);
      await box.clear();
      _logger.log('[Hive] All charging sessions cleared');
    } catch (e) {
      _logger.log('[Hive] Failed to clear sessions: $e');
    }
  }

  // ==================== Settings Operations ====================

  /// Save a setting value
  Future<void> saveSetting(String key, dynamic value) async {
    if (!isAvailable) return;

    try {
      final box = Hive.box(_settingsBox);
      await box.put(key, value);
    } catch (e) {
      _logger.log('[Hive] Failed to save setting $key: $e');
    }
  }

  /// Get a setting value
  T? getSetting<T>(String key, {T? defaultValue}) {
    if (!isAvailable) return defaultValue;

    try {
      final box = Hive.box(_settingsBox);
      return box.get(key, defaultValue: defaultValue) as T?;
    } catch (e) {
      _logger.log('[Hive] Failed to get setting $key: $e');
      return defaultValue;
    }
  }

  /// Delete a setting
  Future<void> deleteSetting(String key) async {
    if (!isAvailable) return;

    try {
      final box = Hive.box(_settingsBox);
      await box.delete(key);
    } catch (e) {
      _logger.log('[Hive] Failed to delete setting $key: $e');
    }
  }

  /// Get all settings as a map
  Map<String, dynamic> getAllSettings() {
    if (!isAvailable) return {};

    try {
      final box = Hive.box(_settingsBox);
      final settings = <String, dynamic>{};
      for (final key in box.keys) {
        if (key is String) {
          settings[key] = box.get(key);
        }
      }
      return settings;
    } catch (e) {
      _logger.log('[Hive] Failed to get all settings: $e');
      return {};
    }
  }

  /// Save multiple settings at once
  Future<void> saveAllSettings(Map<String, dynamic> settings) async {
    if (!isAvailable) return;

    try {
      final box = Hive.box(_settingsBox);
      for (final entry in settings.entries) {
        if (entry.value != null) {
          await box.put(entry.key, entry.value);
        }
      }
      _logger.log('[Hive] Saved ${settings.length} settings');
    } catch (e) {
      _logger.log('[Hive] Failed to save all settings: $e');
    }
  }

  // ==================== Maintenance ====================

  /// Close all Hive boxes
  Future<void> close() async {
    try {
      await Hive.close();
      _initialized = false;
      _logger.log('[Hive] Storage closed');
    } catch (e) {
      _logger.log('[Hive] Failed to close storage: $e');
    }
  }

  /// Get estimated storage size in bytes
  Future<int> getStorageSize() async {
    // Hive doesn't expose file size directly
    // Return count * estimated average size
    final count = await getChargingSessionsCount();
    return count * 500; // Rough estimate: ~500 bytes per session
  }
}
