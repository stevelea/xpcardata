import 'dart:async';
import 'dart:io';
import 'tailscale_service.dart';
import 'mqtt_service.dart';
import 'debug_logger.dart';
import 'hive_storage_service.dart';

/// Service that monitors and maintains network connectivity
/// - Periodically checks Tailscale VPN and reconnects if disconnected
/// - Monitors MQTT connection and triggers reconnection if needed
class ConnectivityWatchdogService {
  static final ConnectivityWatchdogService _instance =
      ConnectivityWatchdogService._internal();
  static ConnectivityWatchdogService get instance => _instance;

  ConnectivityWatchdogService._internal();

  final _logger = DebugLogger.instance;
  final _tailscale = TailscaleService.instance;

  // Watchdog timer
  Timer? _watchdogTimer;
  bool _isRunning = false;

  // Configuration
  static const Duration _defaultCheckInterval = Duration(seconds: 60);
  Duration _checkInterval = _defaultCheckInterval;

  // Settings
  bool _tailscaleAutoReconnect = false;
  bool _mqttEnabled = false;

  // MQTT service reference (set externally to avoid circular dependency)
  MqttService? _mqttService;

  // Stats
  int _tailscaleReconnectAttempts = 0;
  int _mqttReconnectAttempts = 0;
  DateTime? _lastCheck;
  DateTime? _lastTailscaleReconnect;
  DateTime? _lastMqttReconnect;

  // Getters
  bool get isRunning => _isRunning;
  Duration get checkInterval => _checkInterval;
  int get tailscaleReconnectAttempts => _tailscaleReconnectAttempts;
  int get mqttReconnectAttempts => _mqttReconnectAttempts;
  DateTime? get lastCheck => _lastCheck;

  /// Set the MQTT service reference
  void setMqttService(MqttService service) {
    _mqttService = service;
  }

  /// Initialize the watchdog service
  Future<void> initialize() async {
    _logger.log('[Watchdog] Initializing connectivity watchdog...');

    // Load settings
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      _tailscaleAutoReconnect =
          hive.getSetting<bool>('tailscale_auto_reconnect') ?? false;
      _mqttEnabled = hive.getSetting<bool>('mqtt_enabled') ?? false;

      final intervalSeconds =
          hive.getSetting<int>('watchdog_interval_seconds') ?? 60;
      _checkInterval = Duration(seconds: intervalSeconds);
    }

    _logger.log(
        '[Watchdog] Settings: tailscaleAutoReconnect=$_tailscaleAutoReconnect, mqttEnabled=$_mqttEnabled, interval=${_checkInterval.inSeconds}s');
  }

  /// Start the watchdog timer
  void start() {
    if (_isRunning) {
      _logger.log('[Watchdog] Already running');
      return;
    }

    _logger.log('[Watchdog] Starting with ${_checkInterval.inSeconds}s interval');
    _isRunning = true;

    // Run immediately
    _runCheck();

    // Then run periodically
    _watchdogTimer = Timer.periodic(_checkInterval, (_) => _runCheck());
  }

  /// Stop the watchdog timer
  void stop() {
    _logger.log('[Watchdog] Stopping');
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _isRunning = false;
  }

  /// Update settings and restart if needed
  void updateSettings({
    bool? tailscaleAutoReconnect,
    bool? mqttEnabled,
    int? intervalSeconds,
  }) {
    bool needsRestart = false;

    if (tailscaleAutoReconnect != null) {
      _tailscaleAutoReconnect = tailscaleAutoReconnect;
    }

    if (mqttEnabled != null) {
      _mqttEnabled = mqttEnabled;
    }

    if (intervalSeconds != null) {
      final newInterval = Duration(seconds: intervalSeconds);
      if (newInterval != _checkInterval) {
        _checkInterval = newInterval;
        needsRestart = true;
      }
    }

    // Save settings
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      hive.saveSetting('tailscale_auto_reconnect', _tailscaleAutoReconnect);
      hive.saveSetting('watchdog_interval_seconds', _checkInterval.inSeconds);
    }

    _logger.log(
        '[Watchdog] Settings updated: tailscale=$_tailscaleAutoReconnect, mqtt=$_mqttEnabled, interval=${_checkInterval.inSeconds}s');

    if (needsRestart && _isRunning) {
      stop();
      start();
    }
  }

  /// Run a connectivity check
  Future<void> _runCheck() async {
    _lastCheck = DateTime.now();
    _logger.log('[Watchdog] Running connectivity check...');

    try {
      // Check Tailscale (only on Android)
      if (Platform.isAndroid && _tailscaleAutoReconnect) {
        await _checkTailscale();
      }

      // Check MQTT - always check if we have a service reference
      if (_mqttService != null) {
        await _checkMqtt();
      } else {
        _logger.log('[Watchdog] MQTT service not set');
      }
    } catch (e) {
      _logger.log('[Watchdog] Check error: $e');
    }
  }

  /// Check Tailscale VPN and reconnect if needed
  Future<void> _checkTailscale() async {
    try {
      final isVpnActive = await _tailscale.checkVpnStatus();

      if (!isVpnActive) {
        _logger.log('[Watchdog] Tailscale VPN not active, attempting reconnect...');
        _tailscaleReconnectAttempts++;
        _lastTailscaleReconnect = DateTime.now();

        // Use connectWithRetry for more reliable connection
        final success = await _tailscale.connectWithRetry(maxAttempts: 2);

        if (success) {
          _logger.log('[Watchdog] Tailscale reconnected successfully');
        } else {
          _logger.log('[Watchdog] Tailscale reconnect failed');
        }
      }
    } catch (e) {
      _logger.log('[Watchdog] Tailscale check error: $e');
    }
  }

  /// Check MQTT connection and trigger reconnect if needed
  Future<void> _checkMqtt() async {
    if (_mqttService == null) return;

    try {
      final isConnected = _mqttService!.isConnected;
      _logger.log('[Watchdog] MQTT check: connected=$isConnected');

      if (!isConnected) {
        _logger.log('[Watchdog] MQTT not connected, triggering reconnect...');
        _mqttReconnectAttempts++;
        _lastMqttReconnect = DateTime.now();

        // Directly trigger reconnection attempt
        await _mqttService!.reconnect();

        // Also ensure periodic reconnect is enabled as backup
        if (_mqttService!.periodicReconnectInterval == 0) {
          _mqttService!.periodicReconnectInterval = 30;
          _logger.log('[Watchdog] Enabled MQTT periodic reconnect (30s)');
        }
      }
    } catch (e) {
      _logger.log('[Watchdog] MQTT check error: $e');
    }
  }

  /// Force an immediate check
  Future<void> forceCheck() async {
    _logger.log('[Watchdog] Forced check requested');
    await _runCheck();
  }

  /// Get status summary
  Map<String, dynamic> getStatus() {
    return {
      'isRunning': _isRunning,
      'checkInterval': _checkInterval.inSeconds,
      'tailscaleAutoReconnect': _tailscaleAutoReconnect,
      'mqttEnabled': _mqttEnabled,
      'tailscaleReconnectAttempts': _tailscaleReconnectAttempts,
      'mqttReconnectAttempts': _mqttReconnectAttempts,
      'lastCheck': _lastCheck?.toIso8601String(),
      'lastTailscaleReconnect': _lastTailscaleReconnect?.toIso8601String(),
      'lastMqttReconnect': _lastMqttReconnect?.toIso8601String(),
    };
  }

  /// Dispose resources
  void dispose() {
    stop();
  }
}
