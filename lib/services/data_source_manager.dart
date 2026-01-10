import 'dart:async';
import 'dart:convert';
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
import 'location_service.dart';
import 'fleet_analytics_service.dart';
import 'debug_logger.dart';

/// Data source types available
enum DataSource {
  carInfo,  // Android Automotive CarInfo API (primary for AAOS)
  obd,      // OBD-II Bluetooth adapter
  proxy,    // Intercepted data from OBD proxy (external app querying)
}

/// Manages vehicle data collection from multiple sources with intelligent fallback
class DataSourceManager {
  final CarInfoService _carInfoService;
  final OBDService _obdService;
  final MqttService? _mqttService;
  final AbrpService _abrpService = AbrpService();
  final LocationService _locationService = LocationService.instance;
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
  LocationService get locationService => _locationService;

  /// Check if location tracking is enabled
  bool get isLocationEnabled => _locationEnabled;

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
    final enrichedData = _enrichWithLocation(data);
    _dataController.add(enrichedData);
    _saveData(enrichedData);
    _publishToMqtt(enrichedData);
    _publishToAbrp(enrichedData);
    _publishToFleetAnalytics(enrichedData);
    _sendToAndroidAuto(enrichedData);
    _processChargingData(enrichedData);
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
    }
  }

  /// Start CarInfo API data source
  Future<void> _startCarInfoSource() async {
    _dataSubscription = _carInfoService.vehicleDataStream.listen(
      (data) {
        final enrichedData = _enrichWithLocation(data);
        _dataController.add(enrichedData);
        _saveData(enrichedData);
        _publishToMqtt(enrichedData);
        _publishToAbrp(enrichedData);
        _publishToFleetAnalytics(enrichedData);
        _sendToAndroidAuto(enrichedData);
        _processChargingData(enrichedData);
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
        final enrichedData = _enrichWithLocation(data);
        _dataController.add(enrichedData);
        _saveData(enrichedData);
        _publishToMqtt(enrichedData);
        _publishToAbrp(enrichedData);
        _publishToFleetAnalytics(enrichedData);
        _sendToAndroidAuto(enrichedData);
        _processChargingData(enrichedData);
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
        _mqttService.publishVehicleData(data).catchError((error) {
          // Silently handle MQTT publish errors
        });
      }
    }
  }

  /// Publish data to ABRP if enabled
  void _publishToAbrp(VehicleData data) {
    _logger.log('[DataSourceManager] _publishToAbrp called, abrpService.isEnabled=${_abrpService.isEnabled}');
    if (_abrpService.isEnabled) {
      // Get charging status from additional properties if available
      bool? isCharging;
      if (data.additionalProperties != null) {
        final charging = data.additionalProperties!['CHARGING'];
        if (charging != null) {
          isCharging = (charging == 1 || charging == 1.0);
        }
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
        return true;
      } else {
        _logger.log('[DataSourceManager] Failed to initialize location service');
        return false;
      }
    } else {
      await _locationService.stopTracking();
      _locationEnabled = false;
      _logger.log('[DataSourceManager] Location tracking disabled');
      return true;
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
