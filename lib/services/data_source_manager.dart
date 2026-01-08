import 'dart:async';
import '../models/vehicle_data.dart';
import 'car_info_service.dart';
import 'obd_service.dart';
import 'database_service.dart';
import 'mqtt_service.dart';
import 'abrp_service.dart';
import 'car_app_bridge.dart';
import 'charging_session_service.dart';
import 'debug_logger.dart';

/// Data source types available
enum DataSource {
  carInfo,  // Android Automotive CarInfo API (primary for AAOS)
  obd,      // OBD-II Bluetooth adapter
}

/// Manages vehicle data collection from multiple sources with intelligent fallback
class DataSourceManager {
  final CarInfoService _carInfoService;
  final OBDService _obdService;
  final MqttService? _mqttService;
  final AbrpService _abrpService = AbrpService();
  late final ChargingSessionService _chargingSessionService;
  final _logger = DebugLogger.instance;

  DataSource? _currentSource;
  StreamSubscription<VehicleData>? _dataSubscription;

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
  }

  /// Get ABRP service for configuration
  AbrpService get abrpService => _abrpService;

  /// Get charging session service for monitoring
  ChargingSessionService get chargingSessionService => _chargingSessionService;

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

  /// Initialize and determine best data source
  Future<DataSource?> initialize() async {
    _logger.log('[DataSourceManager] Initializing...');

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
        _startObdSource();
        break;
    }
  }

  /// Start CarInfo API data source
  Future<void> _startCarInfoSource() async {
    _dataSubscription = _carInfoService.vehicleDataStream.listen(
      (data) {
        _dataController.add(data);
        _saveData(data);
        _publishToMqtt(data);
        _publishToAbrp(data);
        _sendToAndroidAuto(data);
        _processChargingData(data);
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
        _dataController.add(data);
        _saveData(data);
        _publishToMqtt(data);
        _publishToAbrp(data);
        _sendToAndroidAuto(data);
        _processChargingData(data);
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

    return sources;
  }

  /// Get data source display name
  static String getSourceName(DataSource source) {
    switch (source) {
      case DataSource.carInfo:
        return 'Android CarInfo API';
      case DataSource.obd:
        return 'OBD-II Adapter';
    }
  }

  /// Get data source description
  static String getSourceDescription(DataSource source) {
    switch (source) {
      case DataSource.carInfo:
        return 'Direct access to vehicle data via Android Automotive OS';
      case DataSource.obd:
        return 'Vehicle data from Bluetooth OBD-II adapter';
    }
  }

  /// Update the data update frequency (applies to ABRP)
  /// Call this when user changes the setting
  Future<void> updateFrequency(int seconds) async {
    _logger.log('[DataSourceManager] Updating frequency to $seconds seconds');

    // Update ABRP send interval (minimum 5 seconds enforced by ABRP service)
    _abrpService.setUpdateInterval(seconds);
  }

  /// Dispose and cleanup
  void dispose() {
    _stopCurrentSource();
    _carInfoService.dispose();
    _obdService.dispose();
    _chargingSessionService.dispose();
    _dataController.close();
    _sourceController.close();
  }
}
