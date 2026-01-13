import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'debug_logger.dart';

/// Model for a charging station from Open Charge Map
class ChargingStation {
  final int id;
  final String? name;
  final String? operatorName;
  final String? address;
  final String? town;
  final String? postcode;
  final double latitude;
  final double longitude;
  final double? distanceKm;
  final int? numberOfPoints;
  final List<String> connectionTypes;
  final double? maxPowerKw;

  const ChargingStation({
    required this.id,
    this.name,
    this.operatorName,
    this.address,
    this.town,
    this.postcode,
    required this.latitude,
    required this.longitude,
    this.distanceKm,
    this.numberOfPoints,
    this.connectionTypes = const [],
    this.maxPowerKw,
  });

  /// Get a display name for the station
  String get displayName {
    if (name != null && name!.isNotEmpty) return name!;
    if (operatorName != null && operatorName!.isNotEmpty) {
      if (town != null && town!.isNotEmpty) {
        return '$operatorName - $town';
      }
      return operatorName!;
    }
    if (address != null && address!.isNotEmpty) return address!;
    if (town != null && town!.isNotEmpty) return town!;
    return 'Charging Station #$id';
  }

  /// Get a short description
  String get shortDescription {
    final parts = <String>[];
    if (operatorName != null && operatorName!.isNotEmpty) {
      parts.add(operatorName!);
    }
    if (maxPowerKw != null && maxPowerKw! > 0) {
      parts.add('${maxPowerKw!.toStringAsFixed(0)} kW');
    }
    if (numberOfPoints != null && numberOfPoints! > 0) {
      parts.add('$numberOfPoints points');
    }
    return parts.isEmpty ? 'Charging Station' : parts.join(' • ');
  }

  factory ChargingStation.fromJson(Map<String, dynamic> json) {
    final addressInfo = json['AddressInfo'] as Map<String, dynamic>?;
    final operatorInfo = json['OperatorInfo'] as Map<String, dynamic>?;
    final connections = json['Connections'] as List<dynamic>? ?? [];

    // Extract connection types and max power
    final connTypes = <String>[];
    double? maxPower;
    for (final conn in connections) {
      final connMap = conn as Map<String, dynamic>;
      final connType = connMap['ConnectionType'] as Map<String, dynamic>?;
      if (connType != null) {
        final title = connType['Title'] as String?;
        if (title != null && !connTypes.contains(title)) {
          connTypes.add(title);
        }
      }
      final power = (connMap['PowerKW'] as num?)?.toDouble();
      if (power != null && (maxPower == null || power > maxPower)) {
        maxPower = power;
      }
    }

    return ChargingStation(
      id: json['ID'] as int,
      name: addressInfo?['Title'] as String?,
      operatorName: operatorInfo?['Title'] as String?,
      address: addressInfo?['AddressLine1'] as String?,
      town: addressInfo?['Town'] as String?,
      postcode: addressInfo?['Postcode'] as String?,
      latitude: (addressInfo?['Latitude'] as num?)?.toDouble() ?? 0,
      longitude: (addressInfo?['Longitude'] as num?)?.toDouble() ?? 0,
      distanceKm: (json['Distance'] as num?)?.toDouble(),
      numberOfPoints: json['NumberOfPoints'] as int?,
      connectionTypes: connTypes,
      maxPowerKw: maxPower,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'operatorName': operatorName,
    'address': address,
    'town': town,
    'postcode': postcode,
    'latitude': latitude,
    'longitude': longitude,
    'distanceKm': distanceKm,
    'numberOfPoints': numberOfPoints,
    'connectionTypes': connectionTypes,
    'maxPowerKw': maxPowerKw,
  };

  factory ChargingStation.fromCacheJson(Map<String, dynamic> json) {
    return ChargingStation(
      id: json['id'] as int,
      name: json['name'] as String?,
      operatorName: json['operatorName'] as String?,
      address: json['address'] as String?,
      town: json['town'] as String?,
      postcode: json['postcode'] as String?,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      distanceKm: (json['distanceKm'] as num?)?.toDouble(),
      numberOfPoints: json['numberOfPoints'] as int?,
      connectionTypes: (json['connectionTypes'] as List<dynamic>?)?.cast<String>() ?? [],
      maxPowerKw: (json['maxPowerKw'] as num?)?.toDouble(),
    );
  }
}

/// Service for looking up charging stations via Open Charge Map API
class OpenChargeMapService {
  static final OpenChargeMapService _instance = OpenChargeMapService._internal();
  static OpenChargeMapService get instance => _instance;
  OpenChargeMapService._internal();

  final _logger = DebugLogger.instance;

