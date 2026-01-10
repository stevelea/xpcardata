import 'dart:async';
import 'package:flutter/services.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'dart:io';
import 'debug_logger.dart';

/// Service for controlling Tailscale VPN via Android intents
///
/// Uses broadcast intents to connect/disconnect Tailscale:
/// - Connect: com.tailscale.ipn.CONNECT_VPN
/// - Disconnect: com.tailscale.ipn.DISCONNECT_VPN
///
/// Note: Tailscale app must be installed and configured for these intents to work.
/// The user must have previously logged in and set up Tailscale manually.
class TailscaleService {
  static final TailscaleService _instance = TailscaleService._internal();
  static TailscaleService get instance => _instance;

  final _logger = DebugLogger.instance;

  static const String _tailscalePackage = 'com.tailscale.ipn';
  static const String _tailscaleReceiver = 'com.tailscale.ipn.IPNReceiver';
  static const String _connectAction = 'com.tailscale.ipn.CONNECT_VPN';
  static const String _disconnectAction = 'com.tailscale.ipn.DISCONNECT_VPN';

  static const _platform = MethodChannel('com.example.carsoc/vpn_status');

  // Cached VPN status
  bool _isVpnActive = false;
  DateTime? _lastCheck;
  Timer? _statusTimer;

  /// Stream controller for VPN status changes
  final _statusController = StreamController<bool>.broadcast();

  /// Stream of VPN status changes
  Stream<bool> get statusStream => _statusController.stream;

  /// Current VPN active status
  bool get isVpnActive => _isVpnActive;

  TailscaleService._internal();

  /// Check if Tailscale is installed on the device
  Future<bool> isInstalled() async {
    if (!Platform.isAndroid) {
      _logger.log('[Tailscale] Not Android platform');
      return false;
    }

    try {
      // Try to query the package manager for Tailscale
      const platform = MethodChannel('com.example.carsoc/package_manager');
      final result = await platform.invokeMethod<bool>(
        'isPackageInstalled',
        {'packageName': _tailscalePackage},
      );
      _logger.log('[Tailscale] Installation check: $result');
      return result ?? false;
    } catch (e) {
      // If method channel fails, try alternative approach
      _logger.log('[Tailscale] Method channel check failed: $e');
      // Assume installed if we can't check - let the intent fail gracefully
      return true;
    }
  }

  /// Connect to Tailscale VPN
  ///
  /// Sends a broadcast intent to start the VPN connection.
  /// Note: Tailscale app must be open/running in background for this to work reliably.
  Future<bool> connect() async {
    if (!Platform.isAndroid) {
      _logger.log('[Tailscale] Connect: Not Android platform');
      return false;
    }

    try {
      _logger.log('[Tailscale] Sending CONNECT_VPN intent');

      final intent = AndroidIntent(
        action: _connectAction,
        package: _tailscalePackage,
        componentName: _tailscaleReceiver,
      );

      await intent.sendBroadcast();

      _logger.log('[Tailscale] CONNECT_VPN intent sent successfully');
      return true;
    } catch (e) {
      _logger.log('[Tailscale] Connect failed: $e');
      return false;
    }
  }

  /// Disconnect from Tailscale VPN
  ///
  /// Sends a broadcast intent to stop the VPN connection.
  Future<bool> disconnect() async {
    if (!Platform.isAndroid) {
      _logger.log('[Tailscale] Disconnect: Not Android platform');
      return false;
    }

    try {
      _logger.log('[Tailscale] Sending DISCONNECT_VPN intent');

      final intent = AndroidIntent(
        action: _disconnectAction,
        package: _tailscalePackage,
        componentName: _tailscaleReceiver,
      );

      await intent.sendBroadcast();

      _logger.log('[Tailscale] DISCONNECT_VPN intent sent successfully');
      return true;
    } catch (e) {
      _logger.log('[Tailscale] Disconnect failed: $e');
      return false;
    }
  }

  /// Open Tailscale app
  ///
  /// Launches the Tailscale app so the user can see the connection status
  /// or perform manual configuration.
  Future<bool> openApp() async {
    if (!Platform.isAndroid) {
      _logger.log('[Tailscale] Open app: Not Android platform');
      return false;
    }

    try {
      _logger.log('[Tailscale] Opening Tailscale app');

      // Use launch app intent with category LAUNCHER to open the main activity
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        category: 'android.intent.category.LAUNCHER',
        package: _tailscalePackage,
        componentName: 'com.tailscale.ipn.MainActivity',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );

      await intent.launch();

      _logger.log('[Tailscale] App launch intent sent');
      return true;
    } catch (e) {
      _logger.log('[Tailscale] Failed to open app: $e');
      return false;
    }
  }

  /// Check if any VPN is currently active using Android's ConnectivityManager
  /// Note: This detects any VPN, not specifically Tailscale
  Future<bool> checkVpnStatus() async {
    if (!Platform.isAndroid) {
      _logger.log('[Tailscale] VPN check: Not Android platform');
      return false;
    }

    try {
      final result = await _platform.invokeMethod<bool>('isVpnActive');
      final isActive = result ?? false;

      // Update cached status and notify listeners if changed
      if (_isVpnActive != isActive) {
        _isVpnActive = isActive;
        _statusController.add(isActive);
        _logger.log('[Tailscale] VPN status changed: ${isActive ? "ACTIVE" : "INACTIVE"}');
      }

      _lastCheck = DateTime.now();
      return isActive;
    } catch (e) {
      _logger.log('[Tailscale] VPN status check failed: $e');
      return false;
    }
  }

  /// Start periodic VPN status monitoring
  void startStatusMonitoring({Duration interval = const Duration(seconds: 10)}) {
    stopStatusMonitoring();
    _logger.log('[Tailscale] Starting VPN status monitoring (interval: ${interval.inSeconds}s)');

    // Check immediately
    checkVpnStatus();

    // Then check periodically
    _statusTimer = Timer.periodic(interval, (_) => checkVpnStatus());
  }

  /// Stop periodic VPN status monitoring
  void stopStatusMonitoring() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  /// Dispose resources
  void dispose() {
    stopStatusMonitoring();
    _statusController.close();
  }
}
