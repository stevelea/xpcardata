import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vehicle_data.dart';
import '../models/obd_pid_config.dart';
import 'car_info_service.dart';
import 'obd_service.dart';
import 'obd_proxy_service.dart';
import 'database_service.dart';
import 'mqtt_service.dart';
import 'abrp_service.dart';
import 'car_app_bridge.dart';
import 'charging_session_service.dart';
import 'native_location_service.dart';
import 'fleet_analytics_service.dart';
import 'mock_data_service.dart';
import 'debug_logger.dart';
import 'hive_storage_service.dart';
import 'keep_alive_service.dart';
import 'background_service.dart';

/// Data source types available
enum DataSource {
  carInfo,  // Android Automotive CarInfo API (primary for AAOS)
  obd,      // OBD-II Bluetooth adapter
  proxy,    // Intercepted data from OBD proxy (external app querying)
  mock,     // Mock data for testing without car connection
}

/// Manages vehicle data collection from multiple sources with intelligent fallback
class DataSourceManager {
  final CarInfoService _carInfoService;
  final OBDService _obdService;
  final MqttService? _mqttService;
  final AbrpService _abrpService = AbrpService();
  final NativeLocationService _locationService = NativeLocationService.instance;
  final FleetAnalyticsService _fleetAnalyticsService = FleetAnalyticsService.instance;
  late final ChargingSessionService _chargingSessionService;
  final _logger = DebugLogger.instance;

  DataSource? _currentSource;
  StreamSubscription<VehicleData>? _dataSubscription;
  StreamSubscription<dynamic>? _chargingSessionSubscription;

  // Proxy interception state
  VehicleData? _proxyVehicleData;
  Timer? _proxyPublishTimer;

  // Location tracking
  bool _locationEnabled = false;

  // Left-hand drive layout (driver on left, infotainment on right)
  // In LHD countries, we reverse the dashboard layout so important info is closer to driver
  bool _isLeftHandDrive = true; // Default to LHD (most common worldwide)

  // 12V battery protection
  bool _auxBatteryProtectionEnabled = true;
  double _auxBatteryProtectionThreshold = 12.8;
  bool _auxBatteryProtectionActive = false; // Currently paused due to low 12V
  static const double _auxBatteryHysteresis = 0.3; // Resume when voltage rises above threshold + hysteresis

  final StreamController<VehicleData> _dataController =
      StreamController<VehicleData>.broadcast();

  final StreamController<DataSource> _sourceController =
      StreamController<DataSource>.broadcast();

  DataSourceManager({
    CarInfoService? carInfoService,
    OBDService? obdService,
    MqttService? mqttService,
  })  : _carInfoService = carInfoService ?? CarInfoService(),
        _obdService = obdService ?? OBDService(),
        _mqttService = mqttService {
    _chargingSessionService = ChargingSessionService(mqttService: mqttService);
    _setupProxyInterception();
    _setupChargingSessionListener();
  }

  /// Setup listener for charging session completion to send to fleet analytics
  void _setupChargingSessionListener() {
    _chargingSessionSubscription = _chargingSessionService.sessionStream.listen(
      (session) {
        _logger.log('[DataSourceManager] Received charging session: ${session.id}, endTime: ${session.endTime}');
        // Record completed charging session to fleet analytics
        if (session.endTime != null) {
          if (_fleetAnalyticsService.isEnabled) {
            _logger.log('[DataSourceManager] Sending to fleet analytics');
            _fleetAnalyticsService.recordChargingSession(session);
          } else {
            _logger.log('[DataSourceManager] Fleet analytics disabled, not sending');
          }
        }
      },
    );
  }

  /// Get ABRP service for configuration
  AbrpService get abrpService => _abrpService;

  /// Get charging session service for monitoring
  ChargingSessionService get chargingSessionService => _chargingSessionService;

  /// Get location service for configuration
  NativeLocationService get locationService => _locationService;

  /// Check if location tracking is enabled
  bool get isLocationEnabled => _locationEnabled;

  /// Check if left-hand drive layout is enabled
  /// LHD = driver on left, so dashboard should show key info on the left side
  bool get isLeftHandDrive => _isLeftHandDrive;

  /// Check if 12V battery protection is currently active (polling paused)
  bool get isAuxBatteryProtectionActive => _auxBatteryProtectionActive;

  /// Validate and sanitize vehicle data, nullifying out-of-range values
  VehicleData _sanitizeData(VehicleData data) {
    if (data.stateOfCharge != null && data.stateOfCharge! > 100.0) {
      _logger.log('[DataSourceManager] BAD DATA: SOC ${data.stateOfCharge}% > 100%, discarding value');
      return data.copyWith(stateOfCharge: null);
    }
    return data;
  }

