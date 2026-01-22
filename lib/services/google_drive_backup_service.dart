import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/charging_session.dart';
import 'github_update_service.dart' show appVersion;
import 'hive_storage_service.dart';
import 'database_service.dart';

/// Service for backing up and restoring app data via file export/import
class BackupService {
  static final BackupService instance = BackupService._();
  BackupService._();

  static const String _backupFileName = 'xpcardata_backup.json';
  static const int _backupVersion = 1;

  String? _error;
  DateTime? _lastBackupTime;

  /// Last error message
  String? get error => _error;

  /// Last backup timestamp
  DateTime? get lastBackupTime => _lastBackupTime;

  /// Initialize service
  Future<void> initialize() async {
    await _loadLastBackupTime();
  }

  /// Export backup to a shareable file and return the file path
  Future<String?> exportBackup() async {
    _error = null;
    try {
      debugPrint('[Backup] Creating backup...');

      // Collect all data
      final settings = await _collectSettings();
      final sessions = await _collectChargingSessions();

      final backup = {
        'version': _backupVersion,
        'created_at': DateTime.now().toIso8601String(),
        'app_version': appVersion,
        'settings': settings,
        'charging_sessions': sessions,
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(backup);

      // Save to temp file
      String filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/$_backupFileName';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/$_backupFileName';
      }

      final file = File(filePath);
      await file.writeAsString(jsonString);

      debugPrint('[Backup] Backup file created: $filePath');
      debugPrint('[Backup] Settings count: ${settings.length}');
      debugPrint('[Backup] Sessions count: ${sessions.length}');

      // Save last backup time
      _lastBackupTime = DateTime.now();
      await _saveLastBackupTime();

      return filePath;
    } catch (e) {
      _error = 'Export failed: $e';
      debugPrint('[Backup] Export error: $e');
      return null;
    }
  }

