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
import 'hive_storage_service.dart';

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

  // Debug getters for troubleshooting
  bool get rawIsEnabled => _isEnabled;
  bool get rawConsentGiven => _consentGiven;

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
    // Try Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable && _countryCode != null) {
      await hive.saveSetting('fleet_analytics_country', _countryCode!);
      await hive.saveSetting('fleet_analytics_country_timestamp',
          _lastCountryLookup?.millisecondsSinceEpoch ?? 0);
      return;
    }

    // Fallback to SharedPreferences
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
    // Try Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      _countryCode = hive.getSetting<String>('fleet_analytics_country');
      final timestamp = hive.getSetting<int>('fleet_analytics_country_timestamp');
      if (timestamp != null) {
        _lastCountryLookup = DateTime.fromMillisecondsSinceEpoch(timestamp);
      }
      if (_countryCode != null) return;
    }

    // Fallback to SharedPreferences
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
    _logger.log('[FleetAnalytics] configure() called: enabled=$enabled, consentGiven=$consentGiven');
    _isEnabled = enabled;
    if (consentGiven != null) {
      _consentGiven = consentGiven;
    }
    if (vehicleModel != null) {
      _vehicleModel = vehicleModel;
    }
    await _saveSettings();
    _logger.log('[FleetAnalytics] After configure: _isEnabled=$_isEnabled, _consentGiven=$_consentGiven, isEnabled=$isEnabled');
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
  /// Tries Hive first, then SharedPreferences, then file fallback
  Future<void> _loadSettings() async {
    bool hiveLoaded = false;
    bool prefsLoaded = false;
    bool fileLoaded = false;
    bool hiveEnabled = false;
    bool hiveConsent = false;
    bool prefsEnabled = false;
    bool prefsConsent = false;
    bool fileEnabled = false;
    bool fileConsent = false;

    // Try Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      hiveEnabled = hive.getSetting<bool>('fleet_analytics_enabled') ?? false;
      hiveConsent = hive.getSetting<bool>('fleet_analytics_consent') ?? false;
      _anonymousDeviceId = hive.getSetting<String>('fleet_analytics_device_id');
      _vehicleModel = hive.getSetting<String>('vehicle_model') ?? 'G6';
      hiveLoaded = true;
      _logger.log('[FleetAnalytics] Hive loaded: enabled=$hiveEnabled, consent=$hiveConsent, deviceId=${_anonymousDeviceId != null}');
    }

    // Also try SharedPreferences (fallback)
    try {
      final prefs = await SharedPreferences.getInstance();
      prefsEnabled = prefs.getBool('fleet_analytics_enabled') ?? false;
      prefsConsent = prefs.getBool('fleet_analytics_consent') ?? false;
      if (_anonymousDeviceId == null) {
        _anonymousDeviceId = prefs.getString('fleet_analytics_device_id');
      }
      if (_vehicleModel == 'G6') {
        _vehicleModel = prefs.getString('vehicle_model') ?? 'G6';
      }
      prefsLoaded = true;
      _logger.log('[FleetAnalytics] SharedPrefs loaded: enabled=$prefsEnabled, consent=$prefsConsent, deviceId=${_anonymousDeviceId != null}');
    } catch (e) {
      _logger.log('[FleetAnalytics] SharedPreferences failed: $e');
    }

    // Also try file fallback (AAOS compatibility)
    try {
      final file = await _getSettingsFile();
      _logger.log('[FleetAnalytics] Checking file: ${file.path}');
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        fileEnabled = json['enabled'] ?? false;
        fileConsent = json['consent'] ?? false;
        if (_anonymousDeviceId == null) {
          _anonymousDeviceId = json['device_id'];
        }
        if (_vehicleModel == 'G6') {
          _vehicleModel = json['vehicle_model'] ?? 'G6';
        }
        fileLoaded = true;
        _logger.log('[FleetAnalytics] File loaded: enabled=$fileEnabled, consent=$fileConsent');
      } else {
        _logger.log('[FleetAnalytics] File does not exist yet');
      }
    } catch (e) {
      _logger.log('[FleetAnalytics] File fallback failed: $e');
    }

    // Use whichever source has it enabled (OR logic - if any has it enabled, use that)
    _isEnabled = hiveEnabled || prefsEnabled || fileEnabled;
    _consentGiven = hiveConsent || prefsConsent || fileConsent;

    final deviceIdPreview = _anonymousDeviceId != null && _anonymousDeviceId!.length >= 8
        ? '${_anonymousDeviceId!.substring(0, 8)}...'
        : _anonymousDeviceId ?? 'null';
    _logger.log('[FleetAnalytics] Final settings: enabled=$_isEnabled, consent=$_consentGiven, deviceId=$deviceIdPreview');
    _logger.log('[FleetAnalytics] Sources: hive=$hiveLoaded, prefs=$prefsLoaded, file=$fileLoaded');

    // Generate anonymous device ID if not exists
    if (_anonymousDeviceId == null) {
      _anonymousDeviceId = _generateAnonymousId();
      _logger.log('[FleetAnalytics] Generated new device ID');
    }

    // Sync settings to both storage locations if there was a mismatch
    if (prefsLoaded && fileLoaded && (prefsEnabled != fileEnabled || prefsConsent != fileConsent)) {
      _logger.log('[FleetAnalytics] Mismatch detected, syncing settings');
      await _saveSettings();
    } else if (_isEnabled || _consentGiven) {
      // Ensure settings are persisted
      await _saveSettings();
    }

    // Load cached country code
    await _loadCountryCode();
  }

  /// Save settings to storage (saves to Hive, SharedPreferences, and file for redundancy)
  Future<void> _saveSettings() async {
    _logger.log('[FleetAnalytics] Saving settings: enabled=$_isEnabled, consent=$_consentGiven');

    // Save to Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting('fleet_analytics_enabled', _isEnabled);
      await hive.saveSetting('fleet_analytics_consent', _consentGiven);
      if (_anonymousDeviceId != null) {
        await hive.saveSetting('fleet_analytics_device_id', _anonymousDeviceId!);
      }
      _logger.log('[FleetAnalytics] Settings saved to Hive');
    }

    // Also save to SharedPreferences as backup
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('fleet_analytics_enabled', _isEnabled);
      await prefs.setBool('fleet_analytics_consent', _consentGiven);
      if (_anonymousDeviceId != null) {
        await prefs.setString('fleet_analytics_device_id', _anonymousDeviceId!);
      }
      _logger.log('[FleetAnalytics] Settings saved to SharedPreferences');
    } catch (e) {
      _logger.log('[FleetAnalytics] SharedPreferences save failed: $e');
    }

    // Also save to file (AAOS compatibility - always save to both)
    await _saveSettingsToFile();
  }

  /// Save settings to file (AAOS fallback)
  /// Uses application documents directory which persists across app restarts
  Future<void> _saveSettingsToFile() async {
    try {
      final file = await _getSettingsFile();
      await file.writeAsString(jsonEncode({
        'enabled': _isEnabled,
        'consent': _consentGiven,
        'device_id': _anonymousDeviceId,
        'vehicle_model': _vehicleModel,
      }));
      _logger.log('[FleetAnalytics] Settings saved to file: ${file.path}');
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to save settings to file: $e');
    }
  }

  /// Get settings file path with AAOS fallback
  Future<File> _getSettingsFile() async {
    // 1. Try hardcoded internal app storage FIRST (works on AI boxes!)
    // This is the same approach that OBDService uses successfully
    const internalPaths = [
      '/data/data/com.example.carsoc/files/fleet_analytics_settings.json',
      '/data/data/com.stevelea.carsoc/files/fleet_analytics_settings.json',
      '/data/user/0/com.example.carsoc/files/fleet_analytics_settings.json',
      '/data/user/0/com.stevelea.carsoc/files/fleet_analytics_settings.json',
    ];

    for (final path in internalPaths) {
      try {
        final file = File(path);
        final parentDir = file.parent;
        if (await parentDir.exists()) {
          _logger.log('[FleetAnalytics] Using internal path: $path');
          return file;
        }
      } catch (e) {
        // Continue to next path
      }
    }

    // 2. Try path_provider (works on normal devices)
    try {
      final directory = await getExternalStorageDirectory();
      if (directory != null) {
        return File('${directory.path}/fleet_analytics_settings.json');
      }
    } catch (e) {
      _logger.log('[FleetAnalytics] getExternalStorageDirectory failed: $e');
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      return File('${directory.path}/fleet_analytics_settings.json');
    } catch (e) {
      _logger.log('[FleetAnalytics] getApplicationDocumentsDirectory failed: $e');
    }

    // 3. Try cache directory (often accessible when others aren't)
    try {
      final directory = await getTemporaryDirectory();
      _logger.log('[FleetAnalytics] Using temp directory: ${directory.path}');
      return File('${directory.path}/fleet_analytics_settings.json');
    } catch (e) {
      _logger.log('[FleetAnalytics] getTemporaryDirectory failed: $e');
    }

    // 4. AAOS ultimate fallback: use /sdcard which is usually accessible
    const fallbackPaths = [
      '/sdcard/Android/data/com.stevelea.carsoc/files/fleet_analytics_settings.json',
      '/storage/emulated/0/Android/data/com.stevelea.carsoc/files/fleet_analytics_settings.json',
    ];

    for (final fallbackPath in fallbackPaths) {
      try {
        _logger.log('[FleetAnalytics] Trying fallback path: $fallbackPath');
        final file = File(fallbackPath);
        final parent = file.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
        // Test if we can write
        await file.writeAsString('{}');
        _logger.log('[FleetAnalytics] Fallback path works: $fallbackPath');
        return file;
      } catch (e) {
        _logger.log('[FleetAnalytics] Fallback path failed: $fallbackPath - $e');
      }
    }

    // Last resort: return a path that will likely fail but log clearly
    _logger.log('[FleetAnalytics] ERROR: No accessible file path found for settings storage');
    return File('/tmp/fleet_analytics_settings.json');
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
      _logger.log('[FleetAnalytics] Logging battery_snapshot to Analytics...');
      await _analytics?.logEvent(
        name: 'battery_snapshot',
        parameters: params,
      );
      _logger.log('[FleetAnalytics] Analytics event logged');

      // Write to Firestore for aggregation (separate try-catch so Analytics still works)
      if (_firestore != null) {
        try {
          final docRef = await _firestore!.collection('contributions').add({
            'type': 'battery',
            'device_id': _anonymousDeviceId,
            'timestamp': FieldValue.serverTimestamp(),
            ...params,
          });
          _logger.log('[FleetAnalytics] Firestore write success: ${docRef.id}');
        } catch (firestoreError) {
          _logger.log('[FleetAnalytics] Firestore write failed (permission denied?): $firestoreError');
        }
      }

      _logger.log('[FleetAnalytics] Recorded battery metrics: SOC=$socBucket%, SOH=$sohBucket%');
    } catch (e, stackTrace) {
      _logger.log('[FleetAnalytics] Failed to record battery metrics: $e');
      _logger.log('[FleetAnalytics] Stack trace: $stackTrace');
    }
  }

  /// Record charging session (anonymous, bucketed)
  Future<void> recordChargingSession(ChargingSession session) async {
    _logger.log('[FleetAnalytics] recordChargingSession called, isEnabled: $isEnabled');
    if (!isEnabled) {
      _logger.log('[FleetAnalytics] Skipping - not enabled (enabled=$_isEnabled, consent=$_consentGiven)');
      return;
    }

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

      _logger.log('[FleetAnalytics] Logging charging_session to Analytics...');
      await _analytics?.logEvent(
        name: 'charging_session',
        parameters: params,
      );
      _logger.log('[FleetAnalytics] Analytics event logged');

      // Write to Firestore for aggregation (separate try-catch so Analytics still works)
      if (_firestore != null) {
        try {
          final docRef = await _firestore!.collection('contributions').add({
            'type': 'charging',
            'device_id': _anonymousDeviceId,
            'timestamp': FieldValue.serverTimestamp(),
            ...params,
          });
          _logger.log('[FleetAnalytics] Firestore write success: ${docRef.id}');
        } catch (firestoreError) {
          _logger.log('[FleetAnalytics] Firestore write failed (permission denied?): $firestoreError');
        }
      }

      _logger.log('[FleetAnalytics] Recorded charging session: ${session.chargingType}, ${energyBucket}kWh');
    } catch (e, stackTrace) {
      _logger.log('[FleetAnalytics] Failed to record charging session: $e');
      _logger.log('[FleetAnalytics] Stack trace: $stackTrace');
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
  /// First tries pre-aggregated stats, then falls back to computing from contributions
  /// Note: This works even if Fleet Analytics is disabled - viewing stats is always allowed
  Future<FleetStats?> getFleetStats() async {
    // Ensure Firestore is initialized (viewing stats is allowed even if contribution is disabled)
    if (_firestore == null) {
      _logger.log('[FleetAnalytics] getFleetStats: Firestore is null, attempting to initialize...');
      try {
        _firestore = FirebaseFirestore.instance;
        _logger.log('[FleetAnalytics] Firestore initialized for stats query');
      } catch (e) {
        _logger.log('[FleetAnalytics] Failed to initialize Firestore: $e');
        return null;
      }
    }

    try {
      _logger.log('[FleetAnalytics] Fetching fleet stats...');

      // First, try to get pre-aggregated stats (from Cloud Function if available)
      final doc = await _firestore!.collection('fleet_stats').doc('current').get();
      if (doc.exists && doc.data() != null) {
        _logger.log('[FleetAnalytics] Got pre-aggregated fleet stats');
        return FleetStats.fromFirestore(doc.data()!);
      }

      // Fallback: compute stats from contributions collection
      _logger.log('[FleetAnalytics] No pre-aggregated stats, computing from contributions...');
      return await _computeStatsFromContributions();
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to get fleet stats: $e');
      return null;
    }
  }

  /// Compute fleet statistics from contributions collection (client-side fallback)
  Future<FleetStats?> _computeStatsFromContributions() async {
    if (_firestore == null) {
      _logger.log('[FleetAnalytics] _computeStatsFromContributions: Firestore is null');
      return null;
    }

    try {
      // Get recent contributions (simplified query to avoid composite index requirement)
      // Filter by type client-side to avoid needing a composite index on type + timestamp
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      _logger.log('[FleetAnalytics] Querying contributions since ${cutoff.toIso8601String()}...');

      _logger.log('[FleetAnalytics] Executing Firestore query...');
      final allDocs = await _firestore!
          .collection('contributions')
          .orderBy('timestamp', descending: true)
          .limit(1000)
          .get();

      _logger.log('[FleetAnalytics] Query complete. Got ${allDocs.docs.length} total contributions');

      // Filter by type and date client-side
      final cutoffTimestamp = Timestamp.fromDate(cutoff);
      final batteryDocs = allDocs.docs.where((doc) {
        final data = doc.data();
        final type = data['type'] as String?;
        final timestamp = data['timestamp'] as Timestamp?;
        return type == 'battery' && timestamp != null && timestamp.compareTo(cutoffTimestamp) > 0;
      }).toList();

      final chargingDocs = allDocs.docs.where((doc) {
        final data = doc.data();
        final type = data['type'] as String?;
        final timestamp = data['timestamp'] as Timestamp?;
        return type == 'charging' && timestamp != null && timestamp.compareTo(cutoffTimestamp) > 0;
      }).toList();

      _logger.log('[FleetAnalytics] Found ${batteryDocs.length} battery, ${chargingDocs.length} charging contributions (after filtering)');

      if (batteryDocs.isEmpty && chargingDocs.isEmpty) {
        _logger.log('[FleetAnalytics] No contributions found in last 7 days');
        return null;
      }

      // Calculate SOH stats
      final Set<String> uniqueDevices = {};
      final Map<String, int> sohDistribution = {};
      double sohSum = 0;
      int sohCount = 0;

      for (final doc in batteryDocs) {
        final data = doc.data();
        final deviceId = data['device_id'] as String?;
        if (deviceId != null) uniqueDevices.add(deviceId);

        final sohBucket = data['soh_bucket'];
        if (sohBucket != null && sohBucket is int && sohBucket > 0) {
          final key = sohBucket.toString();
          sohDistribution[key] = (sohDistribution[key] ?? 0) + 1;
          sohSum += sohBucket;
          sohCount++;
        }
      }

      // Calculate charging stats
      final Map<String, int> chargingTypeDistribution = {};
      double acPowerSum = 0;
      int acPowerCount = 0;
      double dcPowerSum = 0;
      int dcPowerCount = 0;
      final Map<String, int> countryDistribution = {};

      for (final doc in chargingDocs) {
        final data = doc.data();
        final deviceId = data['device_id'] as String?;
        if (deviceId != null) uniqueDevices.add(deviceId);

        final chargingType = data['charging_type'] as String? ?? 'unknown';
        chargingTypeDistribution[chargingType] = (chargingTypeDistribution[chargingType] ?? 0) + 1;

        final powerBucket = data['power_kw_bucket'];
        if (powerBucket != null && powerBucket is int) {
          if (chargingType == 'ac') {
            acPowerSum += powerBucket;
            acPowerCount++;
          } else if (chargingType == 'dc') {
            dcPowerSum += powerBucket;
            dcPowerCount++;
          }
        }

        final country = data['country'] as String?;
        if (country != null) {
          countryDistribution[country] = (countryDistribution[country] ?? 0) + 1;
        }
      }

      // Also count countries from battery contributions
      for (final doc in batteryDocs) {
        final data = doc.data();
        final country = data['country'] as String?;
        if (country != null) {
          countryDistribution[country] = (countryDistribution[country] ?? 0) + 1;
        }
      }

      final avgSoh = sohCount > 0 ? sohSum / sohCount : 0.0;
      final avgAcPower = acPowerCount > 0 ? acPowerSum / acPowerCount : 0.0;
      final avgDcPower = dcPowerCount > 0 ? dcPowerSum / dcPowerCount : 0.0;
      final totalContributions = batteryDocs.length + chargingDocs.length;

      _logger.log('[FleetAnalytics] Computed stats: ${uniqueDevices.length} contributors, $totalContributions contributions, avg SOH: ${avgSoh.toStringAsFixed(1)}%');

      return FleetStats(
        totalContributors: uniqueDevices.length,
        totalContributions: totalContributions,
        avgSoh: avgSoh,
        avgChargingPowerAc: avgAcPower,
        avgChargingPowerDc: avgDcPower,
        sohDistribution: sohDistribution,
        chargingTypeDistribution: chargingTypeDistribution,
        countryDistribution: countryDistribution,
        lastUpdated: DateTime.now(),
      );
    } catch (e) {
      _logger.log('[FleetAnalytics] Failed to compute stats from contributions: $e');
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
  final int totalContributions;
  final double avgSoh;
  final double avgChargingPowerAc;
  final double avgChargingPowerDc;
  final Map<String, int> sohDistribution;
  final Map<String, int> chargingTypeDistribution;
  final Map<String, int> countryDistribution;
  final DateTime lastUpdated;

  FleetStats({
    required this.totalContributors,
    required this.totalContributions,
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
      totalContributions: data['total_contributions'] ?? 0,
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
