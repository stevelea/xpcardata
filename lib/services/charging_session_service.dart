import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vehicle_data.dart';
import '../models/charging_session.dart';
import '../providers/vehicle_data_provider.dart' show vehicleBatteryCapacities;
import 'debug_logger.dart';
import 'mqtt_service.dart';
import 'database_service.dart';

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

  ChargingSession? _currentSession;
  double? _lastCumulativeCharge;
  double? _lastVoltage; // Track voltage for kWh calculation
  bool _isCharging = false;
  ChargingType _chargingType = ChargingType.none;
  double _chargePowerKw = 0.0;
  double? _previousSessionEndOdometer; // Odometer at end of last charge

  // Energy accumulation for sessions (integrates power over time)
  double _accumulatedEnergyKwh = 0.0;
  DateTime? _lastPowerSampleTime;

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

  // Thresholds for detection
  static const double _chargingCurrentThreshold = 0.5; // Amps (positive = discharging, negative = charging)
  static const double _minChargeChange = 0.1; // Ah
  static const double _maxSpeedForCharging = 1.0; // km/h - must be stationary to charge

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
    _loadPreviousSessionOdometer();
    // Reset charging state on initialization - ensures clean state on app restart
    _isCharging = false;
    _chargingType = ChargingType.none;
    _chargePowerKw = 0.0;
    _stationarySampleCount = 0;
    _nonChargingSampleCount = 0;
    _logger.log('[Charging] Service initialized - charging state reset');
  }

  /// Load the odometer from the last completed charging session
  Future<void> _loadPreviousSessionOdometer() async {
    try {
      final lastSession = await _db.getLastCompletedSession();
      if (lastSession != null && lastSession.endOdometer != null) {
        _previousSessionEndOdometer = lastSession.endOdometer;
        _logger.log('[Charging] Loaded previous session odometer: ${_previousSessionEndOdometer?.toStringAsFixed(0)} km');
      }
    } catch (e) {
      _logger.log('[Charging] Failed to load previous session: $e');
    }
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
    // Extract charging-related values from additionalProperties
    final props = data.additionalProperties ?? {};

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
    final hvCurrent = _getDoubleValue(props, 'HV_A');

    // Get DC charging values - these are reliable for DC fast charging detection
    final dcChgCurrent = _getDoubleValue(props, 'DC_CHG_A');
    final dcChgVoltage = _getDoubleValue(props, 'DC_CHG_V');

    // Get AC charging values
    final acChgCurrent = _getDoubleValue(props, 'AC_CHG_A');
    final acChgVoltage = _getDoubleValue(props, 'AC_CHG_V');

    // Debug: log charging-related values
    _logger.log('[Charging] HV_A=${hvCurrent?.toStringAsFixed(2) ?? "null"}, DC_CHG_A=${dcChgCurrent?.toStringAsFixed(1) ?? "null"}, AC_CHG_A=${acChgCurrent?.toStringAsFixed(1) ?? "null"}, speed=${currentSpeed.toStringAsFixed(1)}, isCharging=$_isCharging');

    // Calculate DC power
    double dcPowerKw = 0.0;
    if (dcChgCurrent != null && dcChgVoltage != null && dcChgCurrent > 0) {
      dcPowerKw = (dcChgCurrent * dcChgVoltage) / 1000.0;
    }

    // Calculate AC power
    double acPowerKw = 0.0;
    if (acChgCurrent != null && acChgVoltage != null && acChgCurrent > 0) {
      acPowerKw = (acChgCurrent * acChgVoltage) / 1000.0;
    }

    // Calculate power from HV current (negative = charging)
    double hvPowerKw = 0.0;
    if (hvCurrent != null && hvCurrent < 0 && data.batteryVoltage != null) {
      hvPowerKw = (hvCurrent.abs() * data.batteryVoltage!) / 1000.0;
    }

    // Determine charging type and power
    // XPENG G6 has max 11kW AC charging capability
    // DC_CHG_A PID returns stale/garbage data when not DC charging
    // Use power threshold to distinguish: >11kW = DC, ≤11kW with AC_CHG_A = AC
    //
    // Priority:
    // 1. AC_CHG_A > 1A AND acPower ≤ 11kW = AC charging (checked FIRST because DC_CHG_A has stale data)
    // 2. DC power > 11kW = DC fast charging (must exceed AC max)
    // 3. HV_A < -0.5A = fallback for any charging type
    ChargingType detectedType = ChargingType.none;
    double detectedPower = 0.0;
    String detectionReason = '';

    // Max AC charging power for XPENG G6 - anything above this must be DC
    const double maxAcPowerKw = 11.5; // Slightly above 11kW to allow for measurement variance

    // Check for AC charging FIRST (AC_CHG_A is reliable, DC_CHG_A has stale data issue)
    if (acChgCurrent != null && acChgCurrent > 1 && isConfirmedStationary) {
      detectedType = ChargingType.ac;
      detectedPower = acPowerKw;
      detectionReason = 'AC charger ${acChgCurrent.toStringAsFixed(0)}A @ ${acChgVoltage?.toStringAsFixed(0) ?? "?"}V = ${acPowerKw.toStringAsFixed(1)} kW';
    }
    // Check for DC fast charging - only if power > 11kW (exceeds max AC)
    // This avoids false DC detection from stale DC_CHG_A values during AC charging
    else if (dcChgCurrent != null && dcChgCurrent > 10 && dcPowerKw > maxAcPowerKw && isConfirmedStationary) {
      detectedType = ChargingType.dc;
      detectedPower = dcPowerKw;
      detectionReason = 'DC charger ${dcChgCurrent.toStringAsFixed(0)}A @ ${dcChgVoltage?.toStringAsFixed(0) ?? "?"}V = ${dcPowerKw.toStringAsFixed(1)} kW';
    }
    // Fallback: Check HV_A for negative current (generic charging detection)
    else if (hvCurrent != null && hvCurrent < -_chargingCurrentThreshold && isConfirmedStationary) {
      // Use power to determine type: >11kW = DC, otherwise AC
      if (hvPowerKw > maxAcPowerKw) {
        detectedType = ChargingType.dc;
        detectedPower = dcPowerKw > 0 ? dcPowerKw : hvPowerKw;
      } else {
        detectedType = ChargingType.ac;
        detectedPower = acPowerKw > 0 ? acPowerKw : hvPowerKw;
      }
      detectionReason = 'HV current ${hvCurrent.toStringAsFixed(1)}A: ${detectedPower.toStringAsFixed(1)} kW';
    }
    // Not charging: AC charger off AND (DC power below AC max OR no DC) AND HV current not negative
    else if ((acChgCurrent == null || acChgCurrent < 1) &&
             (dcPowerKw <= maxAcPowerKw || dcChgCurrent == null || dcChgCurrent < 10) &&
             (hvCurrent == null || hvCurrent >= -_chargingCurrentThreshold)) {
      if (_isCharging) {
        _logger.log('[Charging] Charging stopped: DC=${dcChgCurrent?.toStringAsFixed(0) ?? "null"}A (${dcPowerKw.toStringAsFixed(1)}kW), AC=${acChgCurrent?.toStringAsFixed(0) ?? "null"}A, HV=${hvCurrent?.toStringAsFixed(1) ?? "null"}A');
      }
      detectedType = ChargingType.none;
      detectedPower = 0.0;
    }

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

    _currentSession = ChargingSession(
      id: sessionId,
      startTime: data.timestamp,
      startCumulativeCharge: startCumulative,
      startSoc: data.stateOfCharge ?? 0,
      startOdometer: data.odometer ?? 0,
      isActive: true,
      chargingType: type.name,
      maxPowerKw: powerKw,
    );

    _logger.log('[Charging] Session: $sessionId');
    _logger.log('[Charging] Type: ${type.name.toUpperCase()}, SOC: ${data.stateOfCharge?.toStringAsFixed(1)}%');

    _sessionController.add(_currentSession!);
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

    // Use peak SOC if it's higher than final sample (handles stale end-of-session data)
    final finalSoc = data.stateOfCharge ?? _currentSession!.startSoc;
    final effectiveEndSoc = (_peakSocDuringSession > finalSoc) ? _peakSocDuringSession : finalSoc;

    if (_peakSocDuringSession > finalSoc) {
      _logger.log('[Charging] Using peak SOC ${_peakSocDuringSession.toStringAsFixed(1)}% instead of final ${finalSoc.toStringAsFixed(1)}%');
    }

    var completedSession = _currentSession!.complete(
      endTime: data.timestamp,
      endCumulativeCharge: data.cumulativeCharge ?? _currentSession!.startCumulativeCharge,
      endSoc: effectiveEndSoc,
      endOdometer: data.odometer,
      averageVoltage: _lastVoltage,
      previousOdometer: _previousSessionEndOdometer,
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
    _logger.log('[Charging] Max Power: ${completedSession.maxPowerKw?.toStringAsFixed(1)} kW');

    // Reset peak SOC tracker (after logging)
    _peakSocDuringSession = 0.0;
    if (completedSession.distanceSinceLastCharge != null) {
      _logger.log('[Charging] Distance since last charge: ${completedSession.distanceSinceLastCharge?.toStringAsFixed(1)} km');
    }
    if (completedSession.consumptionKwhPer100km != null) {
      _logger.log('[Charging] Consumption: ${completedSession.consumptionKwhPer100km?.toStringAsFixed(1)} kWh/100km');
    }

    // Determine if session is worth saving - use multiple criteria:
    // 1. Energy added (kWh) >= 0.1 kWh (from cumulative charge or accumulated power)
    // 2. OR SOC gained >= 0.5% (fallback if energy isn't available)
    // 3. OR max power > 0 and duration > 1 minute (indicates actual charging occurred)
    final energyKwh = completedSession.energyAddedKwh ?? _accumulatedEnergyKwh;
    final socGained = completedSession.socGained ?? 0;
    final durationMins = completedSession.duration?.inMinutes ?? 0;
    final maxPower = completedSession.maxPowerKw ?? 0;

    final hasSignificantEnergy = energyKwh >= 0.1;
    final hasSignificantSocGain = socGained >= 0.5;
    final hasChargedWithPower = maxPower > 0 && durationMins >= 1;

    final shouldSave = hasSignificantEnergy || hasSignificantSocGain || hasChargedWithPower;
    _logger.log('[Charging] Save criteria: energyKwh=${energyKwh.toStringAsFixed(2)} (>=0.1?$hasSignificantEnergy), '
        'socGain=${socGained.toStringAsFixed(1)}% (>=0.5%?$hasSignificantSocGain), '
        'power+duration?$hasChargedWithPower => SAVE?$shouldSave');

    if (shouldSave) {
      // Save to database - always attempt even if isAvailable is false (it may become available)
      _logger.log('[Charging] Attempting database save, isAvailable=${_db.isAvailable}');
      try {
        await _db.insertChargingSession(completedSession);
        _logger.log('[Charging] Session ${completedSession.id} saved to database successfully');
      } catch (e, stackTrace) {
        _logger.log('[Charging] Failed to save session: $e');
        _logger.log('[Charging] Stack trace: $stackTrace');
      }

      // Update previous session odometer for next consumption calculation
      if (completedSession.endOdometer != null) {
        _previousSessionEndOdometer = completedSession.endOdometer;
      }

      _sessionController.add(completedSession);
      _publishSessionToMqtt(completedSession);
    } else {
      _logger.log('[Charging] Discarded - no significant charging detected');
    }

    // Reset accumulated energy for next session
    _accumulatedEnergyKwh = 0.0;
    _lastPowerSampleTime = null;

    _currentSession = null;
  }

  /// Update active session with current values
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

    // Update max power if current power is higher
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
      );
    }

    final currentCharge = data.cumulativeCharge ?? _currentSession!.startCumulativeCharge;
    final energyAdded = currentCharge - _currentSession!.startCumulativeCharge;

    _logger.log('[Charging] ${type.name.toUpperCase()} ${powerKw.toStringAsFixed(1)}kW, '
        'SOC=${data.stateOfCharge?.toStringAsFixed(1)}%, +${energyAdded.toStringAsFixed(2)}Ah, '
        'accumulated=${_accumulatedEnergyKwh.toStringAsFixed(2)}kWh');
  }

  /// Publish charging session to MQTT
  void _publishSessionToMqtt(ChargingSession session) {
    if (_mqttService == null) {
      _logger.log('[Charging] Cannot publish to MQTT - service is null');
      return;
    }
    if (!_mqttService.isConnected) {
      _logger.log('[Charging] Cannot publish to MQTT - not connected');
      return;
    }
    _mqttService.publishChargingSession(session);
    _logger.log('[Charging] Published session ${session.id} to MQTT');
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

  /// Get list of recent charging sessions from database
  Future<List<ChargingSession>> getRecentSessions({int limit = 10}) async {
    if (!_db.isAvailable) return [];
    try {
      return await _db.getChargingSessions(limit: limit);
    } catch (e) {
      _logger.log('[Charging] Failed to get sessions: $e');
      return [];
    }
  }

  /// Get all charging sessions from database
  Future<List<ChargingSession>> getAllSessions() async {
    if (!_db.isAvailable) return [];
    try {
      return await _db.getChargingSessions();
    } catch (e) {
      _logger.log('[Charging] Failed to get all sessions: $e');
      return [];
    }
  }

  /// Update a charging session (for manual edits like location, cost, notes)
  Future<bool> updateSession(ChargingSession session) async {
    try {
      await _db.updateChargingSession(session);
      _logger.log('[Charging] Session ${session.id} updated');
      _publishSessionToMqtt(session); // Sync to MQTT
      return true;
    } catch (e) {
      _logger.log('[Charging] Failed to update session: $e');
      return false;
    }
  }

  /// Delete a charging session
  Future<bool> deleteSession(String sessionId) async {
    try {
      await _db.deleteChargingSession(sessionId);
      _logger.log('[Charging] Session $sessionId deleted');
      return true;
    } catch (e) {
      _logger.log('[Charging] Failed to delete session: $e');
      return false;
    }
  }

  /// Get charging statistics
  Future<Map<String, dynamic>> getStatistics() async {
    if (!_db.isAvailable) {
      return {
        'sessionCount': 0,
        'totalEnergyKwh': 0.0,
        'averageConsumptionKwhPer100km': null,
      };
    }
    try {
      final sessionCount = await _db.getChargingSessionsCount();
      final totalEnergy = await _db.getTotalEnergyCharged();
      final avgConsumption = await _db.getAverageConsumption();

      return {
        'sessionCount': sessionCount,
        'totalEnergyKwh': totalEnergy,
        'averageConsumptionKwhPer100km': avgConsumption,
      };
    } catch (e) {
      _logger.log('[Charging] Failed to get statistics: $e');
      return {
        'sessionCount': 0,
        'totalEnergyKwh': 0.0,
        'averageConsumptionKwhPer100km': null,
      };
    }
  }

  /// Dispose resources
  void dispose() {
    _sessionController.close();
  }
}
