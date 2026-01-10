import 'dart:async';
import 'package:flutter_automotive/flutter_automotive.dart';
import '../models/vehicle_data.dart';
import 'debug_logger.dart';

/// Service for accessing vehicle data via Android Automotive CarInfo API
/// Note: Only works on Android Automotive OS (AAOS), not Android Auto projection
class CarInfoService {
  final FlutterAutomotive _automotive = FlutterAutomotive();
  final StreamController<VehicleData> _dataController =
      StreamController<VehicleData>.broadcast();
  final _logger = DebugLogger.instance;

  bool _isInitialized = false;
  Timer? _pollingTimer;

  Stream<VehicleData> get vehicleDataStream => _dataController.stream;
  bool get isAvailable => _isInitialized;

  /// Initialize the CarInfo service and check availability
  Future<bool> initialize() async {
    try {
      _logger.log('[CarInfoService] Attempting to initialize CarInfo API...');

      // Test if flutter_automotive is available by getting a simple property
      // This will fail gracefully on non-AAOS devices
      // Increased timeout for Android Auto which may take longer to respond
      final speedValue = await _automotive.getProperty(VehicleProperty.PERF_VEHICLE_SPEED)
          .timeout(const Duration(seconds: 3));

      _logger.log('[CarInfoService] ✓ CarInfo API is available! Speed property returned: $speedValue');
      _isInitialized = true;

      if (_isInitialized) {
        _logger.log('[CarInfoService] Starting data collection...');
        _startDataCollection();
      }

      return _isInitialized;
    } catch (e) {
      // CarInfo API not available (likely not on AAOS)
      _logger.log('[CarInfoService] ✗ CarInfo API not available: $e');
      _logger.log('[CarInfoService] Error type: ${e.runtimeType}');
      _isInitialized = false;
      return false;
    }
  }

  /// Start collecting vehicle data
  void _startDataCollection() {
    // Poll vehicle data periodically
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final data = await getCurrentVehicleData();
      _dataController.add(data);
    });
  }

  /// Get current vehicle data from all available properties
  Future<VehicleData> getCurrentVehicleData() async {
    try {
      _logger.log('[CarInfoService] Fetching vehicle data...');

      // Gather data from multiple vehicle properties using getProperty
      final speed = await _getDoubleProperty(VehicleProperty.PERF_VEHICLE_SPEED);
      _logger.log('[CarInfoService] Speed: $speed km/h');

      final odometer = await _getDoubleProperty(VehicleProperty.PERF_ODOMETER);
      _logger.log('[CarInfoService] Odometer: ${odometer != null ? odometer / 1000 : null} km');

      // EV-specific properties
      final batteryLevel = await _getDoubleProperty(VehicleProperty.EV_BATTERY_LEVEL);
      _logger.log('[CarInfoService] Battery Level: $batteryLevel Wh');

      final batteryCapacity = await _getDoubleProperty(VehicleProperty.INFO_EV_BATTERY_CAPACITY);
      _logger.log('[CarInfoService] Battery Capacity: $batteryCapacity Wh');

      // Calculate SOC from battery level and capacity
      double? stateOfCharge;
      if (batteryLevel != null && batteryCapacity != null && batteryCapacity > 0) {
        // batteryLevel is in Wh, capacity is in Wh
        // Convert to percentage
        stateOfCharge = ((batteryLevel / batteryCapacity) * 100).clamp(0.0, 100.0);
        _logger.log('[CarInfoService] Calculated SOC: $stateOfCharge%');
      } else {
        _logger.log('[CarInfoService] Cannot calculate SOC - missing battery data');
      }

      // Calculate remaining range (simplified estimation)
      double? range;
      if (stateOfCharge != null) {
        // Assume 400km max range (can be made configurable)
        range = (stateOfCharge / 100) * 400;
        _logger.log('[CarInfoService] Estimated range: $range km');
      }

      final vehicleData = VehicleData(
        timestamp: DateTime.now(),
        stateOfCharge: stateOfCharge,
        stateOfHealth: null, // SOH not typically available via standard properties
        batteryCapacity: batteryCapacity != null ? batteryCapacity / 1000 : null, // Convert Wh to kWh
        batteryVoltage: null, // Not directly available in standard properties
        batteryCurrent: null, // Not directly available in standard properties
        batteryTemperature: null, // Not directly available in standard properties
        range: range,
        speed: speed,
        odometer: odometer != null ? odometer / 1000 : null, // Convert m to km
        power: null, // Would need to calculate from current and voltage
      );

      _logger.log('[CarInfoService] ✓ Vehicle data retrieved successfully');
      return vehicleData;
    } catch (e) {
      _logger.log('[CarInfoService] ✗ Error fetching vehicle data: $e');
      // Return empty data on error
      return VehicleData(timestamp: DateTime.now());
    }
  }

  /// Helper method to get a double property value
  Future<double?> _getDoubleProperty(VehicleProperty property) async {
    try {
      final value = await _automotive.getProperty(property)
          .timeout(const Duration(seconds: 1));

      if (value == null) return null;

      // Convert to double if it's an int or already a double
      if (value is double) return value;
      if (value is int) return value.toDouble();

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Get battery state of charge
  Future<double?> getBatterySOC() async {
    try {
      final level = await _getDoubleProperty(VehicleProperty.EV_BATTERY_LEVEL);
      final capacity = await _getDoubleProperty(VehicleProperty.INFO_EV_BATTERY_CAPACITY);

      if (level != null && capacity != null && capacity > 0) {
        return ((level / capacity) * 100).clamp(0.0, 100.0);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Get battery capacity (in kWh)
  Future<double?> getBatteryCapacity() async {
    final capacity = await _getDoubleProperty(VehicleProperty.INFO_EV_BATTERY_CAPACITY);
    return capacity != null ? capacity / 1000 : null; // Wh to kWh
  }

  /// Get vehicle speed (in km/h)
  Future<double?> getSpeed() async {
    return await _getDoubleProperty(VehicleProperty.PERF_VEHICLE_SPEED);
  }

  /// Get odometer (in km)
  Future<double?> getOdometer() async {
    final odo = await _getDoubleProperty(VehicleProperty.PERF_ODOMETER);
    return odo != null ? odo / 1000 : null; // meters to km
  }

  /// Check if specific vehicle property is available
  Future<bool> isPropertyAvailable(VehicleProperty property) async {
    try {
      final value = await _automotive.getProperty(property)
          .timeout(const Duration(seconds: 1));
      return value != null;
    } catch (e) {
      return false;
    }
  }

  /// Get list of available vehicle properties
  Future<List<String>> getAvailableProperties() async {
    final properties = <String>[];

    final propertiesToCheck = {
      'PERF_VEHICLE_SPEED': VehicleProperty.PERF_VEHICLE_SPEED,
      'PERF_ODOMETER': VehicleProperty.PERF_ODOMETER,
      'EV_BATTERY_LEVEL': VehicleProperty.EV_BATTERY_LEVEL,
      'INFO_EV_BATTERY_CAPACITY': VehicleProperty.INFO_EV_BATTERY_CAPACITY,
    };

    for (final entry in propertiesToCheck.entries) {
      if (await isPropertyAvailable(entry.value)) {
        properties.add(entry.key);
      }
    }

    return properties;
  }

  /// Stop data collection
  void stop() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  void dispose() {
    stop();
    _dataController.close();
  }
}
