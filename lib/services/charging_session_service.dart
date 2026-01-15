import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vehicle_data.dart';
import '../models/charging_session.dart';
import '../models/charging_sample.dart';
import '../providers/vehicle_data_provider.dart' show vehicleBatteryCapacities;
import 'debug_logger.dart';
import 'mqtt_service.dart';
import 'database_service.dart';
import 'hive_storage_service.dart';
import 'native_location_service.dart';
import 'open_charge_map_service.dart';
import 'mock_data_service.dart';

/// Charging type enum
enum ChargingType {
  none,
  ac,
  dc,
  unknown,
}

/// Service for detecting and tracking charging sessions
/// Monitors charging status PIDs, current, voltage, and cumulative charge
/// to detect charging state and calculate power
class ChargingSessionService {
  final _logger = DebugLogger.instance;
  final MqttService? _mqttService;
  final DatabaseService _db = DatabaseService.instance;
  final HiveStorageService _hive = HiveStorageService.instance;
  final NativeLocationService _locationService = NativeLocationService.instance;

  ChargingSession? _currentSession;
  double? _lastCumulativeCharge;
  double? _lastVoltage; // Track voltage for kWh calculation
  bool _isCharging = false;
  ChargingType _chargingType = ChargingType.none;
  double _chargePowerKw = 0.0;
  double? _previousSessionEndOdometer; // Odometer at end of last charge
  double? _lastKnownOdometer; // Last non-zero odometer reading (persisted across sessions)

  // In-memory session storage (AAOS fallback when all persistent storage fails)
  // Sessions are kept in memory and synced to MQTT/Home Assistant
  final List<ChargingSession> _inMemorySessions = [];

  // Energy accumulation for sessions (integrates power over time)
  double _accumulatedEnergyKwh = 0.0;
  DateTime? _lastPowerSampleTime;

  // MQTT update throttling - only send UPDATE every 30 seconds
  DateTime? _lastMqttUpdateTime;
  static const int _mqttUpdateIntervalSeconds = 30;

  // Track peak SOC during charging session (to handle stale end-of-session data)
  double _peakSocDuringSession = 0.0;

  // Cached battery capacity from settings
  double? _batteryCapacityKwh;

  // Stationary sample counter (need 2 consecutive samples at speed=0 to confirm charging)
  int _stationarySampleCount = 0;
  static const int _requiredStationarySamples = 2;

  // Track consecutive non-charging samples to detect charging end
  int _nonChargingSampleCount = 0;
  static const int _requiredNonChargingSamples = 2; // 2 consecutive samples with no charging indicators

  // Charging curve sample collection
  List<ChargingSample> _currentSessionSamples = [];
  DateTime? _lastCurveSampleTime;
  double? _lastSampledSoc;
  static const int _curveSampleIntervalSeconds = 30; // Sample every 30 seconds
  static const int _maxSamplesPerSession = 120; // Max ~1 hour of data at 30s intervals
  static const double _minSocChangeForSample = 0.5; // Or sample if SOC changed by 0.5%

  // Thresholds for detection
  static const double _chargingCurrentThreshold = 0.5; // Amps (positive = discharging, negative = charging)
  static const double _minChargeChange = 0.1; // Ah
  static const double _maxSpeedForCharging = 1.0; // km/h - must be stationary to charge

  // Minimum session thresholds to filter out false positives (e.g., brief stops, regen)
  static const int _minSessionDurationSeconds = 120; // 2 minutes minimum
  static const double _minSocGainForSave = 1.0; // At least 1% SOC gain
  static const double _minEnergyKwhForSave = 0.5; // At least 0.5 kWh added

  final StreamController<ChargingSession> _sessionController =
      StreamController<ChargingSession>.broadcast();

  /// Stream of charging session updates
  Stream<ChargingSession> get sessionStream => _sessionController.stream;

  /// Current active charging session (null if not charging)
  ChargingSession? get currentSession => _currentSession;

  /// Whether vehicle is currently charging
  bool get isCharging => _isCharging;

  /// Current charging type (AC, DC, or none)
  ChargingType get chargingType => _chargingType;

  /// Current charge power in kW
  double get chargePowerKw => _chargePowerKw;

  ChargingSessionService({MqttService? mqttService}) : _mqttService = mqttService {
    // Initialize: load sessions from persistent storage into memory
    _initializeSessions();
    _loadPreviousSessionOdometer();
    // Reset charging state on initialization - ensures clean state on app restart
    _isCharging = false;
    _chargingType = ChargingType.none;
    _chargePowerKw = 0.0;
    _stationarySampleCount = 0;
    _nonChargingSampleCount = 0;
    _logger.log('[Charging] Service initialized - charging state reset');
  }

  /// Initialize: load sessions from persistent storage into in-memory cache
  /// This ensures sessions persist across app restarts
  Future<void> _initializeSessions() async {
    _logger.log('[Charging] Initializing sessions from persistent storage...');

    // Try Hive first
    if (_hive.isAvailable) {
      try {
        final sessions = await _hive.getChargingSessions();
        if (sessions.isNotEmpty) {
          _inMemorySessions.clear();
          _inMemorySessions.addAll(sessions);
          _logger.log('[Charging] Loaded ${sessions.length} sessions from Hive into memory');
          return;
        }
      } catch (e) {
        _logger.log('[Charging] Hive initialization failed: $e');
      }
    }

    // Try SQLite database
    if (_db.isAvailable) {
      try {
        final sessions = await _db.getChargingSessions();
        if (sessions.isNotEmpty) {
          _inMemorySessions.clear();
          _inMemorySessions.addAll(sessions);
          _logger.log('[Charging] Loaded ${sessions.length} sessions from SQLite into memory');
          return;
        }
      } catch (e) {
        _logger.log('[Charging] SQLite initialization failed: $e');
      }
    }

    // Try SharedPreferences
    try {
      final sessions = await _loadSessionsFromPrefs();
      if (sessions.isNotEmpty) {
        _inMemorySessions.clear();
        _inMemorySessions.addAll(sessions);
        _logger.log('[Charging] Loaded ${sessions.length} sessions from SharedPreferences into memory');
        return;
      }
    } catch (e) {
      _logger.log('[Charging] SharedPreferences initialization failed: $e');
    }

    // Try file storage
    try {
      final sessions = await _loadSessionsFromFile();
      if (sessions.isNotEmpty) {
        _inMemorySessions.clear();
        _inMemorySessions.addAll(sessions);
        _logger.log('[Charging] Loaded ${sessions.length} sessions from file into memory');
        return;
      }
    } catch (e) {
      _logger.log('[Charging] File storage initialization failed: $e');
    }

    _logger.log('[Charging] No existing sessions found in any storage');
  }

