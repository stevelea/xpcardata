import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/charging_sample.dart';
import '../models/charging_session.dart';
import '../models/vehicle_data.dart';
import 'debug_logger.dart';

/// Service providing mock vehicle and charging session data for testing
/// Can be enabled/disabled via settings
class MockDataService {
  static final MockDataService _instance = MockDataService._internal();
  static MockDataService get instance => _instance;
  MockDataService._internal();

  final _logger = DebugLogger.instance;
  bool _enabled = false;
  List<ChargingSession>? _cachedSessions;

  // Mock vehicle data streaming
  Timer? _vehicleDataTimer;
  final StreamController<VehicleData> _vehicleDataController =
      StreamController<VehicleData>.broadcast();
  VehicleData? _currentMockData;

  /// Stream of mock vehicle data (updates every 2 seconds when enabled)
  Stream<VehicleData> get vehicleDataStream => _vehicleDataController.stream;

  /// Current mock vehicle data
  VehicleData? get currentVehicleData => _currentMockData;

  /// Whether mock data mode is enabled
  bool get isEnabled => _enabled;

  /// Initialize service and load enabled state
  Future<void> initialize() async {
    bool? enabled;

    // Try SharedPreferences first
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool('mock_data_enabled');
      _logger.log('[MockData] Loaded from prefs: $enabled');
    } catch (e) {
      _logger.log('[MockData] Prefs failed: $e');
    }

    // Try file-based storage as fallback
    if (enabled == null) {
      enabled = await _loadFromFile();
      if (enabled != null) {
        _logger.log('[MockData] Loaded from file: $enabled');
      }
    }

    _enabled = enabled ?? false;
    _logger.log('[MockData] Initialized, enabled: $_enabled');

