import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'hive_storage_service.dart';
import 'debug_logger.dart';

/// Service for health monitoring via healthchecks.io (hc-ping.com)
/// Sends periodic pings to indicate the app is running and connected
class HealthcheckService {
  static final HealthcheckService _instance = HealthcheckService._internal();
  static HealthcheckService get instance => _instance;
  HealthcheckService._internal();

  final _logger = DebugLogger.instance;
  Timer? _pingTimer;
  String? _pingUrl;
  int _intervalSeconds = 60;
  bool _enabled = false;
  DateTime? _lastPingTime;
  bool _lastPingSuccess = false;

  /// Whether healthcheck is enabled
  bool get isEnabled => _enabled;

  /// The configured ping URL
  String? get pingUrl => _pingUrl;

  /// Ping interval in seconds
  int get intervalSeconds => _intervalSeconds;

  /// Last ping time
  DateTime? get lastPingTime => _lastPingTime;

  /// Whether last ping was successful
  bool get lastPingSuccess => _lastPingSuccess;

  /// Initialize and start healthcheck if enabled
  Future<void> initialize() async {
    await _loadSettings();
    if (_enabled && _pingUrl != null && _pingUrl!.isNotEmpty) {
      start();
    }
  }

  /// Load settings from storage
  Future<void> _loadSettings() async {
    // Try Hive first
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      _enabled = hive.getSetting<bool>('healthcheck_enabled') ?? false;
      _pingUrl = hive.getSetting<String>('healthcheck_url');
      _intervalSeconds = hive.getSetting<int>('healthcheck_interval') ?? 60;
      if (_enabled) {
        _logger.log('[Healthcheck] Settings loaded from Hive');
      }
      return;
    }

    // Fall back to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool('healthcheck_enabled') ?? false;
      _pingUrl = prefs.getString('healthcheck_url');
      _intervalSeconds = prefs.getInt('healthcheck_interval') ?? 60;
      if (_enabled) {
        _logger.log('[Healthcheck] Settings loaded from SharedPreferences');
      }
    } catch (e) {
      _logger.log('[Healthcheck] Failed to load settings: $e');
    }
  }

  /// Configure the healthcheck service
  Future<void> configure({
    required bool enabled,
    String? url,
    int intervalSeconds = 60,
  }) async {
    _enabled = enabled;
    _pingUrl = url;
    _intervalSeconds = intervalSeconds;

    // Save to Hive first
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting('healthcheck_enabled', enabled);
      if (url != null) await hive.saveSetting('healthcheck_url', url);
      await hive.saveSetting('healthcheck_interval', intervalSeconds);
    }

    // Also save to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('healthcheck_enabled', enabled);
      if (url != null) await prefs.setString('healthcheck_url', url);
      await prefs.setInt('healthcheck_interval', intervalSeconds);
    } catch (e) {
      _logger.log('[Healthcheck] Failed to save to SharedPreferences: $e');
    }

    if (enabled && url != null && url.isNotEmpty) {
      start();
    } else {
      stop();
    }
  }

  /// Start periodic health pings
  void start() {
    if (_pingUrl == null || _pingUrl!.isEmpty) {
      _logger.log('[Healthcheck] Cannot start - no URL configured');
      return;
    }

    stop(); // Stop any existing timer

    _logger.log('[Healthcheck] Starting with ${_intervalSeconds}s interval');

    // Send initial ping immediately
    _sendPing();

    // Schedule periodic pings
    _pingTimer = Timer.periodic(
      Duration(seconds: _intervalSeconds),
      (_) => _sendPing(),
    );
  }

  /// Stop periodic health pings
  void stop() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _logger.log('[Healthcheck] Stopped');
  }

  /// Send a ping to healthchecks.io
  Future<bool> _sendPing({String? suffix}) async {
    if (_pingUrl == null || _pingUrl!.isEmpty) return false;

    try {
      final url = suffix != null ? '$_pingUrl/$suffix' : _pingUrl!;
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
      );

      _lastPingTime = DateTime.now();
      _lastPingSuccess = response.statusCode == 200;

      if (_lastPingSuccess) {
        _logger.log('[Healthcheck] Ping successful');
      } else {
        _logger.log('[Healthcheck] Ping failed: ${response.statusCode}');
      }

      return _lastPingSuccess;
    } catch (e) {
      _lastPingTime = DateTime.now();
      _lastPingSuccess = false;
      _logger.log('[Healthcheck] Ping error: $e');
      return false;
    }
  }

  /// Send a start signal (when app starts or OBD connects)
  Future<bool> sendStart() async {
    return _sendPing(suffix: 'start');
  }

  /// Send a success ping (normal heartbeat)
  Future<bool> sendSuccess() async {
    return _sendPing();
  }

  /// Send a fail signal (when something goes wrong)
  Future<bool> sendFail() async {
    return _sendPing(suffix: 'fail');
  }

  /// Send a log message along with ping
  Future<bool> sendLog(String message) async {
    if (_pingUrl == null || _pingUrl!.isEmpty) return false;

    try {
      final response = await http.post(
        Uri.parse('$_pingUrl/log'),
        body: message,
      ).timeout(const Duration(seconds: 10));

      _lastPingTime = DateTime.now();
      _lastPingSuccess = response.statusCode == 200;
      return _lastPingSuccess;
    } catch (e) {
      _logger.log('[Healthcheck] Log send error: $e');
      return false;
    }
  }

  /// Dispose of resources
  void dispose() {
    stop();
  }
}