  /// Load the odometer from the last completed charging session
  /// Tries in-memory first, then Hive, database, SharedPreferences, and file storage
  Future<void> _loadPreviousSessionOdometer() async {
    // First check in-memory storage
    if (_inMemorySessions.isNotEmpty) {
      final sessions = List<ChargingSession>.from(_inMemorySessions);
      sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
      final lastCompleted = sessions.where((s) => !s.isActive && s.endOdometer != null).firstOrNull;
      if (lastCompleted != null) {
        _previousSessionEndOdometer = lastCompleted.endOdometer;
        _logger.log('[Charging] Loaded previous session odometer from in-memory: ${_previousSessionEndOdometer?.toStringAsFixed(0)} km');
        return;
      }
    }

    // Try Hive (lightweight NoSQL - works better on AI boxes)
    if (_hive.isAvailable) {
      try {
        final lastSession = await _hive.getLastCompletedSession();
        if (lastSession != null && lastSession.endOdometer != null) {
          _previousSessionEndOdometer = lastSession.endOdometer;
          _logger.log('[Charging] Loaded previous session odometer from Hive: ${_previousSessionEndOdometer?.toStringAsFixed(0)} km');
          return;
        }
      } catch (e) {
        _logger.log('[Charging] Hive load failed: $e');
      }
    }

    // Try SQLite database
    if (_db.isAvailable) {
      try {
        final lastSession = await _db.getLastCompletedSession();
        if (lastSession != null && lastSession.endOdometer != null) {
          _previousSessionEndOdometer = lastSession.endOdometer;
          _logger.log('[Charging] Loaded previous session odometer from SQLite: ${_previousSessionEndOdometer?.toStringAsFixed(0)} km');
          return;
        }
      } catch (e) {
        _logger.log('[Charging] SQLite load failed: $e');
      }
    }

    // Try SharedPreferences
    try {
      final sessions = await _loadSessionsFromPrefs();
      if (sessions.isNotEmpty) {
        sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
        final lastCompleted = sessions.where((s) => !s.isActive && s.endOdometer != null).firstOrNull;
        if (lastCompleted != null) {
          _previousSessionEndOdometer = lastCompleted.endOdometer;
          _logger.log('[Charging] Loaded previous session odometer from SharedPreferences: ${_previousSessionEndOdometer?.toStringAsFixed(0)} km');
          return;
        }
      }
    } catch (e) {
      _logger.log('[Charging] SharedPreferences load failed: $e');
    }

    // Final fallback to file storage
    try {
      final sessions = await _loadSessionsFromFile();
      if (sessions.isNotEmpty) {
        sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
        final lastCompleted = sessions.where((s) => !s.isActive && s.endOdometer != null).firstOrNull;
        if (lastCompleted != null) {
          _previousSessionEndOdometer = lastCompleted.endOdometer;
          _logger.log('[Charging] Loaded previous session odometer from file: ${_previousSessionEndOdometer?.toStringAsFixed(0)} km');
          return;
        }
      }
    } catch (e) {
      _logger.log('[Charging] File load failed: $e');
    }

    _logger.log('[Charging] No previous session found for odometer reference');
  }

  /// Find the last session with a DIFFERENT odometer than the current session
  /// This handles the case where multiple charges happen at the same location
  /// (e.g., charging at home twice without driving)
  Future<double?> _findLastDifferentOdometer(double currentOdometer) async {
    final allSessions = await getAllSessions();
    if (allSessions.isEmpty) return null;

    // Sort by time, most recent first
    allSessions.sort((a, b) => b.startTime.compareTo(a.startTime));

    // Tolerance for "same location" - within 1 km is considered same spot
    const double odometerTolerance = 1.0;

    for (final session in allSessions) {
      if (!session.isActive && session.endOdometer != null) {
        final difference = (currentOdometer - session.endOdometer!).abs();
        if (difference > odometerTolerance) {
          _logger.log('[Charging] Found previous different odometer: ${session.endOdometer?.toStringAsFixed(0)} km '
              '(${difference.toStringAsFixed(1)} km difference)');
          return session.endOdometer;
        }
      }
    }

    _logger.log('[Charging] No session found with different odometer');
    return null;
  }

  /// Get battery capacity from settings (cached after first load)
  /// Returns capacity in kWh based on vehicle model from settings
  Future<double> _getBatteryCapacityKwh() async {
    if (_batteryCapacityKwh != null) return _batteryCapacityKwh!;

    try {
      final prefs = await SharedPreferences.getInstance();
      final vehicleModel = prefs.getString('vehicle_model') ?? '24LR';
      _batteryCapacityKwh = vehicleBatteryCapacities[vehicleModel] ?? 87.5;
      _logger.log('[Charging] Battery capacity for $vehicleModel: $_batteryCapacityKwh kWh');
    } catch (e) {
      _batteryCapacityKwh = 87.5; // Default to G6 Long Range
      _logger.log('[Charging] Failed to load battery capacity, using default: $_batteryCapacityKwh kWh');
    }
    return _batteryCapacityKwh!;
  }