  /// Export backup and save to Downloads folder
  /// Returns the file path on success, null on failure
  Future<String?> saveBackupToDownloads() async {
    _error = null;
    try {
      debugPrint('[Backup] Creating backup for Downloads...');

      // Collect all data
      final settings = await _collectSettings();
      final sessions = await _collectChargingSessions();

      final backup = {
        'version': _backupVersion,
        'created_at': DateTime.now().toIso8601String(),
        'app_version': appVersion,
        'settings': settings,
        'charging_sessions': sessions,
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(backup);

      // Try multiple paths for Downloads folder
      String? savedPath;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'xpcardata_backup_$timestamp.json';

      // Try common Android download paths
      final downloadPaths = [
        '/storage/emulated/0/Download',
        '/sdcard/Download',
        '/storage/emulated/0/Downloads',
        '/sdcard/Downloads',
      ];

      for (final downloadDir in downloadPaths) {
        try {
          final dir = Directory(downloadDir);
          if (await dir.exists()) {
            final filePath = '$downloadDir/$fileName';
            final file = File(filePath);
            await file.writeAsString(jsonString);
            savedPath = filePath;
            debugPrint('[Backup] Saved to: $savedPath');
            break;
          }
        } catch (e) {
          debugPrint('[Backup] Failed to save to $downloadDir: $e');
        }
      }

      // Fallback to app internal storage if Downloads not accessible
      if (savedPath == null) {
        final internalPath = '/data/data/com.example.carsoc/files/$fileName';
        try {
          final file = File(internalPath);
          await file.writeAsString(jsonString);
          savedPath = internalPath;
          debugPrint('[Backup] Saved to internal: $savedPath');
        } catch (e) {
          debugPrint('[Backup] Internal save failed: $e');
        }
      }

      if (savedPath != null) {
        _lastBackupTime = DateTime.now();
        await _saveLastBackupTime();
        debugPrint('[Backup] Settings count: ${settings.length}');
        debugPrint('[Backup] Sessions count: ${sessions.length}');
        return savedPath;
      }

      _error = 'Could not save backup file';
      return null;
    } catch (e) {
      _error = 'Export failed: $e';
      debugPrint('[Backup] Export error: $e');
      return null;
    }
  }

  /// Copy backup JSON to clipboard
  Future<bool> copyBackupToClipboard() async {
    _error = null;
    try {
      debugPrint('[Backup] Creating backup for clipboard...');

      final settings = await _collectSettings();
      final sessions = await _collectChargingSessions();

      final backup = {
        'version': _backupVersion,
        'created_at': DateTime.now().toIso8601String(),
        'app_version': appVersion,
        'settings': settings,
        'charging_sessions': sessions,
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(backup);

      await Clipboard.setData(ClipboardData(text: jsonString));

      _lastBackupTime = DateTime.now();
      await _saveLastBackupTime();

      debugPrint('[Backup] Copied to clipboard (${jsonString.length} bytes)');
      debugPrint('[Backup] Settings count: ${settings.length}');
      debugPrint('[Backup] Sessions count: ${sessions.length}');

      return true;
    } catch (e) {
      _error = 'Copy failed: $e';
      debugPrint('[Backup] Clipboard error: $e');
      return false;
    }
  }

  /// Restore from a backup file path
  Future<bool> restoreFromFile(String filePath) async {
    _error = null;
    try {
      debugPrint('[Backup] Restoring from: $filePath');

      final file = File(filePath);
      if (!await file.exists()) {
        _error = 'Backup file not found';
        return false;
      }

      final jsonString = await file.readAsString();
      return await restoreFromJson(jsonString);
    } catch (e) {
      _error = 'Restore failed: $e';
      debugPrint('[Backup] Restore error: $e');
      return false;
    }
  }

  /// Restore from JSON string (for clipboard paste or file content)
  Future<bool> restoreFromJson(String jsonString) async {
    _error = null;
    try {
      final backup = jsonDecode(jsonString) as Map<String, dynamic>;

      // Validate backup
      if (!backup.containsKey('version') || !backup.containsKey('settings')) {
        _error = 'Invalid backup file format';
        return false;
      }

      final version = backup['version'] as int;
      if (version > _backupVersion) {
        _error = 'Backup version too new (v$version). Please update the app.';
        return false;
      }

      debugPrint('[Backup] Restoring backup version $version');

      // Restore settings
      final settings = backup['settings'] as Map<String, dynamic>?;
      if (settings != null) {
        await _restoreSettings(settings);
      }

      // Restore charging sessions
      final sessions = backup['charging_sessions'] as List<dynamic>?;
      if (sessions != null && sessions.isNotEmpty) {
        await _restoreChargingSessions(sessions);
      }

      debugPrint('[Backup] Restore completed successfully');
      return true;
    } catch (e) {
      _error = 'Invalid JSON: $e';
      debugPrint('[Backup] Restore error: $e');
      return false;
    }
  }

  /// Load last backup timestamp from local storage
  Future<void> _loadLastBackupTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timeString = prefs.getString('last_backup_time');
      if (timeString != null) {
        _lastBackupTime = DateTime.tryParse(timeString);
      }
    } catch (e) {
      debugPrint('[Backup] Failed to load last backup time: $e');
    }
  }