  // API configuration
  static const String _baseUrl = 'https://api.openchargemap.io/v3/poi';
  // User-provided API key
  static const String _apiKey = 'bb7def66-2276-4d19-a072-6d990a7694d6';

  // Cache configuration
  static const int _cacheExpirationHours = 24 * 7; // 7 days
  static const int _maxCacheEntries = 100;

  // In-memory cache: key = "lat,lon" (rounded), value = station
  final Map<String, ChargingStation> _stationCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};

  // Home location
  double? _homeLatitude;
  double? _homeLongitude;
  String? _homeLocationName;

  /// Get home location coordinates
  double? get homeLatitude => _homeLatitude;
  double? get homeLongitude => _homeLongitude;
  String? get homeLocationName => _homeLocationName;

  /// Check if home location is set
  bool get hasHomeLocation => _homeLatitude != null && _homeLongitude != null;

  /// Initialize service and load cache
  Future<void> initialize() async {
    await _loadCache();
    await _loadHomeLocation();
    _logger.log('[OCM] Initialized with ${_stationCache.length} cached stations');
  }

  /// Set home location
  Future<void> setHomeLocation(double lat, double lon, String? name) async {
    _homeLatitude = lat;
    _homeLongitude = lon;
    _homeLocationName = name ?? 'Home';
    await _saveHomeLocation();
    _logger.log('[OCM] Home location set: $lat, $lon ($name)');
  }

  /// Clear home location
  Future<void> clearHomeLocation() async {
    _homeLatitude = null;
    _homeLongitude = null;
    _homeLocationName = null;
    await _saveHomeLocation();
    _logger.log('[OCM] Home location cleared');
  }

  /// Check if location is near home (within 100m)
  bool isNearHome(double lat, double lon) {
    if (!hasHomeLocation) return false;
    final distance = _calculateDistance(lat, lon, _homeLatitude!, _homeLongitude!);
    return distance < 0.1; // 100 meters
  }

  /// Find nearest charging station to given coordinates
  /// Returns cached result if available, otherwise fetches from API
  Future<ChargingStation?> findNearestStation(double latitude, double longitude, {double radiusKm = 0.5}) async {
    // Check if near home first
    if (isNearHome(latitude, longitude)) {
      _logger.log('[OCM] Location is near home, returning home location');
      return ChargingStation(
        id: 0,
        name: _homeLocationName ?? 'Home',
        latitude: _homeLatitude!,
        longitude: _homeLongitude!,
        operatorName: 'Home',
      );
    }

    // Check cache
    final cacheKey = _getCacheKey(latitude, longitude);
    final cached = _getFromCache(cacheKey);
    if (cached != null) {
      _logger.log('[OCM] Cache hit for $cacheKey: ${cached.displayName}');
      return cached;
    }

    // Fetch from API
    _logger.log('[OCM] Fetching station near $latitude, $longitude (radius: ${radiusKm}km)');
    try {
      final stations = await _fetchStations(latitude, longitude, radiusKm);
      if (stations.isEmpty) {
        _logger.log('[OCM] No stations found');
        return null;
      }

      // Return nearest station
      final nearest = stations.first;
      _logger.log('[OCM] Found station: ${nearest.displayName} (${nearest.distanceKm?.toStringAsFixed(2)}km away)');

      // Cache result
      _addToCache(cacheKey, nearest);

      return nearest;
    } catch (e) {
      _logger.log('[OCM] API error: $e');
      return null;
    }
  }