  /// Process new vehicle data to detect charging state changes
  ///
  /// SIMPLIFIED LOGIC: Only use HV battery current (power) for charging detection.
  /// - Charging = HV current is NEGATIVE (< -0.5A) AND speed = 0 for 2+ samples
  /// - Not charging = HV current is >= 0 (positive or zero)
  ///
  /// BMS_CHG_STATUS and CHARGING PIDs are IGNORED because they remain active
  /// when the cable is plugged in but charging has stopped.
  void processVehicleData(VehicleData data) {
    // Track last known odometer (use any non-zero value)
    if (data.odometer != null && data.odometer! > 0) {
      _lastKnownOdometer = data.odometer;
    }

    // Get vehicle speed - used to filter out regen braking
    final currentSpeed = data.speed ?? 0.0;
    final isStationary = currentSpeed < _maxSpeedForCharging;

    // Track consecutive stationary samples to avoid false positives from regen braking
    if (isStationary) {
      _stationarySampleCount++;
    } else {
      _stationarySampleCount = 0;
    }
    final isConfirmedStationary = _stationarySampleCount >= _requiredStationarySamples;

    // Get HV battery current (HV_A) - NEGATIVE means charging, POSITIVE means discharging
    // This is the ONLY reliable indicator - AC/DC charger PIDs are stale!
    final hvCurrent = data.batteryCurrent;

    // Debug: log charging-related values (before detection)
    _logger.log('[Charging] HV_A=${hvCurrent?.toStringAsFixed(2) ?? "null"}, speed=${currentSpeed.toStringAsFixed(1)}, wasCharging=$_isCharging');

    ChargingType detectedType = ChargingType.none;
    double detectedPower = 0.0;
    String detectionReason = '';

    // Max AC charging power for XPENG G6 - anything above this must be DC
    const double maxAcPowerKw = 11.5; // Slightly above 11kW to allow for measurement variance
    // =======================================================================
    // CHARGING DETECTION STRATEGY
    // =======================================================================
    // PRIMARY: HV battery current (batteryCurrent / HV_A)
    //   - Negative current = energy flowing INTO battery = CHARGING
    //   - This is the ONLY reliable indicator that resets when charging stops
    //   - Example: -11A during 7.4kW AC charging
    //
    // UNRELIABLE - DO NOT USE FOR DETECTION:
    //   - BMS_CHG_STATUS: Shows 2 (DC) during AC charging, stays stale after unplug
    //   - DC_CHG_A/V: Shows 389A from previous DC charge during current AC charge!
    //   - AC_CHG_A/V: Values may be stale after charging stops
    //
    // TYPE DETERMINATION (once charging is confirmed via HV current):
    //   - Power > 11kW = DC charging
    //   - Power <= 11kW = AC charging
    // =======================================================================

    // PRIMARY INDICATOR: HV battery current - negative = charging
    final bool hvIndicatesCharging = hvCurrent != null && hvCurrent < -_chargingCurrentThreshold;

    // Calculate power from HV current (this is the reliable power reading)
    final double hvChargePowerKw = (hvCurrent != null && hvCurrent < 0 && data.batteryVoltage != null)
        ? (hvCurrent.abs() * data.batteryVoltage!) / 1000.0
        : 0.0;

    // SECONDARY: Power field (same calculation, just pre-computed)
    final bool powerIndicatesCharging = (data.power ?? 0) < -0.5;

    // Combined charging detection
    final bool isActivelyCharging = (hvIndicatesCharging || powerIndicatesCharging) && isConfirmedStationary;

    if (isActivelyCharging) {
      // Charging confirmed - determine type from power level
      // XPENG G6 max AC is 11kW, so anything above that is DC
      if (hvChargePowerKw > maxAcPowerKw) {
        detectedType = ChargingType.dc;
        detectedPower = hvChargePowerKw;
        detectionReason = 'DC charging: HV=${hvCurrent?.toStringAsFixed(1)}A × ${data.batteryVoltage?.toStringAsFixed(0)}V = ${hvChargePowerKw.toStringAsFixed(1)} kW';
      } else {
        detectedType = ChargingType.ac;
        detectedPower = hvChargePowerKw;
        detectionReason = 'AC charging: HV=${hvCurrent?.toStringAsFixed(1)}A × ${data.batteryVoltage?.toStringAsFixed(0)}V = ${hvChargePowerKw.toStringAsFixed(1)} kW';
      }
    } else if (_isCharging && !isActivelyCharging) {
      // Was charging but HV current is now 0 or positive - charging stopped
      _logger.log('[Charging] Charging stopped: HV_A=${hvCurrent?.toStringAsFixed(1) ?? "null"}A, power=${data.power?.toStringAsFixed(1) ?? "null"}kW');
      detectedType = ChargingType.none;
      detectedPower = 0.0;
    }
    // If not charging and wasn't charging, type stays as none

    // Debug: log detection result
    _logger.log('[Charging] Detection: hvChg=$hvIndicatesCharging, pwrChg=$powerIndicatesCharging, stationary=$isConfirmedStationary, type=${detectedType.name}');
    _logger.log('[Charging] Values: HV_A=${hvCurrent?.toStringAsFixed(1) ?? "null"}A, power=${data.power?.toStringAsFixed(1) ?? "null"}kW, hvPower=${hvChargePowerKw.toStringAsFixed(1)}kW');

    final wasCharging = _isCharging;
    final isNowCharging = detectedType != ChargingType.none;

    // Track consecutive non-charging samples for reliable end detection
    if (!isNowCharging && wasCharging) {
      _nonChargingSampleCount++;
      _logger.log('[Charging] Non-charging sample ${_nonChargingSampleCount}/${_requiredNonChargingSamples}');
    } else if (isNowCharging) {
      _nonChargingSampleCount = 0;
    }

    // Determine if we should consider charging as stopped
    // Require multiple consecutive non-charging samples to avoid false stops
    final shouldStopCharging = wasCharging && !isNowCharging &&
        _nonChargingSampleCount >= _requiredNonChargingSamples;

    // Update state
    if (isNowCharging) {
      _isCharging = true;
      _chargingType = detectedType;
      _chargePowerKw = detectedPower;
    } else if (shouldStopCharging) {
      _isCharging = false;
      _chargingType = ChargingType.none;
      _chargePowerKw = 0.0;
      _nonChargingSampleCount = 0; // Reset counter after stopping
    }
    // If transitioning from charging to not charging but haven't hit threshold, keep previous state

    // Log state changes
    if (!wasCharging && isNowCharging) {
      _logger.log('[Charging] === STARTED ===');
      _logger.log('[Charging] Type: ${_chargingType.name.toUpperCase()}, Power: ${_chargePowerKw.toStringAsFixed(1)} kW');
      _logger.log('[Charging] Reason: $detectionReason');
    } else if (shouldStopCharging) {
      _logger.log('[Charging] === STOPPED ===');
      _logger.log('[Charging] Confirmed after ${_requiredNonChargingSamples} non-charging samples');
    }

    // Handle state transitions
    if (!wasCharging && isNowCharging) {
      _startNewSession(data, detectedType, detectedPower);
    } else if (shouldStopCharging) {
      _completeSession(data);
    } else if (_isCharging && _currentSession != null) {
      _updateActiveSession(data, detectedType, detectedPower);
    } else if (_isCharging && _currentSession == null && isNowCharging) {
      // App started while already charging - create session retroactively
      _logger.log('[Charging] === RETROACTIVE START (app launched during charging) ===');
      _startNewSession(data, detectedType, detectedPower);
    }

    // Update last cumulative charge and voltage
    if (data.cumulativeCharge != null) {
      _lastCumulativeCharge = data.cumulativeCharge;
    }
    if (data.batteryVoltage != null) {
      _lastVoltage = data.batteryVoltage;
    }
  }

