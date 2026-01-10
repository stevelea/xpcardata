import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Service for tracking data usage across MQTT and ABRP
class DataUsageService {
  static final DataUsageService _instance = DataUsageService._internal();
  static DataUsageService get instance => _instance;

  DataUsageService._internal();

  // Counters for current session
  int _mqttBytesSent = 0;
  int _mqttRequestCount = 0;
  int _abrpBytesSent = 0;
  int _abrpRequestCount = 0;

  // Counters for all-time (persisted)
  int _totalMqttBytesSent = 0;
  int _totalMqttRequestCount = 0;
  int _totalAbrpBytesSent = 0;
  int _totalAbrpRequestCount = 0;

  // Session start time
  DateTime? _sessionStartTime;

  // Stream for real-time updates
  final _usageController = StreamController<DataUsageStats>.broadcast();
  Stream<DataUsageStats> get usageStream => _usageController.stream;

  /// Initialize the service and load persisted data
  Future<void> initialize() async {
    _sessionStartTime = DateTime.now();
    await _loadPersistedData();
  }

  /// Record MQTT data sent
  void recordMqttSent(int bytes) {
    _mqttBytesSent += bytes;
    _mqttRequestCount++;
    _totalMqttBytesSent += bytes;
    _totalMqttRequestCount++;
    _notifyListeners();
    _savePersistedData();
  }

  /// Record ABRP data sent
  void recordAbrpSent(int bytes) {
    _abrpBytesSent += bytes;
    _abrpRequestCount++;
    _totalAbrpBytesSent += bytes;
    _totalAbrpRequestCount++;
    _notifyListeners();
    _savePersistedData();
  }

  /// Get current session stats
  DataUsageStats get sessionStats => DataUsageStats(
        mqttBytesSent: _mqttBytesSent,
        mqttRequestCount: _mqttRequestCount,
        abrpBytesSent: _abrpBytesSent,
        abrpRequestCount: _abrpRequestCount,
        sessionDuration: _sessionStartTime != null
            ? DateTime.now().difference(_sessionStartTime!)
            : Duration.zero,
      );

  /// Get all-time stats
  DataUsageStats get totalStats => DataUsageStats(
        mqttBytesSent: _totalMqttBytesSent,
        mqttRequestCount: _totalMqttRequestCount,
        abrpBytesSent: _totalAbrpBytesSent,
        abrpRequestCount: _totalAbrpRequestCount,
        sessionDuration: Duration.zero,
      );

  /// Reset session counters
  void resetSession() {
    _mqttBytesSent = 0;
    _mqttRequestCount = 0;
    _abrpBytesSent = 0;
    _abrpRequestCount = 0;
    _sessionStartTime = DateTime.now();
    _notifyListeners();
  }

  /// Reset all counters (including persisted)
  Future<void> resetAll() async {
    _mqttBytesSent = 0;
    _mqttRequestCount = 0;
    _abrpBytesSent = 0;
    _abrpRequestCount = 0;
    _totalMqttBytesSent = 0;
    _totalMqttRequestCount = 0;
    _totalAbrpBytesSent = 0;
    _totalAbrpRequestCount = 0;
    _sessionStartTime = DateTime.now();
    _notifyListeners();
    await _savePersistedData();
  }

  void _notifyListeners() {
    _usageController.add(sessionStats);
  }

  Future<String> get _filePath async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      return '${directory.path}/data_usage.json';
    } catch (e) {
      return '/data/data/com.example.carsoc/files/data_usage.json';
    }
  }

  Future<void> _loadPersistedData() async {
    try {
      final file = File(await _filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        _totalMqttBytesSent = data['totalMqttBytesSent'] ?? 0;
        _totalMqttRequestCount = data['totalMqttRequestCount'] ?? 0;
        _totalAbrpBytesSent = data['totalAbrpBytesSent'] ?? 0;
        _totalAbrpRequestCount = data['totalAbrpRequestCount'] ?? 0;
      }
    } catch (e) {
      // Ignore errors, start fresh
    }
  }

  Future<void> _savePersistedData() async {
    try {
      final file = File(await _filePath);
      final data = {
        'totalMqttBytesSent': _totalMqttBytesSent,
        'totalMqttRequestCount': _totalMqttRequestCount,
        'totalAbrpBytesSent': _totalAbrpBytesSent,
        'totalAbrpRequestCount': _totalAbrpRequestCount,
        'lastUpdated': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      // Ignore save errors
    }
  }

  void dispose() {
    _usageController.close();
  }
}

/// Data usage statistics
class DataUsageStats {
  final int mqttBytesSent;
  final int mqttRequestCount;
  final int abrpBytesSent;
  final int abrpRequestCount;
  final Duration sessionDuration;

  DataUsageStats({
    required this.mqttBytesSent,
    required this.mqttRequestCount,
    required this.abrpBytesSent,
    required this.abrpRequestCount,
    required this.sessionDuration,
  });

  int get totalBytesSent => mqttBytesSent + abrpBytesSent;
  int get totalRequestCount => mqttRequestCount + abrpRequestCount;

  /// Format bytes as human readable string
  static String formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  /// Format duration as human readable string
  static String formatDuration(Duration duration) {
    if (duration.inSeconds < 60) {
      return '${duration.inSeconds}s';
    } else if (duration.inMinutes < 60) {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    } else if (duration.inHours < 24) {
      return '${duration.inHours}h ${duration.inMinutes % 60}m';
    } else {
      return '${duration.inDays}d ${duration.inHours % 24}h';
    }
  }
}