  /// Fetch stations from Open Charge Map API
  Future<List<ChargingStation>> _fetchStations(double lat, double lon, double radiusKm) async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'key': _apiKey,
      'latitude': lat.toString(),
      'longitude': lon.toString(),
      'distance': radiusKm.toString(),
      'distanceunit': 'KM',
      'maxresults': '5',
      'compact': 'true',
      'verbose': 'false',
    });

    final response = await http.get(uri, headers: {
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('API returned ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((json) => ChargingStation.fromJson(json as Map<String, dynamic>))
        .where((s) => s.latitude != 0 && s.longitude != 0)
        .toList();
  }

  /// Get cache key for coordinates (rounded to ~100m grid)
  String _getCacheKey(double lat, double lon) {
    // Round to 3 decimal places (~100m precision)
    final latKey = (lat * 1000).round() / 1000;
    final lonKey = (lon * 1000).round() / 1000;
    return '$latKey,$lonKey';
  }

  /// Get station from cache if not expired
  ChargingStation? _getFromCache(String key) {
    final station = _stationCache[key];
    final timestamp = _cacheTimestamps[key];

    if (station == null || timestamp == null) return null;

    // Check expiration
    final age = DateTime.now().difference(timestamp);
    if (age.inHours > _cacheExpirationHours) {
      _stationCache.remove(key);
      _cacheTimestamps.remove(key);
      return null;
    }

    return station;
  }

  /// Add station to cache
  void _addToCache(String key, ChargingStation station) {
    // Limit cache size
    if (_stationCache.length >= _maxCacheEntries) {
      // Remove oldest entries
      final sortedKeys = _cacheTimestamps.entries
          .toList()
          ..sort((a, b) => a.value.compareTo(b.value));
      for (var i = 0; i < 20 && i < sortedKeys.length; i++) {
        _stationCache.remove(sortedKeys[i].key);
        _cacheTimestamps.remove(sortedKeys[i].key);
      }
    }

    _stationCache[key] = station;
    _cacheTimestamps[key] = DateTime.now();
    _saveCache(); // Async, fire and forget
  }

  /// Calculate distance between two coordinates in km
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371.0; // km
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) * cos(_toRadians(lat2)) *
            sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * pi / 180;

  /// Load cache from persistent storage
  Future<void> _loadCache() async {
    try {
      // Try file-based storage (more reliable on AI boxes)
      final cacheFile = await _getCacheFile();
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;

        final stations = data['stations'] as Map<String, dynamic>? ?? {};
        final timestamps = data['timestamps'] as Map<String, dynamic>? ?? {};

        for (final entry in stations.entries) {
          try {
            _stationCache[entry.key] = ChargingStation.fromCacheJson(
              entry.value as Map<String, dynamic>,
            );
            final ts = timestamps[entry.key];
            if (ts != null) {
              _cacheTimestamps[entry.key] = DateTime.parse(ts as String);
            }
          } catch (e) {
            // Skip invalid entries
          }
        }
        _logger.log('[OCM] Loaded ${_stationCache.length} stations from file cache');
      }
    } catch (e) {
      _logger.log('[OCM] Cache load error: $e');
    }
  }

  /// Save cache to persistent storage
  Future<void> _saveCache() async {
    try {
      final cacheFile = await _getCacheFile();
      final data = {
        'stations': _stationCache.map((k, v) => MapEntry(k, v.toJson())),
        'timestamps': _cacheTimestamps.map((k, v) => MapEntry(k, v.toIso8601String())),
      };
      await cacheFile.writeAsString(jsonEncode(data));
    } catch (e) {
      _logger.log('[OCM] Cache save error: $e');
    }
  }

  /// Get cache file
  Future<File> _getCacheFile() async {
    const path = '/data/data/com.example.carsoc/files/ocm_cache.json';
    return File(path);
  }

  /// Load home location
  Future<void> _loadHomeLocation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _homeLatitude = prefs.getDouble('home_latitude');
      _homeLongitude = prefs.getDouble('home_longitude');
      _homeLocationName = prefs.getString('home_location_name');
    } catch (e) {
      // Try file fallback
      try {
        final file = File('/data/data/com.example.carsoc/files/home_location.json');
        if (await file.exists()) {
          final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          _homeLatitude = (data['latitude'] as num?)?.toDouble();
          _homeLongitude = (data['longitude'] as num?)?.toDouble();
          _homeLocationName = data['name'] as String?;
        }
      } catch (_) {}
    }
    if (hasHomeLocation) {
      _logger.log('[OCM] Home location loaded: $_homeLatitude, $_homeLongitude');
    }
  }

  /// Save home location
  Future<void> _saveHomeLocation() async {
    // Save to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      if (hasHomeLocation) {
        await prefs.setDouble('home_latitude', _homeLatitude!);
        await prefs.setDouble('home_longitude', _homeLongitude!);
        if (_homeLocationName != null) {
          await prefs.setString('home_location_name', _homeLocationName!);
        }
      } else {
        await prefs.remove('home_latitude');
        await prefs.remove('home_longitude');
        await prefs.remove('home_location_name');
      }
    } catch (e) {
      _logger.log('[OCM] SharedPrefs save error: $e');
    }

    // Also save to file (fallback)
    try {
      final file = File('/data/data/com.example.carsoc/files/home_location.json');
      if (hasHomeLocation) {
        await file.writeAsString(jsonEncode({
          'latitude': _homeLatitude,
          'longitude': _homeLongitude,
          'name': _homeLocationName,
        }));
      } else if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      _logger.log('[OCM] File save error: $e');
    }
  }

  /// Clear all cached stations
  Future<void> clearCache() async {
    _stationCache.clear();
    _cacheTimestamps.clear();
    try {
      final cacheFile = await _getCacheFile();
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
    } catch (_) {}
    _logger.log('[OCM] Cache cleared');
  }
}
