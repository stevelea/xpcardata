import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'debug_logger.dart';

/// Location data model
class LocationData {
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? speed; // m/s
  final double? heading;
  final double? accuracy;
  final DateTime timestamp;

  const LocationData({
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.speed,
    this.heading,
    this.accuracy,
    required this.timestamp,
  });

  /// Speed in km/h
  double? get speedKmh => speed != null ? speed! * 3.6 : null;

  @override
  String toString() {
    return 'LocationData(lat: $latitude, lon: $longitude, alt: $altitude, speed: ${speedKmh?.toStringAsFixed(1)} km/h)';
  }
}

/// Location service for GPS data (Singleton)
class LocationService {
  static LocationService? _instance;
  static LocationService get instance {
    _instance ??= LocationService._internal();
    return _instance!;
  }

  final _logger = DebugLogger.instance;

  bool _isEnabled = false;
  bool _hasPermission = false;
  LocationData? _lastLocation;
  StreamSubscription<Position>? _positionSubscription;

  final StreamController<LocationData> _locationController =
      StreamController<LocationData>.broadcast();

  LocationService._internal();

  /// Stream of location updates
  Stream<LocationData> get locationStream => _locationController.stream;

  /// Last known location
  LocationData? get lastLocation => _lastLocation;

  /// Whether location service is enabled
  bool get isEnabled => _isEnabled;

  /// Whether we have location permission
  bool get hasPermission => _hasPermission;

  /// Initialize and request permissions
  Future<bool> initialize() async {
    _logger.log('[Location] Initializing...');

    try {
      // Check if location services are enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _logger.log('[Location] Location services are disabled');
        return false;
      }

      // Check permission
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        _logger.log('[Location] Requesting permission...');
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _logger.log('[Location] Permission denied');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _logger.log('[Location] Permission denied forever');
        return false;
      }

      _hasPermission = true;
      _logger.log('[Location] Permission granted: $permission');

      return true;
    } catch (e) {
      _logger.log('[Location] Initialization error: $e');
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
        _logger.log('[Location] Cannot start tracking - no permission');
        return;
      }
    }

    // Cancel existing subscription
    await stopTracking();

    _logger.log('[Location] Starting location tracking (interval: ${intervalSeconds}s, distance: ${distanceMeters}m)');

    // Use simple LocationSettings to avoid foreground service conflicts
    // The app already has its own background service
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10, // meters
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) {
        final locationData = LocationData(
          latitude: position.latitude,
          longitude: position.longitude,
          altitude: position.altitude,
          speed: position.speed,
          heading: position.heading,
          accuracy: position.accuracy,
          timestamp: position.timestamp,
        );

        _lastLocation = locationData;
        _locationController.add(locationData);

        _logger.log('[Location] Update: ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)} (accuracy: ${position.accuracy.toStringAsFixed(0)}m)');
      },
      onError: (error) {
        _logger.log('[Location] Stream error: $error');
      },
    );

    _isEnabled = true;
  }

  /// Get current location once
  Future<LocationData?> getCurrentLocation() async {
    if (!_hasPermission) {
      final initialized = await initialize();
      if (!initialized) return null;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      final locationData = LocationData(
        latitude: position.latitude,
        longitude: position.longitude,
        altitude: position.altitude,
        speed: position.speed,
        heading: position.heading,
        accuracy: position.accuracy,
        timestamp: position.timestamp,
      );

      _lastLocation = locationData;
      _logger.log('[Location] Current: ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}');

      return locationData;
    } catch (e) {
      _logger.log('[Location] Error getting current location: $e');
      return null;
    }
  }

  /// Stop tracking location
  Future<void> stopTracking() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _isEnabled = false;
    _logger.log('[Location] Tracking stopped');
  }

  /// Dispose
  void dispose() {
    stopTracking();
    _locationController.close();
  }
}
