import 'dart:async';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'debug_logger.dart';
import 'hive_storage_service.dart';

/// Service to keep the app alive and prevent Android from killing it
class KeepAliveService {
  static final KeepAliveService _instance = KeepAliveService._internal();
  static KeepAliveService get instance => _instance;
  KeepAliveService._internal();

  final _logger = DebugLogger.instance;
  static const _keepAliveChannel = MethodChannel('com.example.carsoc/keep_alive');

  bool _isEnabled = false;
  bool _wakelockEnabled = false;
  bool _nativeServiceRunning = false;  // Track native service state
  Timer? _heartbeatTimer;
  DateTime? _lastHeartbeat;

  // Callbacks for when service detects issues
  final List<VoidCallback> _onRestartNeeded = [];

  /// Whether keep-alive is currently active
  bool get isEnabled => _isEnabled;

  /// Whether wakelock is currently held
  bool get isWakelockEnabled => _wakelockEnabled;

  /// Time since last heartbeat
  Duration? get timeSinceLastHeartbeat {
    if (_lastHeartbeat == null) return null;
    return DateTime.now().difference(_lastHeartbeat!);
  }

  /// Initialize the keep-alive service
  Future<void> initialize() async {
    // Load setting from storage
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      _isEnabled = hive.getSetting<bool>('keep_alive_enabled') ?? false;
    }

    if (_isEnabled) {
      await enable();
    }

    _logger.log('[KeepAlive] Initialized, enabled: $_isEnabled');
  }

  /// Enable keep-alive (wakelock + heartbeat monitoring)
  Future<void> enable() async {
    if (_isEnabled && (_wakelockEnabled || _nativeServiceRunning)) return;

    _isEnabled = true;

    // Try Flutter wakelock first
    try {
      await WakelockPlus.enable();
      _wakelockEnabled = await WakelockPlus.enabled;
      _logger.log('[KeepAlive] Wakelock enabled: $_wakelockEnabled');
    } catch (e) {
      _logger.log('[KeepAlive] Flutter wakelock failed: $e');
      _wakelockEnabled = false;
    }

    // If Flutter wakelock failed, use native foreground service (AI box fallback)
    if (!_wakelockEnabled) {
      try {
        await _keepAliveChannel.invokeMethod('startService');
        _nativeServiceRunning = true;
        _logger.log('[KeepAlive] Native foreground service started (fallback)');
      } catch (e) {
        _logger.log('[KeepAlive] Native service also failed: $e');
        _nativeServiceRunning = false;
      }
    }

    // Start heartbeat timer to detect if app is being throttled
    _startHeartbeat();

    // Save setting
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting('keep_alive_enabled', true);
    }

    _logger.log('[KeepAlive] Enabled (wakelock=$_wakelockEnabled, native=$_nativeServiceRunning)');
  }

  /// Disable keep-alive
  Future<void> disable() async {
    _isEnabled = false;

    // Disable wakelock
    try {
      await WakelockPlus.disable();
      _wakelockEnabled = false;
      _logger.log('[KeepAlive] Wakelock disabled');
    } catch (e) {
      _logger.log('[KeepAlive] Failed to disable wakelock: $e');
    }

    // Stop native service if running
    if (_nativeServiceRunning) {
      try {
        await _keepAliveChannel.invokeMethod('stopService');
        _nativeServiceRunning = false;
        _logger.log('[KeepAlive] Native service stopped');
      } catch (e) {
        _logger.log('[KeepAlive] Failed to stop native service: $e');
      }
    }

    // Stop heartbeat
    _stopHeartbeat();

    // Save setting
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting('keep_alive_enabled', false);
    }

    _logger.log('[KeepAlive] Disabled');
  }

  /// Register callback for when restart is needed
  void onRestartNeeded(VoidCallback callback) {
    _onRestartNeeded.add(callback);
  }

  /// Remove restart callback
  void removeRestartCallback(VoidCallback callback) {
    _onRestartNeeded.remove(callback);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastHeartbeat = DateTime.now();

    // Heartbeat every 10 seconds
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      final now = DateTime.now();
      final elapsed = now.difference(_lastHeartbeat!);

      // If more than 30 seconds since last heartbeat, something is wrong
      // This can happen if the system is throttling/killing the app
      if (elapsed.inSeconds > 30) {
        _logger.log('[KeepAlive] WARNING: Heartbeat gap of ${elapsed.inSeconds}s detected!');

        // Re-enable wakelock in case it was released
        _reacquireWakelock();

        // Notify listeners
        for (final callback in _onRestartNeeded) {
          callback();
        }
      }

      _lastHeartbeat = now;

      // Periodically verify wakelock is still held
      _verifyWakelock();
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastHeartbeat = null;
  }

  Future<void> _verifyWakelock() async {
    if (!_isEnabled) return;

    try {
      final enabled = await WakelockPlus.enabled;
      if (!enabled && _wakelockEnabled) {
        _logger.log('[KeepAlive] Wakelock was released, re-acquiring');
        await _reacquireWakelock();
      }
    } catch (e) {
      _logger.log('[KeepAlive] Failed to verify wakelock: $e');
    }
  }

  Future<void> _reacquireWakelock() async {
    // Try Flutter wakelock first
    try {
      await WakelockPlus.enable();
      _wakelockEnabled = await WakelockPlus.enabled;
      _logger.log('[KeepAlive] Wakelock re-acquired: $_wakelockEnabled');
    } catch (e) {
      _logger.log('[KeepAlive] Failed to re-acquire wakelock: $e');
      _wakelockEnabled = false;
    }

    // If wakelock failed, ensure native service is running
    if (!_wakelockEnabled && !_nativeServiceRunning) {
      try {
        await _keepAliveChannel.invokeMethod('startService');
        _nativeServiceRunning = true;
        _logger.log('[KeepAlive] Native service started as fallback');
      } catch (e) {
        _logger.log('[KeepAlive] Native service fallback failed: $e');
      }
    }
  }

  /// Call this when app receives data to prove it's alive
  void pulse() {
    _lastHeartbeat = DateTime.now();
  }

  /// Whether native service is running
  bool get isNativeServiceRunning => _nativeServiceRunning;

  /// Get status info for debugging
  Map<String, dynamic> getStatus() {
    return {
      'enabled': _isEnabled,
      'wakelockHeld': _wakelockEnabled,
      'nativeServiceRunning': _nativeServiceRunning,
      'lastHeartbeat': _lastHeartbeat?.toIso8601String(),
      'timeSinceHeartbeat': timeSinceLastHeartbeat?.inSeconds,
    };
  }

  /// Dispose of resources
  void dispose() {
    _stopHeartbeat();
    _onRestartNeeded.clear();
  }
}
