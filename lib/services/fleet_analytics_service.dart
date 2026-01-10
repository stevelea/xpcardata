import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' show sha256;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vehicle_data.dart';
import '../models/charging_session.dart';
import 'debug_logger.dart';

/// Service for sending anonymous fleet statistics to Firebase
/// All data is anonymized and aggregated - no PII is collected
class FleetAnalyticsService {
  // Singleton
  static final FleetAnalyticsService _instance = FleetAnalyticsService._internal();
  static FleetAnalyticsService get instance => _instance;
  FleetAnalyticsService._internal();

  final _logger = DebugLogger.instance;

  // Firebase instances
  FirebaseAnalytics? _analytics;
  FirebaseFirestore? _firestore;

  // Configuration
  bool _isEnabled = false;
  bool _consentGiven = false;
  String? _anonymousDeviceId;
  String _vehicleModel = 'G6';
  String? _countryCode;

  // Rate limiting
  DateTime? _lastBatteryUpload;
  DateTime? _lastDrivingUpload;
  DateTime? _lastCountryLookup;
  static const _batteryUploadInterval = Duration(seconds: 60);
  static const _drivingUploadInterval = Duration(minutes: 5);
  static const _countryLookupInterval = Duration(hours: 24);

  // Getters
  bool get isEnabled => _isEnabled && _consentGiven;
  bool get consentGiven => _consentGiven;

  /// Initialize the service
  Future<void> initialize() async {
    try {
      _analytics = FirebaseAnalytics.instance;
      _firestore = FirebaseFirestore.instance;
      await _loadSettings();
      // Fetch country code in background (non-blocking)
      _fetchCountryCode();
      _logger.log('[FleetAnalytics] Initialized, enabled: $_isEnabled, consent: $_consentGiven');
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to initialize: $e');
    }
  }

