import 'dart:async';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'debug_logger.dart';

/// Background service for continuous data collection
class BackgroundServiceManager {
  static final BackgroundServiceManager _instance = BackgroundServiceManager._internal();
  static BackgroundServiceManager get instance => _instance;
  BackgroundServiceManager._internal();

  final _logger = DebugLogger.instance;
  bool _isInitialized = false;
  bool _initializationFailed = false;

  static const String notificationChannelId = 'xpcardata_foreground';
  static const String notificationChannelName = 'XPCarData Background Service';
  static const int notificationId = 888;

  // Status notification (works without background service)
  static const String statusChannelId = 'xpcardata_status';
  static const String statusChannelName = 'XPCarData Status';
  static const int statusNotificationId = 889;

  FlutterLocalNotificationsPlugin? _notificationsPlugin;
  bool _statusNotificationEnabled = false;

  /// Initialize the background service
  Future<void> initialize() async {
    try {
      final service = FlutterBackgroundService();

      // Create notification channel for Android
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        notificationChannelId,
        notificationChannelName,
        description: 'XPCarData is collecting vehicle data in the background',
        importance: Importance.low,
      );

      final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
          FlutterLocalNotificationsPlugin();

      try {
        await flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(channel);
      } catch (e) {
        _logger.log('[BackgroundService] Notification channel creation failed: $e');
      }

      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          autoStart: false, // Will be controlled by user setting
          isForegroundMode: true,
          notificationChannelId: notificationChannelId,
          initialNotificationTitle: 'XPCarData',
          initialNotificationContent: 'Collecting vehicle data...',
          foregroundServiceNotificationId: notificationId,
          foregroundServiceTypes: [
            AndroidForegroundType.connectedDevice,
            AndroidForegroundType.remoteMessaging,
          ],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: onStart,
          onBackground: onIosBackground,
        ),
      );

      _isInitialized = true;
      _initializationFailed = false;
      _logger.log('[BackgroundService] Initialized');
    } catch (e) {
      _logger.log('[BackgroundService] Initialization failed: $e');
      _logger.log('[BackgroundService] Background service will be disabled');
      _isInitialized = false;
      _initializationFailed = true;
    }
  }

  /// Check if background service is available
  bool get isAvailable => _isInitialized && !_initializationFailed;

  /// Ensure service is initialized before use
  Future<void> _ensureInitialized() async {
    if (!_isInitialized && !_initializationFailed) {
      await initialize();
    }
  }

  /// Start the background service
  Future<bool> start() async {
    try {
      await _ensureInitialized();

      // If initialization failed, don't try to start
      if (_initializationFailed) {
        _logger.log('[BackgroundService] Cannot start - initialization failed');
        throw Exception('Background service not available on this device');
      }

      final service = FlutterBackgroundService();
      final running = await service.isRunning();

      if (!running) {
        final started = await service.startService();
        _logger.log('[BackgroundService] Started: $started');
        return started;
      }

      _logger.log('[BackgroundService] Already running');
      return true;
    } catch (e) {
      _logger.log('[BackgroundService] Start failed: $e');
      rethrow;
    }
  }

  /// Stop the background service
  Future<void> stop() async {
    if (_initializationFailed) {
      return; // Nothing to stop
    }

    try {
      final service = FlutterBackgroundService();
      service.invoke('stop');
      _logger.log('[BackgroundService] Stopped');
    } catch (e) {
      _logger.log('[BackgroundService] Stop failed: $e');
    }
  }

  /// Check if service is running
  Future<bool> isRunning() async {
    if (_initializationFailed) {
      return false;
    }

    try {
      await _ensureInitialized();
      final service = FlutterBackgroundService();
      return await service.isRunning();
    } catch (e) {
      _logger.log('[BackgroundService] isRunning check failed: $e');
      return false;
    }
  }

  /// Update notification content
  void updateNotification(String title, String content) {
    if (_initializationFailed) {
      return; // Service not available
    }

    try {
      final service = FlutterBackgroundService();
      service.invoke('updateNotification', {
        'title': title,
        'content': content,
      });
    } catch (e) {
      _logger.log('[BackgroundService] updateNotification failed: $e');
    }
  }

  /// Update notification with connection status
  /// Shows OBD and MQTT status in the notification bar
  /// Works with or without the background service running
  Future<void> updateStatusNotification({
    required bool obdConnected,
    required bool mqttConnected,
    double? soc,
    double? power,
    bool? isCharging,
  }) async {
    try {
      // Build title with connection indicators
      String title = 'XPCarData';
      if (obdConnected || mqttConnected) {
        final connected = <String>[];
        if (obdConnected) connected.add('OBD');
        if (mqttConnected) connected.add('MQTT');
        title = 'XPCarData [${connected.join(' | ')}]';
      }

      // Build content with vehicle data
      String content;
      if (soc != null) {
        final socStr = soc.toStringAsFixed(0);
        if (isCharging == true && power != null) {
          final powerStr = power.abs().toStringAsFixed(1);
          content = 'SOC: $socStr% | Charging: ${powerStr}kW';
        } else if (power != null && power.abs() > 0.5) {
          final powerStr = power.toStringAsFixed(1);
          content = 'SOC: $socStr% | Power: ${powerStr}kW';
        } else {
          content = 'SOC: $socStr%';
        }
      } else {
        // No data yet
        if (!obdConnected && !mqttConnected) {
          content = 'Not connected';
        } else {
          content = 'Waiting for data...';
        }
      }

      // Try background service notification first (if running)
      if (!_initializationFailed) {
        try {
          final service = FlutterBackgroundService();
          final isRunning = await service.isRunning();
          if (isRunning) {
            updateNotification(title, content);
            return;
          }
        } catch (_) {
          // Background service not available, fall through to direct notification
        }
      }

      // Use direct notification if background service not running
      await _showDirectNotification(title, content);
    } catch (e) {
      _logger.log('[BackgroundService] updateStatusNotification failed: $e');
    }
  }

  /// Show a direct notification without background service
  Future<void> _showDirectNotification(String title, String content) async {
    try {
      // Initialize plugin if needed
      _notificationsPlugin ??= FlutterLocalNotificationsPlugin();

      // Create status channel if it doesn't exist
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        statusChannelId,
        statusChannelName,
        description: 'Shows vehicle status when app is running',
        importance: Importance.low,
        showBadge: false,
        enableVibration: false,
        playSound: false,
      );

      await _notificationsPlugin!
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      // Show/update the notification
      const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        statusChannelId,
        statusChannelName,
        channelDescription: 'Shows vehicle status when app is running',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        showWhen: false,
        silent: true,
      );

      const NotificationDetails notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _notificationsPlugin!.show(
        statusNotificationId,
        title,
        content,
        notificationDetails,
      );

      _statusNotificationEnabled = true;
    } catch (e) {
      _logger.log('[BackgroundService] Direct notification failed: $e');
    }
  }

  /// Cancel the status notification
  Future<void> cancelStatusNotification() async {
    try {
      _notificationsPlugin ??= FlutterLocalNotificationsPlugin();
      await _notificationsPlugin!.cancel(statusNotificationId);
      _statusNotificationEnabled = false;
    } catch (e) {
      _logger.log('[BackgroundService] Cancel notification failed: $e');
    }
  }
}

