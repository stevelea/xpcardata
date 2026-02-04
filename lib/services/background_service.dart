import 'dart:async';
import 'dart:ui';
import 'package:flutter/services.dart';
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

  // Cache the service instance to avoid repeated platform channel setup
  FlutterBackgroundService? _serviceInstance;
  bool _platformChannelBroken = false;

  /// Safely get the background service instance
  /// Returns null if platform channels are broken
  FlutterBackgroundService? _getService() {
    if (_platformChannelBroken) {
      return null;
    }
    try {
      _serviceInstance ??= FlutterBackgroundService();
      return _serviceInstance;
    } on MissingPluginException catch (e) {
      _logger.log('[BackgroundService] Platform channel missing: $e');
      _platformChannelBroken = true;
      _initializationFailed = true;
      return null;
    } catch (e) {
      _logger.log('[BackgroundService] Failed to get service: $e');
      _platformChannelBroken = true;
      _initializationFailed = true;
      return null;
    }
  }

  /// Pre-flight check: test if the background service platform channel works
  /// by calling isRunning(). If it throws, platform channels are broken.
  Future<bool> _preFlightCheck() async {
    try {
      final service = _getService();
      if (service == null) return false;
      // This will throw MissingPluginException if platform channels are broken
      await service.isRunning();
      return true;
    } on MissingPluginException catch (e) {
      _logger.log('[BackgroundService] Pre-flight check failed: $e');
      _platformChannelBroken = true;
      _initializationFailed = true;
      return false;
    } catch (e) {
      _logger.log('[BackgroundService] Pre-flight check error: $e');
      _platformChannelBroken = true;
      _initializationFailed = true;
      return false;
    }
  }

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
    // Use zone guard to catch any async errors that might escape try-catch
    Object? zoneError;

    // Use a completer to track completion and handle timeout
    final completer = Completer<void>();

    // Set a timeout to prevent hanging if plugin is broken
    Timer? timeoutTimer;
    timeoutTimer = Timer(const Duration(seconds: 5), () {
      if (!completer.isCompleted) {
        _logger.log('[BackgroundService] Initialization timed out - plugin likely broken');
        _isInitialized = false;
        _initializationFailed = true;
        _platformChannelBroken = true;
        completer.complete();
      }
    });

    runZonedGuarded(() async {
      try {
        final service = _getService();
        if (service == null) {
          _logger.log('[BackgroundService] Platform channels not available');
          _initializationFailed = true;
          timeoutTimer?.cancel();
          if (!completer.isCompleted) completer.complete();
          return;
        }

        // Pre-flight: test if the plugin's platform channel actually works
        // before calling configure() which registers an isolate callback.
        // If isRunning() throws, the plugin is non-functional on this device.
        final channelWorks = await _preFlightCheck();
        if (!channelWorks) {
          _logger.log('[BackgroundService] Pre-flight check failed - plugin non-functional');
          timeoutTimer?.cancel();
          if (!completer.isCompleted) completer.complete();
          return;
        }

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

        // Configure the service - can fail if plugin's native side isn't registered
        try {
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
        } on MissingPluginException catch (e) {
          _logger.log('[BackgroundService] Configure failed - platform channel missing: $e');
          _platformChannelBroken = true;
          _initializationFailed = true;
          _isInitialized = false;
          timeoutTimer?.cancel();
          if (!completer.isCompleted) completer.complete();
          return;
        }

        _isInitialized = true;
        _initializationFailed = false;
        _logger.log('[BackgroundService] Initialized');

        timeoutTimer?.cancel();
        if (!completer.isCompleted) completer.complete();
      } on MissingPluginException catch (e) {
        _logger.log('[BackgroundService] Platform channel missing during initialization: $e');
        _logger.log('[BackgroundService] Background service will be disabled');
        _isInitialized = false;
        _initializationFailed = true;
        _platformChannelBroken = true;
        timeoutTimer?.cancel();
        if (!completer.isCompleted) completer.complete();
      } catch (e) {
        _logger.log('[BackgroundService] Initialization failed: $e');
        _logger.log('[BackgroundService] Background service will be disabled');
        _isInitialized = false;
        _initializationFailed = true;
        timeoutTimer?.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    }, (error, stack) {
      zoneError = error;
      _logger.log('[BackgroundService] Zone caught async error during init: $error');
      _isInitialized = false;
      _initializationFailed = true;
      _platformChannelBroken = true;
      timeoutTimer?.cancel();
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future;

    if (zoneError != null) {
      _logger.log('[BackgroundService] Initialization failed due to zone error');
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
      if (_initializationFailed || _platformChannelBroken) {
        _logger.log('[BackgroundService] Cannot start - initialization failed or platform channels broken');
        throw Exception('Background service not available on this device');
      }

      final service = _getService();
      if (service == null) {
        throw Exception('Background service not available on this device');
      }
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
    if (_initializationFailed || _platformChannelBroken) {
      return; // Nothing to stop
    }

    try {
      final service = _getService();
      if (service == null) return;
      service.invoke('stop');
      _logger.log('[BackgroundService] Stopped');
    } on MissingPluginException catch (e) {
      _logger.log('[BackgroundService] Stop failed - platform channel missing: $e');
      _platformChannelBroken = true;
    } catch (e) {
      _logger.log('[BackgroundService] Stop failed: $e');
    }
  }

  /// Check if service is running
  Future<bool> isRunning() async {
    if (_initializationFailed || _platformChannelBroken) {
      return false;
    }

    try {
      await _ensureInitialized();
      final service = _getService();
      if (service == null) return false;
      return await service.isRunning();
    } on MissingPluginException catch (e) {
      _logger.log('[BackgroundService] isRunning check failed - platform channel missing: $e');
      _platformChannelBroken = true;
      return false;
    } catch (e) {
      _logger.log('[BackgroundService] isRunning check failed: $e');
      return false;
    }
  }

  /// Update notification content
  void updateNotification(String title, String content) {
    if (_initializationFailed || _platformChannelBroken) {
      return; // Service not available
    }

    try {
      final service = _getService();
      if (service == null) return;
      service.invoke('updateNotification', {
        'title': title,
        'content': content,
      });
    } on MissingPluginException catch (e) {
      _logger.log('[BackgroundService] updateNotification failed - platform channel missing: $e');
      _platformChannelBroken = true;
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
      // Only attempt if we've successfully initialized AND haven't seen any platform channel issues
      if (_isInitialized && !_initializationFailed && !_platformChannelBroken) {
        try {
          final service = _getService();
          if (service != null) {
            // Use runZonedGuarded to catch async errors that might escape try-catch
            bool? running;
            Object? zoneError;
            await runZonedGuarded(() async {
              running = await service.isRunning();
            }, (error, stack) {
              zoneError = error;
              _logger.log('[BackgroundService] Zone caught error in isRunning: $error');
            });

            // If zone caught an error, mark platform as broken
            if (zoneError != null) {
              _platformChannelBroken = true;
            } else if (running == true) {
              updateNotification(title, content);
              return;
            }
          }
        } on MissingPluginException catch (e) {
          // Platform channel not available - mark as broken and fall through
          _logger.log('[BackgroundService] Platform channel missing in updateStatusNotification: $e');
          _platformChannelBroken = true;
        } catch (e) {
          // Background service not available, mark as broken and fall through
          _logger.log('[BackgroundService] Error in updateStatusNotification: $e');
          _platformChannelBroken = true;
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

    // Track if platform channels are working
    bool platformChannelsWorking = true;

    // Helper to safely subscribe to service events
    // Returns false if subscription fails (platform channels broken)
    bool safeSubscribe(String eventName, void Function(Map<String, dynamic>?) handler) {
      try {
        final stream = service.on(eventName);
        stream.listen(
          handler,
          onError: (error) {
            logger.log('[BackgroundService] Stream error on $eventName: $error');
          },
          cancelOnError: false,
        );
        return true;
      } on MissingPluginException catch (e) {
        logger.log('[BackgroundService] Platform channel missing for $eventName: $e');
        platformChannelsWorking = false;
        return false;
      } catch (e) {
        logger.log('[BackgroundService] Failed to subscribe to $eventName: $e');
        return false;
      }
    }

    // Handle stop command - wrap in try-catch for AI box compatibility
    safeSubscribe('stop', (event) {
      try {
        service.stopSelf();
        logger.log('[BackgroundService] Service stopped by command');
      } catch (e) {
        logger.log('[BackgroundService] stopSelf error: $e');
      }
    });

    // Handle notification update - wrap in try-catch for AI box compatibility
    safeSubscribe('updateNotification', (event) {
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

    // Set as foreground service on Android - wrap in try-catch for AI box compatibility
    try {
      if (service is AndroidServiceInstance) {
        service.setAsForegroundService();
      }
    } catch (e) {
      logger.log('[BackgroundService] Failed to set foreground service: $e');
    }

    // If platform channels aren't working, don't start the timer loop
    // as it will just generate errors
    if (!platformChannelsWorking) {
      logger.log('[BackgroundService] Platform channels broken, stopping service loop');
      try {
        service.stopSelf();
      } catch (e) {
        logger.log('[BackgroundService] Failed to stop self: $e');
      }
      return;
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