  /// Fetch country code from IP geolocation (privacy-preserving)
  /// Only stores the 2-letter country code, not the IP address
  Future<void> _fetchCountryCode() async {
    // Rate limit - only lookup once per 24 hours
    final now = DateTime.now();
    if (_lastCountryLookup != null &&
        now.difference(_lastCountryLookup!) < _countryLookupInterval) {
      return;
    }

    // Skip if we already have a country code from recent lookup
    if (_countryCode != null && _lastCountryLookup != null) {
      return;
    }

    try {
      // Use ip-api.com - free, no API key, returns only country code
      // We only request the countryCode field to minimize data
      final response = await http.get(
        Uri.parse('http://ip-api.com/json/?fields=countryCode'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _countryCode = data['countryCode'] as String?;
        _lastCountryLookup = now;

        // Cache the country code
        await _saveCountryCode();

        _logger.log('[FleetAnalytics] Country detected: $_countryCode');
      }
    } catch (e) {
      // Silently fail - country is optional metadata
      _logger.log('[FleetAnalytics] Country lookup failed (optional): $e');
    }
  }

  /// Save country code to storage
  Future<void> _saveCountryCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_countryCode != null) {
        await prefs.setString('fleet_analytics_country', _countryCode!);
        await prefs.setInt('fleet_analytics_country_timestamp',
            _lastCountryLookup?.millisecondsSinceEpoch ?? 0);
      }
    } catch (e) {
      // Ignore - not critical
    }
  }

  /// Load cached country code
  Future<void> _loadCountryCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _countryCode = prefs.getString('fleet_analytics_country');
      final timestamp = prefs.getInt('fleet_analytics_country_timestamp');
      if (timestamp != null) {
        _lastCountryLookup = DateTime.fromMillisecondsSinceEpoch(timestamp);
      }
    } catch (e) {
      // Ignore - not critical
    }
  }

  /// Configure the service
  Future<void> configure({
    required bool enabled,
    bool? consentGiven,
    String? vehicleModel,
  }) async {
    _isEnabled = enabled;
    if (consentGiven != null) {
      _consentGiven = consentGiven;
    }
    if (vehicleModel != null) {
      _vehicleModel = vehicleModel;
    }
    await _saveSettings();
    _logger.log('[FleetAnalytics] Configured: enabled=$_isEnabled, consent=$_consentGiven');
  }

  /// Set consent status
  Future<void> setConsent(bool consent) async {
    _consentGiven = consent;
    await _saveSettings();

    // Set analytics collection based on consent
    try {
      await _analytics?.setAnalyticsCollectionEnabled(consent && _isEnabled);
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to set analytics collection: $e');
    }
  }

  /// Load settings from storage
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isEnabled = prefs.getBool('fleet_analytics_enabled') ?? false;
      _consentGiven = prefs.getBool('fleet_analytics_consent') ?? false;
      _anonymousDeviceId = prefs.getString('fleet_analytics_device_id');
      _vehicleModel = prefs.getString('vehicle_model') ?? 'G6';

      // Generate anonymous device ID if not exists
      if (_anonymousDeviceId == null) {
        _anonymousDeviceId = _generateAnonymousId();
        await prefs.setString('fleet_analytics_device_id', _anonymousDeviceId!);
      }

      // Load cached country code
      await _loadCountryCode();
    } catch (e) {
      // SharedPreferences may fail on AAOS - try file fallback
      await _loadSettingsFromFile();
    }
  }

  /// Load settings from file (AAOS fallback)
  Future<void> _loadSettingsFromFile() async {
    try {
      final directory = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final file = File('${directory.path}/fleet_analytics_settings.json');
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        _isEnabled = json['enabled'] ?? false;
        _consentGiven = json['consent'] ?? false;
        _anonymousDeviceId = json['device_id'];
        _vehicleModel = json['vehicle_model'] ?? 'G6';
      }

      // Generate anonymous device ID if not exists
      if (_anonymousDeviceId == null) {
        _anonymousDeviceId = _generateAnonymousId();
        await _saveSettingsToFile();
      }
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to load settings from file: $e');
    }
  }

  /// Save settings to storage
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('fleet_analytics_enabled', _isEnabled);
      await prefs.setBool('fleet_analytics_consent', _consentGiven);
      if (_anonymousDeviceId != null) {
        await prefs.setString('fleet_analytics_device_id', _anonymousDeviceId!);
      }
    } catch (e) {
      // Fallback to file
      await _saveSettingsToFile();
    }
  }

  /// Save settings to file (AAOS fallback)
  Future<void> _saveSettingsToFile() async {
    try {
      final directory = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final file = File('${directory.path}/fleet_analytics_settings.json');
      await file.writeAsString(jsonEncode({
        'enabled': _isEnabled,
        'consent': _consentGiven,
        'device_id': _anonymousDeviceId,
        'vehicle_model': _vehicleModel,
      }));
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to save settings to file: $e');
    }
  }

  /// Generate an anonymous device ID (not traceable to user)
  String _generateAnonymousId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecond;
    final hash = sha256.convert(utf8.encode('$timestamp-$random-fleet'));
    return hash.toString().substring(0, 16);
  }

  /// Record battery metrics (anonymous, bucketed)
  Future<void> recordBatteryMetrics(VehicleData data) async {
    if (!isEnabled) return;

    // Rate limiting
    final now = DateTime.now();
    if (_lastBatteryUpload != null &&
        now.difference(_lastBatteryUpload!) < _batteryUploadInterval) {
      return;
    }
    _lastBatteryUpload = now;

    try {
      // Bucket values for anonymity (5% increments for SOC/SOH)
      final socBucket = _bucketValue(data.stateOfCharge, 5);
      final sohBucket = _bucketValue(data.stateOfHealth, 5);
      final tempRange = _getTemperatureRange(data.batteryTemperature);

      // Calculate cell voltage delta if available
      int? cellDeltaMvBucket;
      final hvMaxV = data.additionalProperties?['HV_C_V_MAX'];
      final hvMinV = data.additionalProperties?['HV_C_V_MIN'];
      if (hvMaxV != null && hvMinV != null && hvMaxV is num && hvMinV is num) {
        final deltaMv = ((hvMaxV - hvMinV) * 1000).round();
        cellDeltaMvBucket = _bucketValue(deltaMv.toDouble(), 10);
      }

      final params = <String, Object>{
        'soc_bucket': socBucket ?? 0,
        'soh_bucket': sohBucket ?? 0,
        'temp_range': tempRange,
        'vehicle_model': _vehicleModel,
        if (cellDeltaMvBucket != null) 'cell_delta_mv_bucket': cellDeltaMvBucket,
        if (_countryCode != null) 'country': _countryCode!,
      };

      // Log to Firebase Analytics
      await _analytics?.logEvent(
        name: 'battery_snapshot',
        parameters: params,
      );

      // Write to Firestore for aggregation
      await _firestore?.collection('contributions').add({
        'type': 'battery',
        'device_id': _anonymousDeviceId,
        'timestamp': FieldValue.serverTimestamp(),
        ...params,
      });

      _logger.log('[FleetAnalytics] Recorded battery metrics: SOC=$socBucket%, SOH=$sohBucket%');
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to record battery metrics: $e');
    }
  }

  /// Record charging session (anonymous, bucketed)
  Future<void> recordChargingSession(ChargingSession session) async {
    if (!isEnabled) return;

    try {
      final energyBucket = _bucketValue(session.energyAddedKwh, 5);
      final powerBucket = _bucketValue(session.maxPowerKw, 10);
      final durationMins = session.endTime != null
          ? session.endTime!.difference(session.startTime).inMinutes
          : 0;
      final durationBucket = _bucketValue(durationMins.toDouble(), 10);

      final params = <String, Object>{
        'charging_type': session.chargingType ?? 'unknown',
        'energy_kwh_bucket': energyBucket ?? 0,
        'power_kw_bucket': powerBucket ?? 0,
        'duration_mins_bucket': durationBucket ?? 0,
        'soc_start_bucket': _bucketValue(session.startSoc, 5) ?? 0,
        'soc_end_bucket': _bucketValue(session.endSoc, 5) ?? 0,
        'vehicle_model': _vehicleModel,
        if (_countryCode != null) 'country': _countryCode!,
      };

      await _analytics?.logEvent(
        name: 'charging_session',
        parameters: params,
      );

      await _firestore?.collection('contributions').add({
        'type': 'charging',
        'device_id': _anonymousDeviceId,
        'timestamp': FieldValue.serverTimestamp(),
        ...params,
      });

      _logger.log('[FleetAnalytics] Recorded charging session: ${session.chargingType}, ${energyBucket}kWh');
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to record charging session: $e');
    }
  }

  /// Record driving efficiency metrics (anonymous, bucketed)
  Future<void> recordDrivingMetrics(VehicleData data) async {
    if (!isEnabled) return;

    // Rate limiting
    final now = DateTime.now();
    if (_lastDrivingUpload != null &&
        now.difference(_lastDrivingUpload!) < _drivingUploadInterval) {
      return;
    }
    _lastDrivingUpload = now;

    // Only record when driving (speed > 0)
    if (data.speed == null || data.speed! <= 0) return;

    try {
      final speedBucket = _bucketValue(data.speed, 10);
      final powerBucket = _bucketValue(data.power?.abs(), 10);
      final tempRange = _getTemperatureRange(data.batteryTemperature);

      final params = <String, Object>{
        'speed_bucket': speedBucket ?? 0,
        'power_bucket': powerBucket ?? 0,
        'temp_range': tempRange,
        'vehicle_model': _vehicleModel,
        if (_countryCode != null) 'country': _countryCode!,
      };

      await _analytics?.logEvent(
        name: 'driving_snapshot',
        parameters: params,
      );

      // Don't write driving snapshots to Firestore - too frequent
      // Just use Analytics for aggregate trends

      _logger.log('[FleetAnalytics] Recorded driving metrics: ${speedBucket}km/h, ${powerBucket}kW');
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to record driving metrics: $e');
    }
  }

  /// Get fleet statistics from Firestore
  Future<FleetStats?> getFleetStats() async {
    if (_firestore == null) return null;

    try {
      final doc = await _firestore!.collection('fleet_stats').doc('current').get();
      if (!doc.exists) return null;

      return FleetStats.fromFirestore(doc.data()!);
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to get fleet stats: $e');
      return null;
    }
  }

  /// Bucket a value to the nearest increment (for anonymity)
  int? _bucketValue(double? value, int increment) {
    if (value == null) return null;
    return ((value / increment).round() * increment).toInt();
  }

  /// Get temperature range category
  String _getTemperatureRange(double? temp) {
    if (temp == null) return 'unknown';
    if (temp < 10) return 'cold';
    if (temp < 25) return 'normal';
    if (temp < 35) return 'warm';
    return 'hot';
  }
}