  /// Stream of vehicle data from current active source
  Stream<VehicleData> get vehicleDataStream => _dataController.stream;

  /// Stream of data source changes
  Stream<DataSource> get dataSourceStream => _sourceController.stream;

  /// Current active data source
  DataSource? get currentSource => _currentSource;

  /// Check if CarInfo API is available
  bool get isCarInfoAvailable => _carInfoService.isAvailable;

  /// Check if OBD is connected
  bool get isObdConnected => _obdService.isConnected;

  /// Get OBD service instance
  OBDService get obdService => _obdService;

  /// Setup proxy interception for PID data
  void _setupProxyInterception() {
    final proxyService = OBDProxyService.instance;

    // Set PIDs to intercept from the OBD service's configured PIDs
    proxyService.onPIDIntercepted = _handleInterceptedPID;

    // Monitor proxy status changes
    proxyService.onStatusChanged = (isRunning, clientAddress) {
      if (isRunning && clientAddress != null) {
        // Proxy client connected - switch to proxy source
        _logger.log('[DataSourceManager] Proxy client connected, switching to proxy source');
        _activateProxySource();
      } else if (isRunning && clientAddress == null && _currentSource == DataSource.proxy) {
        // Proxy client disconnected - switch back to OBD if connected
        _logger.log('[DataSourceManager] Proxy client disconnected');
        if (_obdService.isConnected) {
          _activateDataSource(DataSource.obd);
        }
      }
    };
  }

  /// Configure PIDs for proxy interception (call after loading vehicle profile)
  void configureProxyInterception(List<OBDPIDConfig> pids) {
    final proxyService = OBDProxyService.instance;
    proxyService.setInterceptPIDs(pids);
    _logger.log('[DataSourceManager] Configured ${pids.length} PIDs for proxy interception');
  }

