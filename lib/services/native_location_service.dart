import 'dart:async';
import 'package:flutter/services.dart';
import 'debug_logger.dart';

/// Location data model (same as LocationService)
class NativeLocationData {
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? speed; // m/s
  final double? heading;
  final double? accuracy;
  final DateTime timestamp;
  final String? provider;

  const NativeLocationData({
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.speed,
    this.heading,
    this.accuracy,
    required this.timestamp,
    this.provider,
  });

  /// Speed in km/h
  double? get speedKmh => speed != null ? speed! * 3.6 : null;

  @override
  String toString() {
    return 'NativeLocationData(lat: $latitude, lon: $longitude, alt: $altitude, speed: ${speedKmh?.toStringAsFixed(1)} km/h, provider: $provider)';
  }
}

/// Native location service using Android LocationManager via Method Channel.
/// This bypasses the geolocator Flutter plugin which fails on some Android 13 devices.
class NativeLocationService {
  static NativeLocationService? _instance;
  static NativeLocationService get instance {
    _instance ??= NativeLocationService._internal();
    return _instance!;
  }

  static const _channel = MethodChannel('com.example.carsoc/location');
  final _logger = DebugLogger.instance;

  bool _isEnabled = false;
  bool _hasPermission = false;
  NativeLocationData? _lastLocation;
  Timer? _pollingTimer;

  final StreamController<NativeLocationData> _locationController =
      StreamController<NativeLocationData>.broadcast();

  NativeLocationService._internal();

  /// Stream of location updates
  Stream<NativeLocationData> get locationStream => _locationController.stream;

  /// Last known location
  NativeLocationData? get lastLocation => _lastLocation;

  /// Whether location service is enabled
  bool get isEnabled => _isEnabled;

  /// Whether we have location permission
  bool get hasPermission => _hasPermission;

  /// Initialize and check permissions
  Future<bool> initialize() async {
    _logger.log('[NativeLocation] Initializing...');

    try {
      // Check if location services are enabled
      final serviceEnabled = await _channel.invokeMethod<bool>('isLocationEnabled') ?? false;
      if (!serviceEnabled) {
        _logger.log('[NativeLocation] Location services are disabled');
        return false;
      }

      // Check permission
      final hasPerms = await _channel.invokeMethod<bool>('hasPermissions') ?? false;
      if (!hasPerms) {
        _logger.log('[NativeLocation] No location permission granted');
        // Note: We can't request permissions from here - user must grant via system settings
        return false;
      }

      _hasPermission = true;
      _logger.log('[NativeLocation] Permission granted, service enabled');

      return true;
    } catch (e) {
      _logger.log('[NativeLocation] Initialization error: $e');
      return false;
    }
  }

  /// Start listening for location updates
  Future<void> startTracking({
    int intervalSeconds = 10,
    int distanceMeters = 10,
  }) async {
    if (!_hasPermission) {
      final initialized = await initialize();
      if (!initialized) {
        _logger.log('[NativeLocation] Cannot start tracking - no permission');
        return;
      }
    }

    // Stop existing tracking
    await stopTracking();

    _logger.log('[NativeLocation] Starting location tracking (interval: ${intervalSeconds}s, distance: ${distanceMeters}m)');

    try {
      // Start native tracking
      final started = await _channel.invokeMethod<bool>('startTracking', {
        'minTimeMs': intervalSeconds * 1000,
        'minDistanceM': distanceMeters.toDouble(),
      }) ?? false;

      if (started) {
        _isEnabled = true;
        _logger.log('[NativeLocation] Native tracking started');

        // Start polling for location updates (native tracking updates internally)
        _pollingTimer = Timer.periodic(Duration(seconds: intervalSeconds), (_) async {
          await _pollLocation();
        });

        // Get initial location
        await _pollLocation();
      } else {
        _logger.log('[NativeLocation] Failed to start native tracking');
      }
    } catch (e) {
      _logger.log('[NativeLocation] Error starting tracking: $e');
    }
  }

  /// Poll for current location from native side
  Future<void> _pollLocation() async {
    try {
      final locationMap = await _channel.invokeMethod<Map<Object?, Object?>>('getLastKnownLocation');
      if (locationMap != null) {
        final location = _parseLocationMap(locationMap);
        if (location != null) {
          _lastLocation = location;
          _locationController.add(location);
          _logger.log('[NativeLocation] Update: ${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)} (accuracy: ${location.accuracy?.toStringAsFixed(0)}m)');
        }
      }
    } catch (e) {
      _logger.log('[NativeLocation] Poll error: $e');
    }
  }

  /// Get current location once
  Future<NativeLocationData?> getCurrentLocation() async {
    if (!_hasPermission) {
      final initialized = await initialize();
      if (!initialized) return null;
    }

    try {
      _logger.log('[NativeLocation] Getting current location...');
      final locationMap = await _channel.invokeMethod<Map<Object?, Object?>>('getCurrentLocation');

      if (locationMap != null) {
        final location = _parseLocationMap(locationMap);
        if (location != null) {
          _lastLocation = location;
          _logger.log('[NativeLocation] Current: ${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}');
          return location;
        }
      }

      _logger.log('[NativeLocation] No location available');
      return null;
    } catch (e) {
      _logger.log('[NativeLocation] Error getting current location: $e');
      return null;
    }
  }

  /// Parse location map from native side
  NativeLocationData? _parseLocationMap(Map<Object?, Object?> map) {
    try {
      final lat = map['latitude'];
      final lon = map['longitude'];

      if (lat == null || lon == null) return null;

      return NativeLocationData(
        latitude: (lat as num).toDouble(),
        longitude: (lon as num).toDouble(),
        altitude: (map['altitude'] as num?)?.toDouble(),
        speed: (map['speed'] as num?)?.toDouble(),
        heading: (map['heading'] as num?)?.toDouble(),
        accuracy: (map['accuracy'] as num?)?.toDouble(),
        timestamp: map['timestamp'] != null
            ? DateTime.fromMillisecondsSinceEpoch((map['timestamp'] as num).toInt())
            : DateTime.now(),
        provider: map['provider'] as String?,
      );
    } catch (e) {
      _logger.log('[NativeLocation] Parse error: $e');
      return null;
    }
  }

  /// Stop tracking location
  Future<void> stopTracking() async {
    _pollingTimer?.cancel();
    _pollingTimer = null;

    try {
      await _channel.invokeMethod('stopTracking');
    } catch (e) {
      _logger.log('[NativeLocation] Error stopping tracking: $e');
    }

    _isEnabled = false;
    _logger.log('[NativeLocation] Tracking stopped');
  }

  /// Check if tracking is active
  Future<bool> isTracking() async {
    try {
      return await _channel.invokeMethod<bool>('isTracking') ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Dispose
  void dispose() {
    stopTracking();
    _locationController.close();
  }
}
