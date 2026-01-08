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
    final service = FlutterBackgroundService();
    service.invoke('updateNotification', {
      'title': title,
      'content': content,
    });
  }
}

/// Background service entry point - runs in isolate
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final logger = DebugLogger.instance;
  logger.log('[BackgroundService] Service started in isolate');

  // Handle stop command
  service.on('stop').listen((event) {
    service.stopSelf();
    logger.log('[BackgroundService] Service stopped by command');
  });

  // Handle notification update
  service.on('updateNotification').listen((event) {
    if (service is AndroidServiceInstance) {
      final title = event?['title'] ?? 'XPCarData';
      final content = event?['content'] ?? 'Collecting vehicle data...';
      service.setForegroundNotificationInfo(
        title: title,
        content: content,
      );
    }
  });

  // Set as foreground service on Android
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }

  // Main background loop
  Timer.periodic(const Duration(seconds: 30), (timer) async {
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
  });
}

/// iOS background handler
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  return true;
}