  /// Save last backup timestamp to local storage
  Future<void> _saveLastBackupTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_lastBackupTime != null) {
        await prefs.setString('last_backup_time', _lastBackupTime!.toIso8601String());
      }
    } catch (e) {
      debugPrint('[Backup] Failed to save backup time: $e');
    }
  }

  /// Collect settings from Hive, SharedPreferences and file storage
  Future<Map<String, dynamic>> _collectSettings() async {
    final settings = <String, dynamic>{};

    // Try Hive first (most reliable on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      try {
        final hiveSettings = hive.getAllSettings();
        for (final entry in hiveSettings.entries) {
          settings[entry.key] = entry.value;
        }
        debugPrint('[Backup] Collected ${hiveSettings.length} settings from Hive');
      } catch (e) {
        debugPrint('[Backup] Failed to read Hive settings: $e');
      }
    }

    // Also get from SharedPreferences (may have additional settings)
    try {
      final prefs = await SharedPreferences.getInstance();

      // MQTT Settings
      settings['mqtt_broker'] = prefs.getString('mqtt_broker');
      settings['mqtt_port'] = prefs.getInt('mqtt_port');
      settings['mqtt_username'] = prefs.getString('mqtt_username');
      settings['mqtt_password'] = prefs.getString('mqtt_password');
      settings['mqtt_vehicle_id'] = prefs.getString('mqtt_vehicle_id');
      settings['mqtt_use_tls'] = prefs.getBool('mqtt_use_tls');
      settings['mqtt_enabled'] = prefs.getBool('mqtt_enabled');
      settings['ha_discovery_enabled'] = prefs.getBool('ha_discovery_enabled');
      settings['mqtt_reconnect_interval'] = prefs.getInt('mqtt_reconnect_interval');

      // ABRP Settings
      settings['abrp_token'] = prefs.getString('abrp_token');
      settings['abrp_car_model'] = prefs.getString('abrp_car_model');
      settings['abrp_enabled'] = prefs.getBool('abrp_enabled');
      settings['abrp_interval_seconds'] = prefs.getInt('abrp_interval_seconds');

      // Alert Thresholds
      settings['alert_low_battery'] = prefs.getDouble('alert_low_battery');
      settings['alert_critical_battery'] = prefs.getDouble('alert_critical_battery');
      settings['alert_high_temp'] = prefs.getDouble('alert_high_temp');

      // App Behavior
      settings['data_retention_days'] = prefs.getInt('data_retention_days');
      settings['update_frequency_seconds'] = prefs.getInt('update_frequency_seconds');
      settings['start_minimised'] = prefs.getBool('start_minimised');
      settings['stay_in_background'] = prefs.getBool('stay_in_background');
      settings['keep_alive_enabled'] = prefs.getBool('keep_alive_enabled');
      settings['background_service_enabled'] = prefs.getBool('background_service_enabled');

      // Vehicle & Location
      settings['vehicle_model'] = prefs.getString('vehicle_model');
      settings['tailscale_auto_connect'] = prefs.getBool('tailscale_auto_connect');
      settings['location_enabled'] = prefs.getBool('location_enabled');
      settings['left_hand_drive'] = prefs.getBool('left_hand_drive');

      // Home Location
      settings['home_latitude'] = prefs.getDouble('home_latitude');
      settings['home_longitude'] = prefs.getDouble('home_longitude');
      settings['home_location_name'] = prefs.getString('home_location_name');

      // Fleet Analytics
      settings['fleet_analytics_enabled'] = prefs.getBool('fleet_analytics_enabled');
      settings['fleet_analytics_consent'] = prefs.getBool('fleet_analytics_consent');

      // Theme
      settings['app_theme'] = prefs.getString('app_theme');

      // GitHub Token (for updates)
      settings['github_token'] = prefs.getString('github_token');
    } catch (e) {
      debugPrint('[Backup] Failed to read SharedPreferences: $e');
    }

    // Also try file-based settings as fallback
    try {
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/app_settings.json';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/app_settings.json';
      }

      final file = File(filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final fileSettings = jsonDecode(content) as Map<String, dynamic>;

        // Merge file settings (only if not already set from prefs)
        for (final entry in fileSettings.entries) {
          settings[entry.key] ??= entry.value;
        }
      }
    } catch (e) {
      debugPrint('[Backup] Failed to read file settings: $e');
    }

    // Remove null values
    settings.removeWhere((key, value) => value == null);

    return settings;
  }

  /// Collect charging sessions from all storage sources
  Future<List<Map<String, dynamic>>> _collectChargingSessions() async {
    final sessions = <Map<String, dynamic>>[];
    final hive = HiveStorageService.instance;
    final db = DatabaseService.instance;

    try {
      // Try Hive first (best for AI boxes)
      if (hive.isAvailable) {
        try {
          final hiveSessions = await hive.getChargingSessions();
          if (hiveSessions.isNotEmpty) {
            for (final session in hiveSessions) {
              sessions.add(session.toJson());
            }
            debugPrint('[Backup] Collected ${sessions.length} sessions from Hive');
            return sessions;
          }
        } catch (e) {
          debugPrint('[Backup] Hive collection failed: $e');
        }
      }

      // Try SQLite database
      if (db.isAvailable) {
        try {
          final dbSessions = await db.getChargingSessions();
          if (dbSessions.isNotEmpty) {
            for (final session in dbSessions) {
              sessions.add(session.toJson());
            }
            debugPrint('[Backup] Collected ${sessions.length} sessions from SQLite');
            return sessions;
          }
        } catch (e) {
          debugPrint('[Backup] SQLite collection failed: $e');
        }
      }

      // Try SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        final jsonString = prefs.getString('charging_sessions');
        if (jsonString != null && jsonString.isNotEmpty) {
          final jsonList = jsonDecode(jsonString) as List;
          for (final json in jsonList) {
            final session = ChargingSession.fromMap(Map<String, dynamic>.from(json));
            sessions.add(session.toJson());
          }
          debugPrint('[Backup] Collected ${sessions.length} sessions from SharedPreferences');
          return sessions;
        }
      } catch (e) {
        debugPrint('[Backup] SharedPreferences collection failed: $e');
      }

      // Try file storage
      try {
        String? filePath;
        try {
          final directory = await getApplicationDocumentsDirectory();
          filePath = '${directory.path}/charging_sessions.json';
        } catch (e) {
          filePath = '/data/data/com.example.carsoc/files/charging_sessions.json';
        }

        final file = File(filePath);
        if (await file.exists()) {
          final content = await file.readAsString();
          final jsonList = jsonDecode(content) as List;
          for (final json in jsonList) {
            final session = ChargingSession.fromMap(Map<String, dynamic>.from(json));
            sessions.add(session.toJson());
          }
          debugPrint('[Backup] Collected ${sessions.length} sessions from file');
        }
      } catch (e) {
        debugPrint('[Backup] File collection failed: $e');
      }

      debugPrint('[Backup] Collected ${sessions.length} charging sessions total');
    } catch (e) {
      debugPrint('[Backup] Failed to collect charging sessions: $e');
    }

    return sessions;
  }

  /// Restore settings to Hive, SharedPreferences and file
  Future<void> _restoreSettings(Map<String, dynamic> settings) async {
    debugPrint('[Backup] Restoring ${settings.length} settings');

    // Save to Hive first (most reliable on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      try {
        await hive.saveAllSettings(settings);
        debugPrint('[Backup] Settings restored to Hive');
      } catch (e) {
        debugPrint('[Backup] Failed to restore to Hive: $e');
      }
    }

    // Also save to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();

      for (final entry in settings.entries) {
        final key = entry.key;
        final value = entry.value;

        if (value == null) continue;

        if (value is String) {
          await prefs.setString(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is bool) {
          await prefs.setBool(key, value);
        }
      }
      debugPrint('[Backup] Settings restored to SharedPreferences');
    } catch (e) {
      debugPrint('[Backup] Failed to restore to SharedPreferences: $e');
    }

    // Also save to file for AI box compatibility
    try {
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/app_settings.json';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/app_settings.json';
      }

      final file = File(filePath);
      await file.writeAsString(jsonEncode(settings));
      debugPrint('[Backup] Settings saved to file: $filePath');
    } catch (e) {
      debugPrint('[Backup] Failed to save settings to file: $e');
    }
  }

  /// Restore charging sessions to all available storage
  Future<void> _restoreChargingSessions(List<dynamic> sessionsJson) async {
    debugPrint('[Backup] Restoring ${sessionsJson.length} charging sessions');

    final sessions = <ChargingSession>[];
    for (final json in sessionsJson) {
      try {
        final session = ChargingSession.fromJson(json as Map<String, dynamic>);
        sessions.add(session);
      } catch (e) {
        debugPrint('[Backup] Failed to parse session: $e');
      }
    }

    if (sessions.isEmpty) {
      debugPrint('[Backup] No valid sessions to restore');
      return;
    }

    final hive = HiveStorageService.instance;
    final db = DatabaseService.instance;

    // Try Hive first (best for AI boxes)
    if (hive.isAvailable) {
      try {
        for (final session in sessions) {
          await hive.saveChargingSession(session);
        }
        debugPrint('[Backup] Restored ${sessions.length} sessions to Hive');
      } catch (e) {
        debugPrint('[Backup] Hive restore failed: $e');
      }
    }

    // Also try SQLite database
    if (db.isAvailable) {
      try {
        for (final session in sessions) {
          await db.insertChargingSession(session);
        }
        debugPrint('[Backup] Restored ${sessions.length} sessions to SQLite');
      } catch (e) {
        debugPrint('[Backup] SQLite restore failed: $e');
      }
    }

    // Also save to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = sessions.map((s) => s.toMap()).toList();
      await prefs.setString('charging_sessions', jsonEncode(jsonList));
      debugPrint('[Backup] Restored ${sessions.length} sessions to SharedPreferences');
    } catch (e) {
      debugPrint('[Backup] SharedPreferences restore failed: $e');
    }

    // Also save to file for AI box compatibility
    try {
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/charging_sessions.json';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/charging_sessions.json';
      }

      final file = File(filePath);
      final jsonList = sessions.map((s) => s.toMap()).toList();
      await file.writeAsString(jsonEncode(jsonList));
      debugPrint('[Backup] Restored ${sessions.length} sessions to file: $filePath');
    } catch (e) {
      debugPrint('[Backup] File restore failed: $e');
    }

    debugPrint('[Backup] Charging sessions restored');
  }
}