/// Fleet statistics data model
class FleetStats {
  final int totalContributors;
  final double avgSoh;
  final double avgChargingPowerAc;
  final double avgChargingPowerDc;
  final Map<String, int> sohDistribution;
  final Map<String, int> chargingTypeDistribution;
  final Map<String, int> countryDistribution;
  final DateTime lastUpdated;

  FleetStats({
    required this.totalContributors,
    required this.avgSoh,
    required this.avgChargingPowerAc,
    required this.avgChargingPowerDc,
    required this.sohDistribution,
    required this.chargingTypeDistribution,
    required this.countryDistribution,
    required this.lastUpdated,
  });

  factory FleetStats.fromFirestore(Map<String, dynamic> data) {
    return FleetStats(
      totalContributors: data['total_contributors'] ?? 0,
      avgSoh: (data['avg_soh'] ?? 0).toDouble(),
      avgChargingPowerAc: (data['avg_charging_power_ac'] ?? 0).toDouble(),
      avgChargingPowerDc: (data['avg_charging_power_dc'] ?? 0).toDouble(),
      sohDistribution: Map<String, int>.from(data['soh_distribution'] ?? {}),
      chargingTypeDistribution: Map<String, int>.from(data['charging_type_distribution'] ?? {}),
      countryDistribution: Map<String, int>.from(data['country_distribution'] ?? {}),
      lastUpdated: (data['last_updated'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