  /// Helper to extract double value from properties
  double? _getDoubleValue(Map<String, dynamic> props, String key) {
    final value = props[key];
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  /// Start a new charging session
  void _startNewSession(VehicleData data, ChargingType type, double powerKw) {
    final sessionId = 'charge_${DateTime.now().millisecondsSinceEpoch}';
    final startCumulative = _lastCumulativeCharge ?? data.cumulativeCharge ?? 0;

    // Reset energy accumulation for new session
    _accumulatedEnergyKwh = 0.0;
    _lastPowerSampleTime = data.timestamp;

    // Initialize peak SOC tracking with start SOC
    _peakSocDuringSession = data.stateOfCharge ?? 0;

    // Reset charging curve samples for new session
    _currentSessionSamples = [];
    _lastCurveSampleTime = null;
    _lastSampledSoc = null;

    // Take initial sample immediately
    _collectChargingCurveSample(data, powerKw);

    // Use current odometer, or fall back to last known odometer if current is null/0
    final currentOdo = data.odometer;
    final startOdo = (currentOdo != null && currentOdo > 0) ? currentOdo : (_lastKnownOdometer ?? 0);

    // Try to get current GPS location for the charging session
    double? latitude;
    double? longitude;
    final lastLocation = _locationService.lastLocation;
    if (lastLocation != null) {
      latitude = lastLocation.latitude;
      longitude = lastLocation.longitude;
      _logger.log('[Charging] Location from cache: ${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}');
    } else {
      // Try to get current location asynchronously (won't block session creation)
      _captureLocationForSession(sessionId);
    }

    _currentSession = ChargingSession(
      id: sessionId,
      startTime: data.timestamp,
      startCumulativeCharge: startCumulative,
      startSoc: data.stateOfCharge ?? 0,
      startOdometer: startOdo,
      isActive: true,
      chargingType: type.name,
      maxPowerKw: powerKw,
      latitude: latitude,
      longitude: longitude,
    );

    _logger.log('[Charging] Session: $sessionId');
    _logger.log('[Charging] Type: ${type.name.toUpperCase()}, SOC: ${data.stateOfCharge?.toStringAsFixed(1)}%');
    _logger.log('[Charging] Odometer: ${startOdo.toStringAsFixed(1)} km (data=${currentOdo?.toStringAsFixed(1) ?? "null"}, lastKnown=${_lastKnownOdometer?.toStringAsFixed(1) ?? "null"}), prev session end: ${_previousSessionEndOdometer?.toStringAsFixed(1) ?? "null"} km');
    if (latitude != null && longitude != null) {
      _logger.log('[Charging] GPS: ${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}');
    }

    _sessionController.add(_currentSession!);

    // Publish START event to MQTT
    _publishSessionToMqtt(
      _currentSession!,
      status: 'START',
      currentOdometer: startOdo,
    );

    // Publish charging started notification
    _mqttService?.publishChargingNotification(
      event: 'CHARGE_STARTED',
      soc: data.stateOfCharge ?? 0,
      chargingType: type.name,
      powerKw: powerKw,
    );
  }

  /// Capture GPS location asynchronously and update session
  /// Retries multiple times with delay to allow GPS to get a fix
  Future<void> _captureLocationForSession(String sessionId) async {
    const maxRetries = 5;
    const retryDelayMs = 2000; // 2 seconds between retries

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        _logger.log('[Charging] GPS location attempt $attempt/$maxRetries for session $sessionId...');

        // First check if we already have a cached location
        var location = _locationService.lastLocation;

        // If no cached location, request a fresh one
        if (location == null) {
          location = await _locationService.getCurrentLocation();
        }

        if (location != null && _currentSession != null && _currentSession!.id == sessionId) {
          // Update the current session with location, preserving all other fields
          _currentSession = ChargingSession(
            id: _currentSession!.id,
            startTime: _currentSession!.startTime,
            startCumulativeCharge: _currentSession!.startCumulativeCharge,
            startSoc: _currentSession!.startSoc,
            startOdometer: _currentSession!.startOdometer,
            isActive: _currentSession!.isActive,
            chargingType: _currentSession!.chargingType,
            maxPowerKw: _currentSession!.maxPowerKw,
            latitude: location.latitude,
            longitude: location.longitude,
          );
          _logger.log('[Charging] GPS location captured: ${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}');
          return; // Success - exit retry loop
        } else if (_currentSession == null || _currentSession!.id != sessionId) {
          _logger.log('[Charging] Session $sessionId no longer active, stopping GPS capture');
          return; // Session ended, no point continuing
        }

        // Wait before next retry
        if (attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: retryDelayMs));
        }
      } catch (e) {
        _logger.log('[Charging] GPS attempt $attempt failed: $e');
        if (attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: retryDelayMs));
        }
      }
    }

    _logger.log('[Charging] Failed to capture GPS location after $maxRetries attempts');
  }

  /// Look up the charger name from OpenChargeMap based on GPS coordinates
  /// Returns the charger display name if found within 100m, or null if not found
  Future<String?> _lookupChargerName(double latitude, double longitude) async {
    try {
      final ocmService = OpenChargeMapService.instance;

      // Search within 100m radius for the nearest charger
      final station = await ocmService.findNearestStation(
        latitude,
        longitude,
        radiusKm: 0.1, // 100 meters
      );

      if (station != null) {
        _logger.log('[Charging] Found charger: ${station.displayName} (${station.distanceKm?.toStringAsFixed(3) ?? "?"}km away)');
        return station.displayName;
      }

      _logger.log('[Charging] No charger found within 100m of location');
      return null;
    } catch (e) {
      _logger.log('[Charging] OpenChargeMap lookup failed: $e');
      return null;
    }
  }

  /// Complete the current charging session
  Future<void> _completeSession(VehicleData data) async {
    if (_currentSession == null) return;

    // Do one final energy accumulation with current power before completing
    if (_lastPowerSampleTime != null && _chargePowerKw > 0) {
      final intervalSeconds = data.timestamp.difference(_lastPowerSampleTime!).inSeconds;
      if (intervalSeconds > 0 && intervalSeconds < 120) {
        final energyIncrement = _chargePowerKw * (intervalSeconds / 3600.0);
        _accumulatedEnergyKwh += energyIncrement;
      }
    }

    // Take final charging curve sample
    _collectChargingCurveSample(data, _chargePowerKw);
    _logger.log('[Charging] Curve complete with ${_currentSessionSamples.length} samples');

    // Use peak SOC if it's higher than final sample (handles stale end-of-session data)
    final finalSoc = data.stateOfCharge ?? _currentSession!.startSoc;
    final effectiveEndSoc = (_peakSocDuringSession > finalSoc) ? _peakSocDuringSession : finalSoc;

    if (_peakSocDuringSession > finalSoc) {
      _logger.log('[Charging] Using peak SOC ${_peakSocDuringSession.toStringAsFixed(1)}% instead of final ${finalSoc.toStringAsFixed(1)}%');
    }

    // Use current odometer, or fall back to last known odometer if current is null/0
    final currentOdo = data.odometer;
    final endOdo = (currentOdo != null && currentOdo > 0) ? currentOdo : _lastKnownOdometer;

    // Determine the correct previous odometer for consumption calculation
    // If the last session's odometer is the same as current (multiple charges at same location),
    // look further back to find a session where we actually drove
    double? effectivePreviousOdometer = _previousSessionEndOdometer;
    final startOdo = _currentSession!.startOdometer;

    if (_previousSessionEndOdometer != null) {
      final distanceFromLastSession = (startOdo - _previousSessionEndOdometer!).abs();
      if (distanceFromLastSession < 1.0) {
        // Last session was at same location - find an earlier session with different odometer
        _logger.log('[Charging] Same location as last charge (${distanceFromLastSession.toStringAsFixed(1)} km diff), looking further back...');
        effectivePreviousOdometer = await _findLastDifferentOdometer(startOdo);
      }
    }

    var completedSession = _currentSession!.complete(
      endTime: data.timestamp,
      endCumulativeCharge: data.cumulativeCharge ?? _currentSession!.startCumulativeCharge,
      endSoc: effectiveEndSoc,
      endOdometer: endOdo,
      averageVoltage: _lastVoltage,
      previousOdometer: effectivePreviousOdometer,
      chargingCurve: _currentSessionSamples.isNotEmpty ? List.from(_currentSessionSamples) : null,
    );

    // Use accumulated energy if energyAddedKwh is null or zero
    // This provides energy estimate from power integration when cumulative charge PID isn't available
    if ((completedSession.energyAddedKwh == null || completedSession.energyAddedKwh == 0) &&
        _accumulatedEnergyKwh > 0.1) {
      _logger.log('[Charging] Using accumulated energy: ${_accumulatedEnergyKwh.toStringAsFixed(2)} kWh');
      completedSession = completedSession.copyWith(energyAddedKwh: _accumulatedEnergyKwh);
    }

    // Third fallback: Estimate from SOC change and battery capacity
    // Battery capacities by model (usable kWh):
    // - XPENG G6: 87.5 kWh
    // - XPENG G9: 98 kWh
    // - XPENG P7: 80.9 kWh
    final double batteryCapacityKwh = await _getBatteryCapacityKwh();
    if ((completedSession.energyAddedKwh == null || completedSession.energyAddedKwh == 0) &&
        completedSession.socGained != null && completedSession.socGained! > 0) {
      final estimatedKwh = (completedSession.socGained! / 100.0) * batteryCapacityKwh;
      _logger.log('[Charging] Estimating energy from SOC: ${completedSession.socGained!.toStringAsFixed(1)}% × $batteryCapacityKwh kWh = ${estimatedKwh.toStringAsFixed(2)} kWh');
      completedSession = completedSession.copyWith(energyAddedKwh: estimatedKwh);
    }

    _logger.log('[Charging] === SESSION COMPLETE ===');
    _logger.log('[Charging] Type: ${completedSession.chargingType?.toUpperCase() ?? "unknown"}');
    _logger.log('[Charging] Duration: ${completedSession.duration}');
    _logger.log('[Charging] Peak SOC during session: ${_peakSocDuringSession.toStringAsFixed(1)}%');
    _logger.log('[Charging] Energy: ${completedSession.energyAddedAh?.toStringAsFixed(2)} Ah');
    _logger.log('[Charging] Energy: ${completedSession.energyAddedKwh?.toStringAsFixed(2)} kWh (accumulated: ${_accumulatedEnergyKwh.toStringAsFixed(2)} kWh)');
    _logger.log('[Charging] SOC: ${completedSession.startSoc.toStringAsFixed(1)}% -> ${completedSession.endSoc?.toStringAsFixed(1)}%');
    _logger.log('[Charging] Odometer: start=${completedSession.startOdometer.toStringAsFixed(1)}, end=${completedSession.endOdometer?.toStringAsFixed(1) ?? "null"}, prevEnd=${completedSession.previousSessionOdometer?.toStringAsFixed(1) ?? "null"} km');
    _logger.log('[Charging] Max Power: ${completedSession.maxPowerKw?.toStringAsFixed(1)} kW');
    if (completedSession.latitude != null && completedSession.longitude != null) {
      _logger.log('[Charging] Location: ${completedSession.latitude!.toStringAsFixed(5)}, ${completedSession.longitude!.toStringAsFixed(5)}');
    }

    // Look up charger name from OpenChargeMap if we have GPS coordinates and no location name yet
    if (completedSession.latitude != null &&
        completedSession.longitude != null &&
        completedSession.locationName == null) {
      final chargerName = await _lookupChargerName(
        completedSession.latitude!,
        completedSession.longitude!,
      );
      if (chargerName != null) {
        completedSession = completedSession.copyWith(locationName: chargerName);
        _logger.log('[Charging] Location name from OpenChargeMap: $chargerName');
      }
    }

    // Reset peak SOC tracker (after logging)
    _peakSocDuringSession = 0.0;
    if (completedSession.distanceSinceLastCharge != null) {
      _logger.log('[Charging] Distance since last charge: ${completedSession.distanceSinceLastCharge?.toStringAsFixed(1)} km');
    }
    if (completedSession.consumptionKwhPer100km != null) {
      _logger.log('[Charging] Consumption: ${completedSession.consumptionKwhPer100km?.toStringAsFixed(1)} kWh/100km');
    }

    // Determine if session is worth saving - stricter criteria to avoid false positives:
    // Must meet MINIMUM DURATION (2 minutes) AND at least one of:
    // 1. Energy added (kWh) >= 0.5 kWh
    // 2. SOC gained >= 1.0%
    // This prevents brief stops or regen events from creating false charging sessions
    // Note: Min AC charging is 6A @ 240V = 1.44kW, so 2 mins would add ~0.05 kWh minimum
    final energyKwh = completedSession.energyAddedKwh ?? _accumulatedEnergyKwh;
    final socGained = completedSession.socGained ?? 0;
    final durationSecs = completedSession.duration?.inSeconds ?? 0;
    final maxPower = completedSession.maxPowerKw ?? 0;

    final hasMinDuration = durationSecs >= _minSessionDurationSeconds;
    final hasSignificantEnergy = energyKwh >= _minEnergyKwhForSave;
    final hasSignificantSocGain = socGained >= _minSocGainForSave;

    // Must have minimum duration AND either significant energy or SOC gain
    final shouldSave = hasMinDuration && (hasSignificantEnergy || hasSignificantSocGain);
    _logger.log('[Charging] Save criteria: duration=${durationSecs}s (>=$_minSessionDurationSeconds s?$hasMinDuration), '
        'energyKwh=${energyKwh.toStringAsFixed(2)} (>=$_minEnergyKwhForSave?$hasSignificantEnergy), '
        'socGain=${socGained.toStringAsFixed(1)}% (>=$_minSocGainForSave%?$hasSignificantSocGain), '
        'maxPower=${maxPower.toStringAsFixed(1)}kW => SAVE?$shouldSave');

    if (shouldSave) {
      // Always save to in-memory storage first (works everywhere)
      _saveSessionToMemory(completedSession);

      // Try Hive (lightweight NoSQL - best for AI boxes)
      if (_hive.isAvailable) {
        try {
          await _hive.saveChargingSession(completedSession);
          _logger.log('[Charging] Session ${completedSession.id} saved to Hive successfully');
        } catch (e) {
          _logger.log('[Charging] Hive save failed: $e');
        }
      }

      // Try SQLite database (usually fails on AAOS)
      if (_db.isAvailable) {
        try {
          await _db.insertChargingSession(completedSession);
          _logger.log('[Charging] Session ${completedSession.id} saved to SQLite successfully');
        } catch (e) {
          _logger.log('[Charging] SQLite save failed: $e');
        }
      }

      // Try SharedPreferences (may fail on AAOS)
      try {
        await _saveSessionToPrefs(completedSession);
      } catch (e) {
        _logger.log('[Charging] SharedPreferences save failed: $e');
      }

      // Update previous session odometer for next consumption calculation
      if (completedSession.endOdometer != null) {
        _previousSessionEndOdometer = completedSession.endOdometer;
      }

      _sessionController.add(completedSession);

      // MQTT is the reliable sync method on AAOS - always publish
      _publishSessionToMqtt(
        completedSession,
        status: 'STOP',
        currentOdometer: completedSession.endOdometer,
      );

      // Publish charging stopped notification
      _mqttService?.publishChargingNotification(
        event: 'CHARGE_STOPPED',
        soc: completedSession.endSoc ?? completedSession.startSoc,
        chargingType: completedSession.chargingType,
        powerKw: completedSession.maxPowerKw,
        locationName: completedSession.locationName,
      );
      _logger.log('[Charging] Session saved and published to MQTT');
    } else {
      _logger.log('[Charging] Discarded - no significant charging detected');
    }

    // Reset accumulated energy for next session
    _accumulatedEnergyKwh = 0.0;
    _lastPowerSampleTime = null;

    // Clear charging curve samples
    _currentSessionSamples = [];
    _lastCurveSampleTime = null;
    _lastSampledSoc = null;

    _currentSession = null;
  }

  /// Update active session with current values
  /// Collect a charging curve sample for visualization
  /// Samples are taken every 30 seconds or when SOC changes by 0.5%+
  void _collectChargingCurveSample(VehicleData data, double powerKw) {
    final now = data.timestamp;
    final currentSoc = data.stateOfCharge ?? 0;

    // Check if we should take a sample
    bool shouldSample = false;

    if (_lastCurveSampleTime == null) {
      // First sample - always take it
      shouldSample = true;
    } else {
      final secondsSinceLastSample = now.difference(_lastCurveSampleTime!).inSeconds;

      // Sample if interval elapsed
      if (secondsSinceLastSample >= _curveSampleIntervalSeconds) {
        shouldSample = true;
      }

      // Or sample if SOC changed significantly
      if (_lastSampledSoc != null &&
          (currentSoc - _lastSampledSoc!).abs() >= _minSocChangeForSample) {
        shouldSample = true;
      }
    }

    if (!shouldSample) return;

    // Enforce max samples limit
    if (_currentSessionSamples.length >= _maxSamplesPerSession) {
      return;
    }

    // Create and store the sample
    final sample = ChargingSample(
      timestamp: now,
      soc: currentSoc,
      powerKw: powerKw,
      temperature: data.batteryTemperature,
      voltage: data.batteryVoltage,
      current: data.batteryCurrent,
    );

    _currentSessionSamples.add(sample);
    _lastCurveSampleTime = now;
    _lastSampledSoc = currentSoc;

    _logger.log('[Charging] Curve sample #${_currentSessionSamples.length}: '
        'SOC=${currentSoc.toStringAsFixed(1)}%, Power=${powerKw.toStringAsFixed(1)}kW');
  }

  void _updateActiveSession(VehicleData data, ChargingType type, double powerKw) {
    if (_currentSession == null) return;

    // Accumulate energy: power × time interval
    // This provides energy estimate when cumulative charge PID isn't available
    if (_lastPowerSampleTime != null && powerKw > 0) {
      final intervalSeconds = data.timestamp.difference(_lastPowerSampleTime!).inSeconds;
      if (intervalSeconds > 0 && intervalSeconds < 120) {
        // Only accumulate if interval is reasonable (< 2 minutes)
        final energyIncrement = powerKw * (intervalSeconds / 3600.0); // kWh = kW × hours
        _accumulatedEnergyKwh += energyIncrement;
      }
    }
    _lastPowerSampleTime = data.timestamp;

    // Track peak SOC during session (handles stale data at session end)
    final currentSoc = data.stateOfCharge ?? 0;
    if (currentSoc > _peakSocDuringSession) {
      _peakSocDuringSession = currentSoc;
    }

    // Collect charging curve sample (for visualization)
    _collectChargingCurveSample(data, powerKw);

    // Update max power if current power is higher
    // IMPORTANT: Preserve latitude/longitude when recreating the session object
    if (powerKw > (_currentSession!.maxPowerKw ?? 0)) {
      _currentSession = ChargingSession(
        id: _currentSession!.id,
        startTime: _currentSession!.startTime,
        startCumulativeCharge: _currentSession!.startCumulativeCharge,
        startSoc: _currentSession!.startSoc,
        startOdometer: _currentSession!.startOdometer,
        isActive: true,
        chargingType: type.name,
        maxPowerKw: powerKw,
        latitude: _currentSession!.latitude,   // Preserve location
        longitude: _currentSession!.longitude, // Preserve location
      );
    }

    final currentCharge = data.cumulativeCharge ?? _currentSession!.startCumulativeCharge;
    final energyAdded = currentCharge - _currentSession!.startCumulativeCharge;

    _logger.log('[Charging] ${type.name.toUpperCase()} ${powerKw.toStringAsFixed(1)}kW, '
        'SOC=${data.stateOfCharge?.toStringAsFixed(1)}%, +${energyAdded.toStringAsFixed(2)}Ah, '
        'accumulated=${_accumulatedEnergyKwh.toStringAsFixed(2)}kWh');

    // Publish UPDATE to MQTT (throttled to every 30 seconds)
    final now = DateTime.now();
    if (_lastMqttUpdateTime == null ||
        now.difference(_lastMqttUpdateTime!).inSeconds >= _mqttUpdateIntervalSeconds) {
      _lastMqttUpdateTime = now;
      // Use current odometer, fall back to last known, then session start
      final currentOdo = data.odometer;
      final odoForUpdate = (currentOdo != null && currentOdo > 0)
          ? currentOdo
          : (_lastKnownOdometer ?? _currentSession!.startOdometer);
      _publishSessionToMqtt(
        _currentSession!,
        status: 'UPDATE',
        currentOdometer: odoForUpdate,
      );
    }
  }

  /// Publish charging session to MQTT with status
  /// [status] should be 'START', 'UPDATE', or 'STOP'
  /// [currentOdometer] is the current vehicle odometer
  void _publishSessionToMqtt(
    ChargingSession session, {
    required String status,
    double? currentOdometer,
  }) {
    if (_mqttService == null) {
      _logger.log('[Charging] Cannot publish to MQTT - service is null');
      return;
    }
    if (!_mqttService.isConnected) {
      _logger.log('[Charging] Cannot publish to MQTT - not connected');
      return;
    }
    _mqttService.publishChargingSession(
      session,
      status: status,
      currentOdometer: currentOdometer,
      previousSessionOdometer: _previousSessionEndOdometer,
    );
    _logger.log('[Charging] Published session ${session.id} to MQTT (status: $status)');
  }

  /// Sync all charging history to MQTT
  Future<void> syncHistoryToMqtt() async {
    if (_mqttService == null || !_mqttService.isConnected) {
      _logger.log('[Charging] Cannot sync - MQTT not connected');
      return;
    }

    try {
      final sessions = await getAllSessions();
      await _mqttService.publishChargingHistory(sessions);
      _logger.log('[Charging] Synced ${sessions.length} sessions to MQTT');
    } catch (e) {
      _logger.log('[Charging] Failed to sync history: $e');
    }
  }

  /// Manually end the current session
  void endCurrentSession(VehicleData? lastData) {
    if (_currentSession == null) return;
    if (lastData != null) {
      _completeSession(lastData);
    } else {
      _logger.log('[Charging] Session closed without data');
      _currentSession = null;
    }
  }

  /// Get current charging status as a string for display
  String getChargingStatusString() {
    if (!_isCharging) return 'Not charging';
    final typeStr = _chargingType == ChargingType.dc ? 'DC Fast'
        : _chargingType == ChargingType.ac ? 'AC' : 'Charging';
    return '$typeStr: ${_chargePowerKw.toStringAsFixed(1)} kW';
  }

  /// Get list of recent charging sessions
  /// Priority: in-memory > Hive > SQLite > SharedPreferences > file
  Future<List<ChargingSession>> getRecentSessions({int limit = 10}) async {
    // First check in-memory storage (always available)
    if (_inMemorySessions.isNotEmpty) {
      final sessions = _loadSessionsFromMemory();
      sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
      _logger.log('[Charging] Returning ${sessions.take(limit).length} sessions from in-memory storage');
      return sessions.take(limit).toList();
    }

    // Try Hive (lightweight NoSQL - best for AI boxes)
    if (_hive.isAvailable) {
      try {
        final sessions = await _hive.getChargingSessions(limit: limit);
        if (sessions.isNotEmpty) {
          _logger.log('[Charging] Returning ${sessions.length} sessions from Hive');
          return sessions;
        }
      } catch (e) {
        _logger.log('[Charging] Hive failed: $e');
      }
    }

    // Try SQLite database
    if (_db.isAvailable) {
      try {
        final sessions = await _db.getChargingSessions(limit: limit);
        if (sessions.isNotEmpty) {
          _logger.log('[Charging] Returning ${sessions.length} sessions from SQLite');
          return sessions;
        }
      } catch (e) {
        _logger.log('[Charging] SQLite failed: $e');
      }
    }

    // Try SharedPreferences
    try {
      final allSessions = await _loadSessionsFromPrefs();
      if (allSessions.isNotEmpty) {
        allSessions.sort((a, b) => b.startTime.compareTo(a.startTime));
        _logger.log('[Charging] Returning ${allSessions.take(limit).length} sessions from SharedPreferences');
        return allSessions.take(limit).toList();
      }
    } catch (e) {
      _logger.log('[Charging] SharedPreferences failed: $e');
    }

    // Fall back to file storage
    try {
      final allSessions = await _loadSessionsFromFile();
      if (allSessions.isNotEmpty) {
        allSessions.sort((a, b) => b.startTime.compareTo(a.startTime));
        _logger.log('[Charging] Returning ${allSessions.take(limit).length} sessions from file storage');
        return allSessions.take(limit).toList();
      }
    } catch (e) {
      _logger.log('[Charging] File storage failed: $e');
    }

    // Fall back to mock data if in mock mode
    final mockService = MockDataService.instance;
    if (mockService.isEnabled) {
      final mockSessions = mockService.getMockSessions();
      if (mockSessions.isNotEmpty) {
        mockSessions.sort((a, b) => b.startTime.compareTo(a.startTime));
        _logger.log('[Charging] Returning ${mockSessions.take(limit).length} mock sessions');
        return mockSessions.take(limit).toList();
      }
    }

    return [];
  }

  /// Get all charging sessions
  /// Priority: in-memory > Hive > SQLite > SharedPreferences > file
  Future<List<ChargingSession>> getAllSessions() async {
    // First check in-memory storage (always available)
    if (_inMemorySessions.isNotEmpty) {
      final sessions = _loadSessionsFromMemory();
      sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
      _logger.log('[Charging] Returning ${sessions.length} sessions from in-memory storage');
      return sessions;
    }

    // Try Hive
    if (_hive.isAvailable) {
      try {
        final sessions = await _hive.getChargingSessions();
        if (sessions.isNotEmpty) {
          _logger.log('[Charging] Returning ${sessions.length} sessions from Hive');
          return sessions;
        }
      } catch (e) {
        _logger.log('[Charging] Hive failed: $e');
      }
    }

    // Try SQLite database
    if (_db.isAvailable) {
      try {
        final sessions = await _db.getChargingSessions();
        if (sessions.isNotEmpty) {
          _logger.log('[Charging] Returning ${sessions.length} sessions from SQLite');
          return sessions;
        }
      } catch (e) {
        _logger.log('[Charging] SQLite failed: $e');
      }
    }

    // Try SharedPreferences
    try {
      final sessions = await _loadSessionsFromPrefs();
      if (sessions.isNotEmpty) {
        sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
        _logger.log('[Charging] Returning ${sessions.length} sessions from SharedPreferences');
        return sessions;
      }
    } catch (e) {
      _logger.log('[Charging] SharedPreferences failed: $e');
    }

    // Fall back to file storage
    try {
      final sessions = await _loadSessionsFromFile();
      if (sessions.isNotEmpty) {
        sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
        _logger.log('[Charging] Returning ${sessions.length} sessions from file storage');
        return sessions;
      }
    } catch (e) {
      _logger.log('[Charging] File storage failed: $e');
    }

    // Fall back to mock data if in mock mode
    final mockService = MockDataService.instance;
    if (mockService.isEnabled) {
      final mockSessions = mockService.getMockSessions();
      if (mockSessions.isNotEmpty) {
        mockSessions.sort((a, b) => b.startTime.compareTo(a.startTime));
        _logger.log('[Charging] Returning ${mockSessions.length} mock sessions');
        return mockSessions;
      }
    }

    return [];
  }

  /// Update a charging session (for manual edits like location, cost, notes)
  Future<bool> updateSession(ChargingSession session) async {
    // Always update in-memory first
    _saveSessionToMemory(session);

    // Try Hive
    if (_hive.isAvailable) {
      try {
        await _hive.saveChargingSession(session);
        _logger.log('[Charging] Session ${session.id} updated in Hive');
      } catch (e) {
        _logger.log('[Charging] Failed to update session in Hive: $e');
      }
    }

    // Try SQLite database
    if (_db.isAvailable) {
      try {
        await _db.updateChargingSession(session);
        _logger.log('[Charging] Session ${session.id} updated in SQLite');
      } catch (e) {
        _logger.log('[Charging] Failed to update session in SQLite: $e');
      }
    }

    // Try SharedPreferences
    try {
      await _saveSessionToPrefs(session);
    } catch (e) {
      _logger.log('[Charging] Failed to update session in SharedPreferences: $e');
    }

    _publishSessionToMqtt(
      session,
      status: 'UPDATE',
      currentOdometer: session.endOdometer ?? session.startOdometer,
    ); // Sync to MQTT
    return true;
  }

  /// Delete a charging session
  Future<bool> deleteSession(String sessionId) async {
    // Always delete from in-memory first
    _deleteSessionFromMemory(sessionId);

    // Try Hive
    if (_hive.isAvailable) {
      try {
        await _hive.deleteChargingSession(sessionId);
        _logger.log('[Charging] Session $sessionId deleted from Hive');
      } catch (e) {
        _logger.log('[Charging] Failed to delete session from Hive: $e');
      }
    }

    // Try SQLite database
    if (_db.isAvailable) {
      try {
        await _db.deleteChargingSession(sessionId);
        _logger.log('[Charging] Session $sessionId deleted from SQLite');
      } catch (e) {
        _logger.log('[Charging] Failed to delete session from SQLite: $e');
      }
    }

    // Try SharedPreferences
    try {
      await _deleteSessionFromPrefs(sessionId);
    } catch (e) {
      _logger.log('[Charging] Failed to delete session from SharedPreferences: $e');
    }

    return true;
  }

  /// Get charging statistics
  Future<Map<String, dynamic>> getStatistics() async {
    // First check in-memory storage (always available)
    if (_inMemorySessions.isNotEmpty) {
      _logger.log('[Charging] Calculating stats from ${_inMemorySessions.length} in-memory sessions');
      return _calculateStatsFromSessions(_inMemorySessions);
    }

    // Try Hive
    if (_hive.isAvailable) {
      try {
        final sessionCount = await _hive.getChargingSessionsCount();
        final totalEnergy = await _hive.getTotalEnergyCharged();
        final avgConsumption = await _hive.getAverageConsumption();

        if (sessionCount > 0) {
          _logger.log('[Charging] Returning stats from Hive');
          return {
            'sessionCount': sessionCount,
            'totalEnergyKwh': totalEnergy,
            'averageConsumptionKwhPer100km': avgConsumption,
          };
        }
      } catch (e) {
        _logger.log('[Charging] Hive stats failed: $e');
      }
    }

    // Try SQLite database
    if (_db.isAvailable) {
      try {
        final sessionCount = await _db.getChargingSessionsCount();
        final totalEnergy = await _db.getTotalEnergyCharged();
        final avgConsumption = await _db.getAverageConsumption();

        if (sessionCount > 0) {
          _logger.log('[Charging] Returning stats from SQLite');
          return {
            'sessionCount': sessionCount,
            'totalEnergyKwh': totalEnergy,
            'averageConsumptionKwhPer100km': avgConsumption,
          };
        }
      } catch (e) {
        _logger.log('[Charging] SQLite stats failed: $e');
      }
    }

    // Try SharedPreferences
    try {
      final sessions = await _loadSessionsFromPrefs();
      if (sessions.isNotEmpty) {
        _logger.log('[Charging] Returning stats from SharedPreferences');
        return _calculateStatsFromSessions(sessions);
      }
    } catch (e) {
      _logger.log('[Charging] SharedPreferences stats failed: $e');
    }

    // Fall back to file storage
    try {
      final sessions = await _loadSessionsFromFile();
      if (sessions.isNotEmpty) {
        _logger.log('[Charging] Returning stats from file storage');
        return _calculateStatsFromSessions(sessions);
      }
    } catch (e) {
      _logger.log('[Charging] File stats failed: $e');
    }

    return {
      'sessionCount': 0,
      'totalEnergyKwh': 0.0,
      'averageConsumptionKwhPer100km': null,
    };
  }

  /// Calculate statistics from a list of sessions
  Map<String, dynamic> _calculateStatsFromSessions(List<ChargingSession> sessions) {
    if (sessions.isEmpty) {
      return {
        'sessionCount': 0,
        'totalEnergyKwh': 0.0,
        'averageConsumptionKwhPer100km': null,
      };
    }

    final sessionCount = sessions.length;
    final totalEnergy = sessions
        .where((s) => s.energyAddedKwh != null)
        .fold<double>(0.0, (sum, s) => sum + s.energyAddedKwh!);

    final consumptionValues = sessions
        .where((s) => s.consumptionKwhPer100km != null && s.consumptionKwhPer100km! > 0)
        .map((s) => s.consumptionKwhPer100km!)
        .toList();
    final avgConsumption = consumptionValues.isNotEmpty
        ? consumptionValues.reduce((a, b) => a + b) / consumptionValues.length
        : null;

    return {
      'sessionCount': sessionCount,
      'totalEnergyKwh': totalEnergy,
      'averageConsumptionKwhPer100km': avgConsumption,
    };
  }

  // ==================== In-Memory Storage (AAOS Ultimate Fallback) ====================
  // On AAOS, all persistent storage APIs fail. Sessions are kept in memory
  // and synced to Home Assistant via MQTT for persistence.

  /// Save a session to in-memory storage
  void _saveSessionToMemory(ChargingSession session) {
    // Check if session already exists (update) or is new (add)
    final existingIndex = _inMemorySessions.indexWhere((s) => s.id == session.id);
    if (existingIndex >= 0) {
      _inMemorySessions[existingIndex] = session;
    } else {
      _inMemorySessions.add(session);
    }

    // Keep only last 100 sessions
    _inMemorySessions.sort((a, b) => b.startTime.compareTo(a.startTime));
    while (_inMemorySessions.length > 100) {
      _inMemorySessions.removeLast();
    }

    _logger.log('[Charging] Session saved to in-memory storage (${_inMemorySessions.length} total)');
  }

  /// Load sessions from in-memory storage
  List<ChargingSession> _loadSessionsFromMemory() {
    _logger.log('[Charging] Loaded ${_inMemorySessions.length} sessions from in-memory storage');
    return List.from(_inMemorySessions);
  }

  /// Delete a session from in-memory storage
  void _deleteSessionFromMemory(String sessionId) {
    _inMemorySessions.removeWhere((s) => s.id == sessionId);
    _logger.log('[Charging] Session $sessionId deleted from in-memory storage');
  }

  // ==================== SharedPreferences Storage ====================
  // May work on some Android devices but fails on AAOS

  /// Save a session to SharedPreferences
  Future<void> _saveSessionToPrefs(ChargingSession session) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<ChargingSession> sessions = await _loadSessionsFromPrefs();

      // Check if session already exists (update) or is new (add)
      final existingIndex = sessions.indexWhere((s) => s.id == session.id);
      if (existingIndex >= 0) {
        sessions[existingIndex] = session;
      } else {
        sessions.add(session);
      }

      // Keep only last 100 sessions to avoid storage bloat
      sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
      if (sessions.length > 100) {
        sessions = sessions.take(100).toList();
      }

      // Save to SharedPreferences as JSON string
      final jsonList = sessions.map((s) => s.toMap()).toList();
      await prefs.setString('charging_sessions', jsonEncode(jsonList));
      _logger.log('[Charging] Session saved to SharedPreferences (${sessions.length} total)');
    } catch (e) {
      _logger.log('[Charging] Failed to save session to SharedPreferences: $e');
      // Fall back to file storage
      await _saveSessionToFile(session);
    }
  }

  /// Load sessions from SharedPreferences
  Future<List<ChargingSession>> _loadSessionsFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString('charging_sessions');
      if (jsonString == null || jsonString.isEmpty) {
        _logger.log('[Charging] No sessions in SharedPreferences');
        return [];
      }

      final jsonList = jsonDecode(jsonString) as List;
      final sessions = jsonList
          .map((json) => ChargingSession.fromMap(Map<String, dynamic>.from(json)))
          .toList();
      _logger.log('[Charging] Loaded ${sessions.length} sessions from SharedPreferences');
      return sessions;
    } catch (e) {
      _logger.log('[Charging] Failed to load sessions from SharedPreferences: $e');
      return [];
    }
  }

  /// Delete a session from SharedPreferences
  Future<void> _deleteSessionFromPrefs(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessions = await _loadSessionsFromPrefs();
      sessions.removeWhere((s) => s.id == sessionId);

      final jsonList = sessions.map((s) => s.toMap()).toList();
      await prefs.setString('charging_sessions', jsonEncode(jsonList));
      _logger.log('[Charging] Session $sessionId deleted from SharedPreferences');
    } catch (e) {
      _logger.log('[Charging] Failed to delete session from SharedPreferences: $e');
    }
  }

  // ==================== File-based Storage Fallback ====================
  // Used as secondary fallback if SharedPreferences also fails

  /// Get the file path for charging sessions storage
  /// Uses multiple fallback strategies for AAOS compatibility
  Future<File> _getSessionsFile() async {
    // Try path_provider methods first
    try {
      final directory = await getExternalStorageDirectory();
      if (directory != null) {
        return File('${directory.path}/charging_sessions.json');
      }
    } catch (e) {
      _logger.log('[Charging] getExternalStorageDirectory failed: $e');
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      return File('${directory.path}/charging_sessions.json');
    } catch (e) {
      _logger.log('[Charging] getApplicationDocumentsDirectory failed: $e');
    }

    // Try cache directory (often accessible when others aren't)
    try {
      final directory = await getTemporaryDirectory();
      _logger.log('[Charging] Using temp directory: ${directory.path}');
      return File('${directory.path}/charging_sessions.json');
    } catch (e) {
      _logger.log('[Charging] getTemporaryDirectory failed: $e');
    }

    // Android 13+ fallback: use internal app data directory (always accessible)
    // This is the most reliable path on modern Android
    const internalPath = '/data/data/com.example.carsoc/files/charging_sessions.json';
    try {
      _logger.log('[Charging] Trying internal path: $internalPath');
      final file = File(internalPath);
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      _logger.log('[Charging] Internal path accessible: $internalPath');
      return file;
    } catch (e) {
      _logger.log('[Charging] Internal path failed: $internalPath - $e');
    }

    // AAOS/external fallback paths
    const fallbackPaths = [
      '/sdcard/Android/data/com.example.carsoc/files/charging_sessions.json',
      '/storage/emulated/0/Android/data/com.example.carsoc/files/charging_sessions.json',
    ];

    for (final fallbackPath in fallbackPaths) {
      try {
        _logger.log('[Charging] Trying fallback path: $fallbackPath');
        final file = File(fallbackPath);
        final parent = file.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
        // Test if we can write
        await file.writeAsString('[]');
        _logger.log('[Charging] Fallback path works: $fallbackPath');
        return file;
      } catch (e) {
        _logger.log('[Charging] Fallback path failed: $fallbackPath - $e');
      }
    }

    // Last resort: return internal path that should at least be writable
    _logger.log('[Charging] WARNING: Using last resort internal path');
    return File(internalPath);
  }

  /// Save a session to file storage (secondary fallback)
  Future<void> _saveSessionToFile(ChargingSession session) async {
    try {
      final file = await _getSessionsFile();
      List<ChargingSession> sessions = await _loadSessionsFromFile();

      // Check if session already exists (update) or is new (add)
      final existingIndex = sessions.indexWhere((s) => s.id == session.id);
      if (existingIndex >= 0) {
        sessions[existingIndex] = session;
      } else {
        sessions.add(session);
      }

      // Keep only last 100 sessions to avoid file bloat
      sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
      if (sessions.length > 100) {
        sessions = sessions.take(100).toList();
      }

      // Write to file
      final jsonList = sessions.map((s) => s.toMap()).toList();
      await file.writeAsString(jsonEncode(jsonList));
      _logger.log('[Charging] Session saved to file: ${file.path}');
    } catch (e) {
      _logger.log('[Charging] Failed to save session to file: $e');
    }
  }

  /// Load sessions from file storage
  Future<List<ChargingSession>> _loadSessionsFromFile() async {
    try {
      final file = await _getSessionsFile();
      if (!await file.exists()) {
        _logger.log('[Charging] Sessions file does not exist yet');
        return [];
      }

      final jsonString = await file.readAsString();
      final jsonList = jsonDecode(jsonString) as List;
      final sessions = jsonList
          .map((json) => ChargingSession.fromMap(Map<String, dynamic>.from(json)))
          .toList();
      _logger.log('[Charging] Loaded ${sessions.length} sessions from file');
      return sessions;
    } catch (e) {
      _logger.log('[Charging] Failed to load sessions from file: $e');
      return [];
    }
  }

  /// Delete a session from file storage
  Future<void> _deleteSessionFromFile(String sessionId) async {
    try {
      final file = await _getSessionsFile();
      final sessions = await _loadSessionsFromFile();
      sessions.removeWhere((s) => s.id == sessionId);

      final jsonList = sessions.map((s) => s.toMap()).toList();
      await file.writeAsString(jsonEncode(jsonList));
      _logger.log('[Charging] Session $sessionId deleted from file');
    } catch (e) {
      _logger.log('[Charging] Failed to delete session from file: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    _sessionController.close();
  }
}