  /// Handle intercepted PID data from proxy
  void _handleInterceptedPID(String pidName, double value, String rawResponse) {
    _logger.log('[DataSourceManager] Intercepted PID: $pidName = $value');

    // Initialize proxy vehicle data if needed
    _proxyVehicleData ??= VehicleData(timestamp: DateTime.now());

    // Update the appropriate field based on PID name
    final nameLower = pidName.toLowerCase();
    final nameUpper = pidName.toUpperCase();

    if (nameLower == 'soc' || nameLower.contains('state of charge')) {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        stateOfCharge: value,
        timestamp: DateTime.now(),
      );
    } else if (nameLower == 'soh' || nameLower.contains('health')) {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        stateOfHealth: value,
        timestamp: DateTime.now(),
      );
    } else if (nameUpper == 'HV_V' || nameLower.contains('voltage')) {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        batteryVoltage: value,
        timestamp: DateTime.now(),
      );
    } else if (nameUpper == 'HV_A' || nameLower.contains('current')) {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        batteryCurrent: value,
        timestamp: DateTime.now(),
      );
    } else if (nameUpper == 'HV_T_MAX' || (nameLower.contains('temp') && nameLower.contains('max'))) {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        batteryTemperature: value,
        timestamp: DateTime.now(),
      );
    } else if (nameLower == 'speed') {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        speed: value,
        timestamp: DateTime.now(),
      );
    } else if (nameLower == 'odometer') {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        odometer: value,
        timestamp: DateTime.now(),
      );
    } else if (nameUpper == 'RANGE_EST' || nameLower.contains('range')) {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        range: value,
        timestamp: DateTime.now(),
      );
    } else if (nameLower == 'cumulative charge') {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        cumulativeCharge: value,
        timestamp: DateTime.now(),
      );
    } else if (nameLower == 'cumulative discharge') {
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        cumulativeDischarge: value,
        timestamp: DateTime.now(),
      );
    } else {
      // Store in additional properties
      final additionalProps = Map<String, dynamic>.from(
        _proxyVehicleData!.additionalProperties ?? {},
      );
      additionalProps[pidName] = value;
      _proxyVehicleData = _proxyVehicleData!.copyWith(
        additionalProperties: additionalProps,
        timestamp: DateTime.now(),
      );
    }

    // Schedule a publish to batch updates
    _scheduleProxyPublish();
  }

  /// Schedule proxy data publish (batches rapid updates)
  void _scheduleProxyPublish() {
    _proxyPublishTimer?.cancel();
    _proxyPublishTimer = Timer(const Duration(milliseconds: 500), () {
      if (_proxyVehicleData != null && _currentSource == DataSource.proxy) {
        _publishProxyData(_proxyVehicleData!);
      }
    });
  }

  /// Publish proxy-intercepted data
  void _publishProxyData(VehicleData data) {
    final enrichedData = _sanitizeData(_enrichWithLocation(data));
    _dataController.add(enrichedData);
    _saveData(enrichedData);
    _publishToMqtt(enrichedData);
    _publishToAbrp(enrichedData);
    _publishToFleetAnalytics(enrichedData);
    _sendToAndroidAuto(enrichedData);
    _processChargingData(enrichedData);
    _updateStatusBarNotification(enrichedData);
    // Pulse keep-alive to prove app is active
    KeepAliveService.instance.pulse();
  }

  /// Activate proxy data source
  void _activateProxySource() {
    _logger.log('[DataSourceManager] Activating proxy data source');

    // Pause OBD polling if active
    if (_currentSource == DataSource.obd) {
      _obdService.pausePolling();
    }

    _currentSource = DataSource.proxy;
    _sourceController.add(DataSource.proxy);

    // Initialize with empty data
    _proxyVehicleData = VehicleData(timestamp: DateTime.now());
  }

  /// Initialize and determine best data source
  Future<DataSource?> initialize() async {
    _logger.log('[DataSourceManager] Initializing...');

    // Load PIDs for proxy interception
    await _loadPIDsForProxyInterception();

    // Load 12V battery protection settings
    await restoreAuxBatteryProtectionSettings();

    // Auto-select best available source
    _logger.log('[DataSourceManager] Auto-selecting best data source...');
    final selectedSource = await selectDataSource();

    if (selectedSource != null) {
      _logger.log('[DataSourceManager] Selected source: ${getSourceName(selectedSource)}');
      await _activateDataSource(selectedSource);
    } else {
      _logger.log('[DataSourceManager] No data source available');
    }

    return selectedSource;
  }

  /// Load PIDs from SharedPreferences and configure proxy interception
  Future<void> _loadPIDsForProxyInterception() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pidsJson = prefs.getString('custom_pids');

      if (pidsJson != null && pidsJson.isNotEmpty) {
        final List<dynamic> pidList = json.decode(pidsJson);
        final pids = pidList
            .map((p) => OBDPIDConfig.fromJson(p as Map<String, dynamic>))
            .toList();

        if (pids.isNotEmpty) {
          configureProxyInterception(pids);
          _logger.log('[DataSourceManager] Loaded ${pids.length} PIDs for proxy interception');
        }
      } else {
        _logger.log('[DataSourceManager] No PIDs found in SharedPreferences for proxy interception');
      }
    } catch (e) {
      _logger.log('[DataSourceManager] Error loading PIDs for proxy interception: $e');
    }
  }

  /// Select best available data source
  Future<DataSource?> selectDataSource() async {
    // 0. Check if mock data mode is enabled (takes priority for testing)
    if (MockDataService.instance.isEnabled) {
      _logger.log('[DataSourceManager] ✓ Mock data mode is enabled!');
      return DataSource.mock;
    }

    // 1. Try CarInfo API first (best for AAOS / Android Auto)
    try {
      _logger.log('[DataSourceManager] Trying CarInfo API...');
      final isCarInfoAvailable = await _carInfoService.initialize();
      if (isCarInfoAvailable) {
        _logger.log('[DataSourceManager] ✓ CarInfo API is available!');
        return DataSource.carInfo;
      } else {
        _logger.log('[DataSourceManager] ✗ CarInfo API returned false');
      }
    } catch (e) {
      // CarInfo not available, continue to fallback
      _logger.log('[DataSourceManager] ✗ CarInfo API exception: $e');
    }

    // 2. Try OBD-II
    if (_obdService.isConnected) {
      _logger.log('[DataSourceManager] ✓ OBD-II is connected!');
      return DataSource.obd;
    } else {
      _logger.log('[DataSourceManager] ✗ OBD-II not connected');
    }

    // 3. No data source available
    _logger.log('[DataSourceManager] No data source available - connect OBD or use CarInfo API');
    return null;
  }

  /// Activate a specific data source
  Future<void> _activateDataSource(DataSource source) async {
    _logger.log('[DataSourceManager] Activating data source: ${getSourceName(source)}');

    // Stop current source if any
    await _stopCurrentSource();

    _currentSource = source;
    _sourceController.add(source);

    // Start new source
    switch (source) {
      case DataSource.carInfo:
        _logger.log('[DataSourceManager] Starting CarInfo data stream...');
        await _startCarInfoSource();
        break;
      case DataSource.obd:
        _logger.log('[DataSourceManager] Starting OBD-II data stream...');
        _obdService.resumePolling();
        _startObdSource();
        break;
      case DataSource.proxy:
        // Proxy source is activated separately via _activateProxySource
        _logger.log('[DataSourceManager] Proxy source activated');
        break;
      case DataSource.mock:
        _logger.log('[DataSourceManager] Starting mock data stream...');
        _startMockSource();
        break;
    }
  }

  /// Start mock data source
  void _startMockSource() {
    final mockService = MockDataService.instance;
    _dataSubscription = mockService.vehicleDataStream.listen(
      (data) {
        _dataController.add(data);
        // Don't save mock data to database or publish to external services
        _logger.log('[DataSourceManager] Mock data: SOC=${data.stateOfCharge?.toStringAsFixed(1)}%');
      },
      onError: (error) {
        _logger.log('[DataSourceManager] Mock data error: $error');
      },
    );
  }

  /// Start CarInfo API data source
  Future<void> _startCarInfoSource() async {
    _dataSubscription = _carInfoService.vehicleDataStream.listen(
      (data) {
        final enrichedData = _sanitizeData(_enrichWithLocation(data));
        _dataController.add(enrichedData);
        _saveData(enrichedData);
        _publishToMqtt(enrichedData);
        _publishToAbrp(enrichedData);
        _publishToFleetAnalytics(enrichedData);
        _sendToAndroidAuto(enrichedData);
        _processChargingData(enrichedData);
        _updateStatusBarNotification(enrichedData);
      },
      onError: (error) {
        // On error, try to fall back to another source
        _handleSourceError(DataSource.carInfo);
      },
    );
  }

  /// Start OBD-II data source
  void _startObdSource() {
    _dataSubscription = _obdService.vehicleDataStream.listen(
      (data) {
        final enrichedData = _sanitizeData(_enrichWithLocation(data));
        _dataController.add(enrichedData);
        _saveData(enrichedData);
        _publishToMqtt(enrichedData);
        _publishToAbrp(enrichedData);
        _publishToFleetAnalytics(enrichedData);
        _sendToAndroidAuto(enrichedData);
        _processChargingData(enrichedData);
        _updateStatusBarNotification(enrichedData);
        _checkAuxBatteryProtection(enrichedData);
        // Pulse keep-alive to prove app is active
        KeepAliveService.instance.pulse();
      },
      onError: (error) {
        _logger.log('[DataSourceManager] OBD-II error: $error');
        _handleSourceError(DataSource.obd);
      },
    );
  }

  /// Stop current data source
  Future<void> _stopCurrentSource() async {
    await _dataSubscription?.cancel();
    _dataSubscription = null;

    switch (_currentSource) {
      case DataSource.carInfo:
        _carInfoService.stop();
        break;
      case DataSource.obd:
        // OBD service continues running in background
        break;
      case DataSource.proxy:
        _proxyPublishTimer?.cancel();
        _proxyVehicleData = null;
        // Resume OBD polling if connected
        if (_obdService.isConnected) {
          _obdService.resumePolling();
        }
        break;
      case DataSource.mock:
        // Mock service continues running, just stop listening
        break;
      case null:
        break;
    }
  }

  /// Handle data source error by attempting fallback
  Future<void> _handleSourceError(DataSource failedSource) async {
    _logger.log('[DataSourceManager] Data source error: ${getSourceName(failedSource)}');

    // Try to select a different source
    DataSource? fallbackSource;

    switch (failedSource) {
      case DataSource.carInfo:
        // CarInfo failed, try OBD if connected
        if (_obdService.isConnected) {
          fallbackSource = DataSource.obd;
        }
        break;
      case DataSource.obd:
        // OBD failed, try CarInfo if available
        if (_carInfoService.isAvailable) {
          fallbackSource = DataSource.carInfo;
        }
        break;
      case DataSource.proxy:
        // Proxy failed, try OBD if connected
        if (_obdService.isConnected) {
          fallbackSource = DataSource.obd;
        }
        break;
      case DataSource.mock:
        // Mock doesn't fail, but if it did, no fallback needed
        break;
    }

    if (fallbackSource != null) {
      await _activateDataSource(fallbackSource);
    } else {
      _logger.log('[DataSourceManager] No fallback source available');
    }
  }

  /// Save data to database
  void _saveData(VehicleData data) {
    DatabaseService.instance.insertVehicleData(data).catchError((error) {
      // Silently handle database errors
      return 0;
    });
  }

  /// Publish data to MQTT if connected
  void _publishToMqtt(VehicleData data) {
    if (_mqttService != null) {
      if (_mqttService.isConnected) {
        // Include data source in the published data for debugging
        final dataSourceName = _currentSource != null ? getSourceName(_currentSource!) : 'unknown';
        _mqttService.publishVehicleData(data, dataSource: dataSourceName).catchError((error) {
          // Silently handle MQTT publish errors
        });
      }
    }
  }

  /// Publish data to ABRP if enabled
  void _publishToAbrp(VehicleData data) {
    _logger.log('[DataSourceManager] _publishToAbrp called, abrpService.isEnabled=${_abrpService.isEnabled}');
    if (_abrpService.isEnabled) {
      // Determine charging status - must be stationary to distinguish from regen braking
      // Vehicle must be stationary (speed < 1.0 km/h) AND have negative current (charging)
      bool? isCharging;
      final isStationary = data.speed == null || data.speed! < 1.0;

      if (isStationary) {
        // Only consider charging if vehicle is stationary
        if (data.batteryCurrent != null && data.batteryCurrent! < -0.5) {
          // Negative current while stationary = actual charging
          isCharging = true;
        } else if (data.additionalProperties != null) {
          // Fall back to CHARGING PID only when stationary
          final charging = data.additionalProperties!['CHARGING'];
          if (charging != null) {
            isCharging = (charging == 1 || charging == 1.0);
          }
        }
      } else {
        // Vehicle is moving - not charging (could be regen braking)
        isCharging = false;
      }

      _abrpService.sendTelemetry(data, isCharging: isCharging).catchError((error) {
        // Silently handle ABRP errors
        _logger.log('[DataSourceManager] ABRP error: $error');
        return false;
      });
    } else {
      _logger.log('[DataSourceManager] ABRP not enabled, skipping');
    }
  }

  /// Send data to Android Auto display
  void _sendToAndroidAuto(VehicleData data) {
    CarAppBridge.updateVehicleData(data).catchError((error) {
      // Silently handle Android Auto update errors
      return false;
    });
  }

  /// Process vehicle data for charging session detection
  void _processChargingData(VehicleData data) {
    _chargingSessionService.processVehicleData(data);
  }

  /// Update status bar notification with current connection status and vehicle data
  void _updateStatusBarNotification(VehicleData data) {
    final obdConnected = _obdService.isConnected;
    final mqttConnected = _mqttService?.isConnected ?? false;

    // Determine if charging based on current
    bool? isCharging;
    if (data.batteryCurrent != null && data.speed != null && data.speed! < 1.0) {
      isCharging = data.batteryCurrent! < -0.5;
    }

    BackgroundServiceManager.instance.updateStatusNotification(
      obdConnected: obdConnected,
      mqttConnected: mqttConnected,
      soc: data.stateOfCharge,
      power: data.power,
      isCharging: isCharging,
    );
  }

  /// Publish anonymous metrics to fleet analytics if enabled
  void _publishToFleetAnalytics(VehicleData data) {
    if (_fleetAnalyticsService.isEnabled) {
      // Record battery metrics (rate-limited internally)
      _fleetAnalyticsService.recordBatteryMetrics(data);

      // Record driving metrics if moving (rate-limited internally)
      if (data.speed != null && data.speed! > 0) {
        _fleetAnalyticsService.recordDrivingMetrics(data);
      }
    }
  }

  /// Manually switch to a specific data source
  Future<bool> switchToSource(DataSource source) async {
    try {
      // Validate source is available
      switch (source) {
        case DataSource.carInfo:
          if (!_carInfoService.isAvailable) {
            final initialized = await _carInfoService.initialize();
            if (!initialized) return false;
          }
          break;
        case DataSource.obd:
          // Check if OBD is connected
          if (!_obdService.isConnected) return false;
          break;
        case DataSource.proxy:
          // Proxy source requires proxy service running with client
          final proxyService = OBDProxyService.instance;
          if (!proxyService.isRunning || !proxyService.hasClient) return false;
          break;
        case DataSource.mock:
          // Mock is always available when enabled
          if (!MockDataService.instance.isEnabled) return false;
          break;
      }

      await _activateDataSource(source);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Get available data sources
  Future<List<DataSource>> getAvailableSources() async {
    final sources = <DataSource>[];

    // Check mock data availability
    if (MockDataService.instance.isEnabled) {
      sources.add(DataSource.mock);
    }

    // Check CarInfo availability
    if (_carInfoService.isAvailable || await _carInfoService.initialize()) {
      sources.add(DataSource.carInfo);
    }

    // Check OBD availability
    if (_obdService.isConnected) {
      sources.add(DataSource.obd);
    }

    // Check proxy availability
    final proxyService = OBDProxyService.instance;
    if (proxyService.isRunning && proxyService.hasClient) {
      sources.add(DataSource.proxy);
    }

    return sources;
  }

  /// Get data source display name
  static String getSourceName(DataSource source) {
    switch (source) {
      case DataSource.carInfo:
        return 'Android CarInfo API';
      case DataSource.obd:
        return 'OBD-II Adapter';
      case DataSource.proxy:
        return 'OBD Proxy';
      case DataSource.mock:
        return 'Mock Data';
    }
  }

  /// Get data source description
  static String getSourceDescription(DataSource source) {
    switch (source) {
      case DataSource.carInfo:
        return 'Direct access to vehicle data via Android Automotive OS';
      case DataSource.obd:
        return 'Vehicle data from Bluetooth OBD-II adapter';
      case DataSource.proxy:
        return 'Intercepted data from external OBD app via proxy';
      case DataSource.mock:
        return 'Sample data for testing without car connection';
    }
  }

  /// Update the data update frequency (applies to ABRP)
  /// Call this when user changes the setting
  Future<void> updateFrequency(int seconds) async {
    _logger.log('[DataSourceManager] Updating frequency to $seconds seconds');

    // Update ABRP send interval (minimum 5 seconds enforced by ABRP service)
    _abrpService.setUpdateInterval(seconds);
  }

  /// Enable or disable location tracking
  Future<bool> setLocationEnabled(bool enabled) async {
    if (enabled) {
      final initialized = await _locationService.initialize();
      if (initialized) {
        await _locationService.startTracking(intervalSeconds: 10, distanceMeters: 10);
        _locationEnabled = true;
        _logger.log('[DataSourceManager] Location tracking enabled');
        // Save preference (both SharedPreferences and file for reliability)
        await _saveLocationPreference(true);
        return true;
      } else {
        _logger.log('[DataSourceManager] Failed to initialize location service');
        return false;
      }
    } else {
      await _locationService.stopTracking();
      _locationEnabled = false;
      _logger.log('[DataSourceManager] Location tracking disabled');
      // Save preference (both SharedPreferences and file for reliability)
      await _saveLocationPreference(false);
      return true;
    }
  }

  /// Save location preference using Hive (primary) with file fallback
  Future<void> _saveLocationPreference(bool enabled) async {
    // Save to Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting('location_enabled', enabled);
      _logger.log('[DataSourceManager] Location preference saved to Hive: $enabled');
    }

    // Also save to file as backup
    try {
      final file = File('/data/data/com.example.carsoc/files/location_setting.json');
      await file.writeAsString('{"enabled": $enabled}');
      _logger.log('[DataSourceManager] Location preference saved to file: $enabled');
    } catch (e) {
      _logger.log('[DataSourceManager] Failed to save location preference to file: $e');
    }
  }

  /// Restore location tracking from saved preference
  /// Call this during app startup
  Future<void> restoreLocationSetting() async {
    bool? enabled;
    bool migratedFromFile = false;

    // Try Hive first (most reliable on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      enabled = hive.getSetting<bool>('location_enabled');
      if (enabled != null) {
        _logger.log('[DataSourceManager] Location preference from Hive: $enabled');
      } else {
        _logger.log('[DataSourceManager] No location preference in Hive yet');
      }
    } else {
      _logger.log('[DataSourceManager] Hive not available');
    }

    // Try file fallback if Hive didn't have a value
    if (enabled == null) {
      try {
        final file = File('/data/data/com.example.carsoc/files/location_setting.json');
        if (await file.exists()) {
          final content = await file.readAsString();
          final data = jsonDecode(content) as Map<String, dynamic>;
          enabled = data['enabled'] as bool?;
          _logger.log('[DataSourceManager] Location preference from file: $enabled');
          migratedFromFile = true;
        }
      } catch (e) {
        _logger.log('[DataSourceManager] Failed to read location preference from file: $e');
      }
    }

    // Migrate file value to Hive for next time
    if (migratedFromFile && enabled != null && hive.isAvailable) {
      await hive.saveSetting('location_enabled', enabled);
      _logger.log('[DataSourceManager] Migrated location preference to Hive: $enabled');
    }

    // Set the internal state directly without triggering another save
    if (enabled == true) {
      _logger.log('[DataSourceManager] Restoring location tracking from saved preference');
      _locationEnabled = true;
      await _locationService.startTracking();
      _logger.log('[DataSourceManager] Location tracking enabled (restored)');
    } else {
      _locationEnabled = false;
      _logger.log('[DataSourceManager] Location tracking not enabled (preference: $enabled)');
    }
  }

  /// Set left-hand drive layout preference
  Future<void> setLeftHandDrive(bool isLhd) async {
    _isLeftHandDrive = isLhd;
    await _saveDriveLayoutPreference(isLhd);
    _logger.log('[DataSourceManager] Left-hand drive layout set to: $isLhd');
  }

  /// Save drive layout preference
  Future<void> _saveDriveLayoutPreference(bool isLhd) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('left_hand_drive', isLhd);
    } catch (e) {
      _logger.log('[DataSourceManager] Failed to save drive layout preference: $e');
    }

    // Also save to file for reliability
    try {
      final file = File('/data/data/com.example.carsoc/files/drive_layout.json');
      await file.writeAsString('{"leftHandDrive": $isLhd}');
    } catch (e) {
      _logger.log('[DataSourceManager] Failed to save drive layout to file: $e');
    }
  }

  /// Restore drive layout preference from storage
  /// Auto-detects based on locale if no preference is saved
  Future<void> restoreDriveLayoutSetting() async {
    bool? isLhd;

    // Try SharedPreferences first
    try {
      final prefs = await SharedPreferences.getInstance();
      isLhd = prefs.getBool('left_hand_drive');
    } catch (e) {
      _logger.log('[DataSourceManager] Failed to read drive layout from SharedPreferences: $e');
    }

    // Try file fallback
    if (isLhd == null) {
      try {
        final file = File('/data/data/com.example.carsoc/files/drive_layout.json');
        if (await file.exists()) {
          final content = await file.readAsString();
          final data = jsonDecode(content) as Map<String, dynamic>;
          isLhd = data['leftHandDrive'] as bool?;
        }
      } catch (e) {
        _logger.log('[DataSourceManager] Failed to read drive layout from file: $e');
      }
    }

    // If no preference saved, auto-detect based on locale
    if (isLhd == null) {
      isLhd = _autoDetectDriveSide();
      _logger.log('[DataSourceManager] Auto-detected drive side: ${isLhd ? "LHD" : "RHD"}');
      await _saveDriveLayoutPreference(isLhd);
    }

    _isLeftHandDrive = isLhd;
    _logger.log('[DataSourceManager] Drive layout: ${_isLeftHandDrive ? "Left-hand drive" : "Right-hand drive"}');
  }

  /// Auto-detect drive side based on device locale
  /// Returns true for LHD (most countries), false for RHD countries
  bool _autoDetectDriveSide() {
    // RHD countries (drive on left side of road, driver on right)
    // UK, Australia, Japan, India, Thailand, Malaysia, Singapore, Hong Kong, etc.
    const rhdCountries = {
      'GB', 'AU', 'JP', 'IN', 'TH', 'MY', 'SG', 'HK', 'NZ', 'ZA', 'IE', 'CY',
      'MT', 'JM', 'TT', 'BB', 'BS', 'KE', 'UG', 'TZ', 'ZW', 'MU', 'BW', 'NA',
      'MZ', 'ZM', 'MW', 'SZ', 'LS', 'BD', 'PK', 'LK', 'NP', 'BT', 'MM', 'BN',
      'ID', 'TL', 'PG', 'FJ', 'WS', 'TO', 'SB', 'VU', 'KI',
    };

    // Get device locale country code
    final locale = Platform.localeName; // e.g., "en_AU", "en_GB", "de_DE"
    final parts = locale.split('_');
    final countryCode = parts.length > 1 ? parts[1].toUpperCase() : '';

    _logger.log('[DataSourceManager] Device locale: $locale, country: $countryCode');

    // If country is in RHD list, return false (right-hand drive)
    if (rhdCountries.contains(countryCode)) {
      return false; // RHD
    }

    // Default to LHD (most common worldwide)
    return true;
  }

  /// Restore 12V battery protection settings from storage
  Future<void> restoreAuxBatteryProtectionSettings() async {
    final hive = HiveStorageService.instance;

    // Try Hive first (works on AI boxes)
    if (hive.isAvailable) {
      _auxBatteryProtectionEnabled = hive.getSetting<bool>('aux_battery_protection_enabled') ?? true;
      _auxBatteryProtectionThreshold = hive.getSetting<double>('aux_battery_protection_threshold') ?? 12.8;
      _logger.log('[DataSourceManager] 12V protection from Hive: enabled=$_auxBatteryProtectionEnabled, threshold=${_auxBatteryProtectionThreshold}V');
      return;
    }

    // Fallback to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      _auxBatteryProtectionEnabled = prefs.getBool('aux_battery_protection_enabled') ?? true;
      _auxBatteryProtectionThreshold = prefs.getDouble('aux_battery_protection_threshold') ?? 12.8;
      _logger.log('[DataSourceManager] 12V protection from SharedPreferences: enabled=$_auxBatteryProtectionEnabled, threshold=${_auxBatteryProtectionThreshold}V');
    } catch (e) {
      _logger.log('[DataSourceManager] Failed to load 12V protection settings: $e');
    }
  }

  /// Update 12V battery protection settings and clear active state if needed
  void updateAuxBatteryProtectionSettings({bool? enabled, double? threshold}) {
    if (enabled != null) {
      _auxBatteryProtectionEnabled = enabled;
      // If protection is disabled, immediately clear active state and resume polling
      if (!enabled && _auxBatteryProtectionActive) {
        _auxBatteryProtectionActive = false;
        _obdService.resumePolling();
        _logger.log('[DataSourceManager] 12V protection DISABLED by user - OBD polling RESUMED');

        // Clear the MQTT alert
        _mqttService?.publishSystemAlert(
          alertType: '12v_low',
          isActive: false,
          message: '12V protection disabled by user - OBD polling resumed',
        );
      }
    }

    if (threshold != null) {
      final oldThreshold = _auxBatteryProtectionThreshold;
      _auxBatteryProtectionThreshold = threshold;
      // If threshold was lowered and protection was active, clear it
      // (the new threshold may be below the current voltage)
      if (threshold < oldThreshold && _auxBatteryProtectionActive) {
        _auxBatteryProtectionActive = false;
        _obdService.resumePolling();
        _logger.log('[DataSourceManager] 12V protection threshold LOWERED to ${threshold}V - OBD polling RESUMED');

        // Clear the MQTT alert
        _mqttService?.publishSystemAlert(
          alertType: '12v_low',
          isActive: false,
          message: 'Threshold lowered to ${threshold}V - OBD polling resumed',
          additionalData: {'new_threshold': threshold},
        );
      }
    }

    _logger.log('[DataSourceManager] 12V protection updated: enabled=$_auxBatteryProtectionEnabled, threshold=${_auxBatteryProtectionThreshold}V, active=$_auxBatteryProtectionActive');
  }

  /// Check 12V battery voltage and pause/resume OBD polling if needed
  void _checkAuxBatteryProtection(VehicleData data) {
    if (!_auxBatteryProtectionEnabled) return;
    if (_currentSource != DataSource.obd) return;

    // Get 12V voltage from additionalProperties (AUX_V PID)
    final auxVoltage = data.additionalProperties?['AUX_V'] as double?;
    if (auxVoltage == null) return;

    if (!_auxBatteryProtectionActive) {
      // Check if we need to activate protection (voltage dropped below threshold)
      if (auxVoltage < _auxBatteryProtectionThreshold) {
        _auxBatteryProtectionActive = true;
        _obdService.pausePolling();
        _logger.log('[DataSourceManager] 12V BATTERY PROTECTION ACTIVATED: ${auxVoltage.toStringAsFixed(2)}V < ${_auxBatteryProtectionThreshold}V - OBD polling PAUSED');

        // Publish MQTT system alert
        _mqttService?.publishSystemAlert(
          alertType: '12v_low',
          isActive: true,
          message: '12V battery low (${auxVoltage.toStringAsFixed(1)}V) - OBD polling disabled',
          additionalData: {
            'voltage': auxVoltage,
            'threshold': _auxBatteryProtectionThreshold,
          },
        );
      }
    } else {
      // Check if we can deactivate protection (voltage recovered above threshold + hysteresis)
      final resumeThreshold = _auxBatteryProtectionThreshold + _auxBatteryHysteresis;
      if (auxVoltage >= resumeThreshold) {
        _auxBatteryProtectionActive = false;
        _obdService.resumePolling();
        _logger.log('[DataSourceManager] 12V battery recovered: ${auxVoltage.toStringAsFixed(2)}V >= ${resumeThreshold.toStringAsFixed(1)}V - OBD polling RESUMED');

        // Publish MQTT alert clear
        _mqttService?.publishSystemAlert(
          alertType: '12v_low',
          isActive: false,
          message: '12V battery recovered (${auxVoltage.toStringAsFixed(1)}V) - OBD polling resumed',
          additionalData: {
            'voltage': auxVoltage,
            'threshold': _auxBatteryProtectionThreshold,
          },
        );
      }
    }
  }

  /// Enrich vehicle data with current location
  VehicleData _enrichWithLocation(VehicleData data) {
    final location = _locationService.lastLocation;
    if (location != null && _locationEnabled) {
      return data.copyWith(
        latitude: location.latitude,
        longitude: location.longitude,
        altitude: location.altitude,
        gpsSpeed: location.speedKmh,
        heading: location.heading,
      );
    }
    return data;
  }

  /// Dispose and cleanup
  void dispose() {
    _stopCurrentSource();
    _proxyPublishTimer?.cancel();
    _chargingSessionSubscription?.cancel();
    _locationService.stopTracking();
    _carInfoService.dispose();
    _obdService.dispose();
    _chargingSessionService.dispose();
    _dataController.close();
    _sourceController.close();
  }
}