/// Background service entry point - runs in isolate
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  // Run in error zone to catch all errors in the isolate
  runZonedGuarded(() async {
    DartPluginRegistrant.ensureInitialized();

    final logger = DebugLogger.instance;
    logger.log('[BackgroundService] Service started in isolate');

    // Handle stop command - wrap in try-catch for AI box compatibility
    try {
      service.on('stop').listen((event) {
        try {
          service.stopSelf();
          logger.log('[BackgroundService] Service stopped by command');
        } catch (e) {
          logger.log('[BackgroundService] stopSelf error: $e');
        }
      });
    } catch (e) {
      logger.log('[BackgroundService] Failed to register stop listener: $e');
    }

    // Handle notification update - wrap in try-catch for AI box compatibility
    try {
      service.on('updateNotification').listen((event) {
        try {
          if (service is AndroidServiceInstance) {
            final title = event?['title'] ?? 'XPCarData';
            final content = event?['content'] ?? 'Collecting vehicle data...';
            service.setForegroundNotificationInfo(
              title: title,
              content: content,
            );
          }
        } catch (e) {
          logger.log('[BackgroundService] setForegroundNotificationInfo error: $e');
        }
      });
    } catch (e) {
      logger.log('[BackgroundService] Failed to register notification listener: $e');
    }

    // Set as foreground service on Android - wrap in try-catch for AI box compatibility
    try {
      if (service is AndroidServiceInstance) {
        service.setAsForegroundService();
      }
    } catch (e) {
      logger.log('[BackgroundService] Failed to set foreground service: $e');
    }

    // Main background loop - wrap all operations in try-catch
    Timer.periodic(const Duration(seconds: 30), (timer) async {
      try {
        if (service is AndroidServiceInstance) {
          if (await service.isForegroundService()) {
            // Update notification with current time to show service is active
            final now = DateTime.now();
            final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
            service.setForegroundNotificationInfo(
              title: 'XPCarData',
              content: 'Last update: $timeStr',
            );
          }
        }

        // Send data to UI if needed
        service.invoke('update', {
          'timestamp': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        logger.log('[BackgroundService] Timer tick error: $e');
      }
    });
  }, (error, stackTrace) {
    // Catch any unhandled errors in the isolate
    final logger = DebugLogger.instance;
    logger.log('[BackgroundService] Uncaught error in isolate: $error');
    // Don't rethrow - let the service continue running
  });
}

/// iOS background handler
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  return true;
}
