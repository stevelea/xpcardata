import 'dart:collection';

/// Simple in-app debug logger for viewing logs without ADB
class DebugLogger {
  static final DebugLogger _instance = DebugLogger._internal();
  factory DebugLogger() => _instance;
  DebugLogger._internal();

  static DebugLogger get instance => _instance;

  final _logs = Queue<String>();
  static const int _maxLogs = 200;

  /// Add a log entry
  void log(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    final logEntry = '[$timestamp] $message';

    print(logEntry); // Still print to console

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
