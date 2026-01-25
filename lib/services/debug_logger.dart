import 'dart:collection';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simple in-app debug logger for viewing logs without ADB
/// Also sends breadcrumbs to Firebase Crashlytics for crash debugging
class DebugLogger {
  static final DebugLogger _instance = DebugLogger._internal();
  factory DebugLogger() => _instance;
  DebugLogger._internal();

  static DebugLogger get instance => _instance;

  final _logs = Queue<String>();
  static const int _maxLogs = 1000;

  bool _enabled = true;
  static const String _enabledKey = 'debug_logger_enabled';

  /// Whether debug logging is enabled
  bool get isEnabled => _enabled;

  /// Initialize logger settings from preferences
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? true;
  }

  /// Enable or disable debug logging
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  /// Add a log entry (also sends to Crashlytics as breadcrumb)
  void log(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    final logEntry = '[$timestamp] $message';

    // Always print to console
    print(logEntry);

    // Always send to Crashlytics as breadcrumb (for crash debugging)
    try {
      FirebaseCrashlytics.instance.log(message);
    } catch (_) {
      // Crashlytics not initialized yet - ignore
    }

    // Only store locally if enabled
    if (!_enabled) return;

    _logs.add(logEntry);
    if (_logs.length > _maxLogs) {
      _logs.removeFirst();
    }
  }

  /// Get all logs
  List<String> getLogs() => _logs.toList();

  /// Clear all logs
  void clear() => _logs.clear();

  /// Get logs as formatted string
  String getLogsAsString() => _logs.join('\n');
}