    // Start mock vehicle data stream if enabled
    if (_enabled) {
      _startMockVehicleDataStream();
    }
  }

  /// Enable or disable mock data mode
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    _cachedSessions = null; // Clear cache when toggling

    // Start or stop mock vehicle data streaming (do this regardless of save success)
    if (enabled) {
      _startMockVehicleDataStream();
    } else {
      _stopMockVehicleDataStream();
    }

    // Try to persist the setting
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('mock_data_enabled', enabled);
      _logger.log('[MockData] Set enabled: $enabled (saved to prefs)');
    } catch (e) {
      _logger.log('[MockData] Set enabled: $enabled (prefs failed: $e)');
      // Also try file-based storage as fallback
      await _saveToFile(enabled);
    }
  }

  /// Save enabled state to file (fallback for AAOS)
  Future<void> _saveToFile(bool enabled) async {
    try {
      final file = File('/data/data/com.example.carsoc/files/mock_data_settings.json');
      await file.writeAsString('{"enabled": $enabled}');
      _logger.log('[MockData] Saved to file: $enabled');
    } catch (e) {
      _logger.log('[MockData] Failed to save to file: $e');
    }
  }

  /// Load enabled state from file (fallback for AAOS)
  Future<bool?> _loadFromFile() async {
    try {
      final file = File('/data/data/com.example.carsoc/files/mock_data_settings.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        return data['enabled'] as bool?;
      }
    } catch (e) {
      _logger.log('[MockData] Failed to load from file: $e');
    }
    return null;
  }

  /// Start streaming mock vehicle data
  void _startMockVehicleDataStream() {
    _stopMockVehicleDataStream(); // Cancel existing timer
    _currentMockData = _generateMockVehicleData();
    _vehicleDataController.add(_currentMockData!);
    _logger.log('[MockData] Started mock vehicle data stream');

    // Update every 2 seconds with slight variations
    _vehicleDataTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _currentMockData = _generateMockVehicleData();
      _vehicleDataController.add(_currentMockData!);
    });
  }

  /// Stop streaming mock vehicle data
  void _stopMockVehicleDataStream() {
    _vehicleDataTimer?.cancel();
    _vehicleDataTimer = null;
    _currentMockData = null;
    _logger.log('[MockData] Stopped mock vehicle data stream');
  }

  /// Generate realistic mock vehicle data
  VehicleData _generateMockVehicleData() {
    final random = Random();

    // Base values for a parked XPENG G6 LR with ~72% SOC
    const baseSoc = 72.0;
    const baseVoltage = 392.0; // ~400V nominal
    const baseTemp = 28.0;
    const baseOdometer = 14850.0;

    // Add small random variations to simulate real sensor noise
    final socVariation = (random.nextDouble() - 0.5) * 0.2; // ±0.1%
    final voltageVariation = (random.nextDouble() - 0.5) * 2.0; // ±1V
    final tempVariation = (random.nextDouble() - 0.5) * 1.0; // ±0.5°C

    // Calculate range based on SOC (assuming ~4.5km per 1% for G6 LR)
    final soc = baseSoc + socVariation;
    final estimatedRange = soc * 4.5;

    return VehicleData(
      timestamp: DateTime.now(),
      stateOfCharge: soc,
      stateOfHealth: 98.5, // Healthy battery
      batteryCapacity: 87.5, // G6 LR capacity
      batteryVoltage: baseVoltage + voltageVariation,
      batteryCurrent: 0.0, // Parked, no current flow
      batteryTemperature: baseTemp + tempVariation,
      range: estimatedRange,
      speed: 0.0, // Parked
      odometer: baseOdometer,
      power: 0.0, // Parked
      cumulativeCharge: 4250.0, // Ah
      cumulativeDischarge: 4180.0, // Ah
      latitude: -33.8688, // Sydney
      longitude: 151.2093,
      altitude: 58.0,
      gpsSpeed: 0.0,
      heading: 125.0,
      additionalProperties: {
        'HV_V': baseVoltage + voltageVariation,
        'HV_A': 0.0,
        'HV_T_MAX': baseTemp + tempVariation + 2.0,
        'HV_T_MIN': baseTemp + tempVariation - 2.0,
        'CHARGING': 0,
        'BMS_CHG_STATUS': 0,
        'RANGE_EST': estimatedRange,
        'RANGE_DISP': estimatedRange - 5, // Display range slightly lower
        '12V_V': 12.8 + (random.nextDouble() - 0.5) * 0.2,
        'AMBIENT_TEMP': 22.0 + (random.nextDouble() - 0.5) * 2.0,
      },
    );
  }

  /// Dispose of resources
  void dispose() {
    _stopMockVehicleDataStream();
    _vehicleDataController.close();
  }

  /// Get mock charging sessions
  /// Returns a variety of realistic charging sessions with GPS locations
  List<ChargingSession> getMockSessions() {
    if (_cachedSessions != null) return _cachedSessions!;

    final now = DateTime.now();
    final sessions = <ChargingSession>[];

    // Generate sessions over the past 30 days
    final mockData = [
      // Home charging - overnight AC (Sydney area)
      _MockSessionData(
        daysAgo: 1,
        startHour: 22,
        durationMins: 480, // 8 hours overnight
        startSoc: 35,
        endSoc: 95,
        chargingType: 'ac',
        maxPowerKw: 7.4,
        locationName: 'Home',
        latitude: -33.8688,
        longitude: 151.2093,
        energyKwh: 52.5,
        distanceKm: 180,
        consumption: 17.2,
      ),
      // Public DC fast charge - EVSE Australia (Newcastle)
      _MockSessionData(
        daysAgo: 3,
        startHour: 14,
        durationMins: 35,
        startSoc: 18,
        endSoc: 80,
        chargingType: 'dc',
        maxPowerKw: 180,
        locationName: 'EVSE Australia - Kotara',
        latitude: -32.9413,
        longitude: 151.6983,
        energyKwh: 54.3,
        distanceKm: 245,
        consumption: 18.5,
      ),
      // Supermarket parking AC (Coles Ryde)
      _MockSessionData(
        daysAgo: 5,
        startHour: 10,
        durationMins: 90,
        startSoc: 45,
        endSoc: 58,
        chargingType: 'ac',
        maxPowerKw: 22,
        locationName: 'Coles Ryde - ChargePoint',
        latitude: -33.8142,
        longitude: 151.1025,
        energyKwh: 11.4,
        distanceKm: 52,
        consumption: 16.8,
      ),
      // Home charging - top up
      _MockSessionData(
        daysAgo: 6,
        startHour: 19,
        durationMins: 180,
        startSoc: 55,
        endSoc: 80,
        chargingType: 'ac',
        maxPowerKw: 7.4,
        locationName: 'Home',
        latitude: -33.8688,
        longitude: 151.2093,
        energyKwh: 21.9,
        distanceKm: 85,
        consumption: 17.5,
      ),
      // Tesla Destination (Wollongong)
      _MockSessionData(
        daysAgo: 8,
        startHour: 12,
        durationMins: 120,
        startSoc: 30,
        endSoc: 55,
        chargingType: 'ac',
        maxPowerKw: 11,
        locationName: 'Crown St Mall - Tesla',
        latitude: -34.4249,
        longitude: 150.8931,
        energyKwh: 21.9,
        distanceKm: 120,
        consumption: 19.2,
      ),
      // BP Pulse DC (M1 Motorway)
      _MockSessionData(
        daysAgo: 10,
        startHour: 16,
        durationMins: 25,
        startSoc: 12,
        endSoc: 65,
        chargingType: 'dc',
        maxPowerKw: 150,
        locationName: 'BP Pulse - Wyong Services',
        latitude: -33.2848,
        longitude: 151.4235,
        energyKwh: 46.4,
        distanceKm: 210,
        consumption: 18.0,
      ),
      // Home charging - full overnight
      _MockSessionData(
        daysAgo: 12,
        startHour: 21,
        durationMins: 540,
        startSoc: 25,
        endSoc: 100,
        chargingType: 'ac',
        maxPowerKw: 7.4,
        locationName: 'Home',
        latitude: -33.8688,
        longitude: 151.2093,
        energyKwh: 65.6,
        distanceKm: 195,
        consumption: 16.5,
      ),
      // Chargefox DC (Canberra trip)
      _MockSessionData(
        daysAgo: 14,
        startHour: 11,
        durationMins: 40,
        startSoc: 15,
        endSoc: 85,
        chargingType: 'dc',
        maxPowerKw: 350,
        locationName: 'Chargefox - Goulburn',
        latitude: -34.7546,
        longitude: 149.7185,
        energyKwh: 61.3,
        distanceKm: 280,
        consumption: 19.8,
      ),
      // NRMA DC (Canberra)
      _MockSessionData(
        daysAgo: 15,
        startHour: 15,
        durationMins: 30,
        startSoc: 22,
        endSoc: 75,
        chargingType: 'dc',
        maxPowerKw: 175,
        locationName: 'NRMA - Canberra Centre',
        latitude: -35.2809,
        longitude: 149.1300,
        energyKwh: 46.4,
        distanceKm: 165,
        consumption: 17.8,
      ),
      // Home charging
      _MockSessionData(
        daysAgo: 17,
        startHour: 20,
        durationMins: 420,
        startSoc: 40,
        endSoc: 90,
        chargingType: 'ac',
        maxPowerKw: 7.4,
        locationName: 'Home',
        latitude: -33.8688,
        longitude: 151.2093,
        energyKwh: 43.8,
        distanceKm: 145,
        consumption: 17.0,
      ),
      // Jolt free charger (CBD)
      _MockSessionData(
        daysAgo: 20,
        startHour: 9,
        durationMins: 45,
        startSoc: 50,
        endSoc: 62,
        chargingType: 'dc',
        maxPowerKw: 50,
        locationName: 'Jolt - George St Sydney',
        latitude: -33.8731,
        longitude: 151.2068,
        energyKwh: 10.5,
        distanceKm: 38,
        consumption: 16.2,
      ),
      // Home charging
      _MockSessionData(
        daysAgo: 22,
        startHour: 23,
        durationMins: 360,
        startSoc: 30,
        endSoc: 75,
        chargingType: 'ac',
        maxPowerKw: 7.4,
        locationName: 'Home',
        latitude: -33.8688,
        longitude: 151.2093,
        energyKwh: 39.4,
        distanceKm: 128,
        consumption: 17.3,
      ),
      // Ampol AmpCharge (Blue Mountains)
      _MockSessionData(
        daysAgo: 25,
        startHour: 13,
        durationMins: 45,
        startSoc: 20,
        endSoc: 80,
        chargingType: 'dc',
        maxPowerKw: 120,
        locationName: 'Ampol AmpCharge - Katoomba',
        latitude: -33.7139,
        longitude: 150.3119,
        energyKwh: 52.5,
        distanceKm: 175,
        consumption: 18.5,
      ),
      // Evie Networks DC (Central Coast)
      _MockSessionData(
        daysAgo: 28,
        startHour: 10,
        durationMins: 35,
        startSoc: 25,
        endSoc: 78,
        chargingType: 'dc',
        maxPowerKw: 150,
        locationName: 'Evie Networks - Erina',
        latitude: -33.4368,
        longitude: 151.3895,
        energyKwh: 46.4,
        distanceKm: 198,
        consumption: 17.9,
      ),
      // Home charging
      _MockSessionData(
        daysAgo: 30,
        startHour: 22,
        durationMins: 480,
        startSoc: 18,
        endSoc: 92,
        chargingType: 'ac',
        maxPowerKw: 7.4,
        locationName: 'Home',
        latitude: -33.8688,
        longitude: 151.2093,
        energyKwh: 64.8,
        distanceKm: 220,
        consumption: 17.8,
      ),
    ];

    // Convert mock data to ChargingSession objects
    for (var i = 0; i < mockData.length; i++) {
      final data = mockData[i];
      final startTime = now.subtract(Duration(
        days: data.daysAgo,
        hours: 24 - data.startHour,
      ));
      final endTime = startTime.add(Duration(minutes: data.durationMins));

      // Generate realistic odometer values (decreasing as we go back in time)
      final baseOdometer = 15000.0;
      final odometer = baseOdometer - (i * 150) - Random().nextInt(50);

      // Generate charging curve for this session
      final chargingCurve = _generateMockChargingCurve(
        startTime: startTime,
        durationMins: data.durationMins,
        startSoc: data.startSoc.toDouble(),
        endSoc: data.endSoc.toDouble(),
        chargingType: data.chargingType,
        maxPowerKw: data.maxPowerKw,
      );

      sessions.add(ChargingSession(
        id: 'mock_${startTime.millisecondsSinceEpoch}',
        startTime: startTime,
        endTime: endTime,
        startCumulativeCharge: 100.0 + (data.startSoc * 2),
        endCumulativeCharge: 100.0 + (data.endSoc * 2),
        startSoc: data.startSoc.toDouble(),
        endSoc: data.endSoc.toDouble(),
        startOdometer: odometer,
        endOdometer: odometer,
        isActive: false,
        chargingType: data.chargingType,
        maxPowerKw: data.maxPowerKw,
        energyAddedKwh: data.energyKwh,
        distanceSinceLastCharge: data.distanceKm,
        consumptionKwhPer100km: data.consumption,
        previousSessionOdometer: odometer - data.distanceKm,
        latitude: data.latitude,
        longitude: data.longitude,
        locationName: data.locationName,
        chargingCost: _estimateCost(data.energyKwh, data.chargingType, data.locationName),
        notes: null,
        chargingCurve: chargingCurve,
      ));
    }

    // Sort by start time descending (newest first)
    sessions.sort((a, b) => b.startTime.compareTo(a.startTime));

    _cachedSessions = sessions;
    _logger.log('[MockData] Generated ${sessions.length} mock sessions');
    return sessions;
  }

  /// Generate a realistic mock charging curve based on session parameters
  List<ChargingSample> _generateMockChargingCurve({
    required DateTime startTime,
    required int durationMins,
    required double startSoc,
    required double endSoc,
    required String chargingType,
    required double maxPowerKw,
  }) {
    final samples = <ChargingSample>[];
    final random = Random();

    // Sample every 30 seconds
    const sampleIntervalSeconds = 30;
    final totalSamples = (durationMins * 60 / sampleIntervalSeconds).ceil();
    final socRange = endSoc - startSoc;

    for (var i = 0; i <= totalSamples; i++) {
      final timestamp = startTime.add(Duration(seconds: i * sampleIntervalSeconds));
      final progress = i / totalSamples; // 0.0 to 1.0

      // Calculate SOC at this point (linear progression)
      final soc = startSoc + (socRange * progress);

      // Calculate power based on charging type and SOC
      double powerKw;
      if (chargingType == 'dc') {
        // DC charging curve: high power below 50%, tapers 50-80%, slow above 80%
        if (soc < 50) {
          // Full power with slight variation
          powerKw = maxPowerKw * (0.9 + random.nextDouble() * 0.1);
        } else if (soc < 80) {
          // Linear taper from 100% to 50% power between 50-80% SOC
          final taperProgress = (soc - 50) / 30; // 0 at 50%, 1 at 80%
          final taperFactor = 1.0 - (taperProgress * 0.5); // 1.0 to 0.5
          powerKw = maxPowerKw * taperFactor * (0.9 + random.nextDouble() * 0.1);
        } else {
          // Slow charging above 80%: 20-30% of max power
          final slowFactor = 0.2 + (random.nextDouble() * 0.1);
          powerKw = maxPowerKw * slowFactor;
        }
      } else {
        // AC charging: constant power throughout with small variations
        powerKw = maxPowerKw * (0.95 + random.nextDouble() * 0.05);
      }

      // Battery temperature: starts at ambient, rises during charging
      final baseTemp = 20.0 + random.nextDouble() * 5; // Ambient 20-25°C
      final tempRise = chargingType == 'dc'
          ? (powerKw / maxPowerKw) * 15 // DC can heat battery more
          : 5.0; // AC heats less
      final temperature = baseTemp + (tempRise * progress);

      // Voltage: around 400V nominal, slightly higher when charging
      final voltage = 380 + (soc * 0.4) + (random.nextDouble() * 5);

      // Current: calculated from power and voltage (negative = charging)
      final current = -(powerKw * 1000 / voltage);

      samples.add(ChargingSample(
        timestamp: timestamp,
        soc: double.parse(soc.toStringAsFixed(1)),
        powerKw: double.parse(powerKw.toStringAsFixed(1)),
        temperature: double.parse(temperature.toStringAsFixed(1)),
        voltage: double.parse(voltage.toStringAsFixed(1)),
        current: double.parse(current.toStringAsFixed(1)),
      ));
    }

    return samples;
  }

  /// Estimate charging cost based on energy, type, and location
  double? _estimateCost(double energyKwh, String type, String locationName) {
    if (locationName == 'Home') {
      // Home rate: ~$0.30/kWh off-peak
      return energyKwh * 0.30;
    } else if (locationName.contains('Jolt')) {
      // Jolt is free
      return 0.0;
    } else if (type == 'dc') {
      // DC charging: ~$0.50-0.65/kWh
      return energyKwh * (0.50 + Random().nextDouble() * 0.15);
    } else {
      // Public AC: ~$0.35-0.45/kWh
      return energyKwh * (0.35 + Random().nextDouble() * 0.10);
    }
  }

  /// Get mock statistics
  Map<String, dynamic> getMockStatistics() {
    final sessions = getMockSessions();
    final totalEnergy = sessions.fold<double>(
      0.0,
      (sum, s) => sum + (s.energyAddedKwh ?? 0),
    );
    final consumptionValues = sessions
        .where((s) => s.consumptionKwhPer100km != null && s.consumptionKwhPer100km! > 0)
        .map((s) => s.consumptionKwhPer100km!)
        .toList();
    final avgConsumption = consumptionValues.isNotEmpty
        ? consumptionValues.reduce((a, b) => a + b) / consumptionValues.length
        : null;

    return {
      'sessionCount': sessions.length,
      'totalEnergyKwh': totalEnergy,
      'averageConsumptionKwhPer100km': avgConsumption,
    };
  }
}

/// Internal class for mock session data
class _MockSessionData {
  final int daysAgo;
  final int startHour;
  final int durationMins;
  final int startSoc;
  final int endSoc;
  final String chargingType;
  final double maxPowerKw;
  final String locationName;
  final double latitude;
  final double longitude;
  final double energyKwh;
  final double distanceKm;
  final double consumption;

  _MockSessionData({
    required this.daysAgo,
    required this.startHour,
    required this.durationMins,
    required this.startSoc,
    required this.endSoc,
    required this.chargingType,
    required this.maxPowerKw,
    required this.locationName,
    required this.latitude,
    required this.longitude,
    required this.energyKwh,
    required this.distanceKm,
    required this.consumption,
  });
}
