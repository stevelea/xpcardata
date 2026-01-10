import 'dart:async';
import '../models/vehicle_data.dart';
import '../models/charging_session.dart';
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

  // Stationary sample counter (need 2 consecutive samples at speed=0 to confirm charging)
  int _stationarySampleCount = 0;
  static const int _requiredStationarySamples = 2;

  // Track consecutive non-charging samples to detect charging end
  int _nonChargingSampleCount = 0;
  static const int _requiredNonChargingSamples = 2; // 2 consecutive samples with no charging indicators

  // Thresholds for detection
  static const double _chargingCurrentThreshold = 0.5; // Amps (positive = discharging, negative = charging)
  static const double _minChargeChange = 0.1; // Ah
  static const double _minChargePower = 0.1; // kW - minimum to consider charging
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

  /// Process new vehicle data to detect charging state changes
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
    // This is the dashboard current value and is the most reliable charging indicator
    final hvCurrent = _getDoubleValue(props, 'HV_A');

    // Get charging status PID (22031D) - direct charging indicator
    final chargingStatus = _getDoubleValue(props, 'CHARGING');

    // Get DC charging values
    final dcChgStatus = _getDoubleValue(props, 'DC_CHG_STATUS');
    final dcChgCurrent = _getDoubleValue(props, 'DC_CHG_A');
    final dcChgVoltage = _getDoubleValue(props, 'DC_CHG_V');

    // Get AC charging values
    final acChgCurrent = _getDoubleValue(props, 'AC_CHG_A');
    final acChgVoltage = _getDoubleValue(props, 'AC_CHG_V');

    // Get BMS charge status (helps distinguish AC vs DC)
    // XPENG G6: 0=Not charging, 2=DC charging, 3=AC charging, 4=DC charging (high power)
    final bmsChgStatus = _getDoubleValue(props, 'BMS_CHG_STATUS');

    // Calculate DC and AC power
    double dcPowerKw = 0.0;
    double acPowerKw = 0.0;

    // DC power: only count if current > 50A (to distinguish from AC which uses lower current)
    if (dcChgCurrent != null && dcChgVoltage != null && dcChgCurrent > 50) {
      dcPowerKw = (dcChgCurrent * dcChgVoltage) / 1000.0;
    }

    // AC power: use AC-specific PIDs
    if (acChgCurrent != null && acChgVoltage != null && acChgCurrent > 0 && acChgVoltage > 0) {
      acPowerKw = (acChgCurrent * acChgVoltage) / 1000.0;
    }

    // Calculate power from HV current (negative = charging)
    double hvPowerKw = 0.0;
    if (hvCurrent != null && hvCurrent < 0 && data.batteryVoltage != null) {
      // Negative current means charging, calculate power (make positive for display)
      hvPowerKw = (hvCurrent.abs() * data.batteryVoltage!) / 1000.0;
    }

    // Determine charging type and power
    ChargingType detectedType = ChargingType.none;
    double detectedPower = 0.0;
    String detectionReason = '';

    // CRITICAL: Battery current is the ultimate truth for charging detection
    // When cable is plugged in but charging has stopped, XPENG still reports:
    // - BMS_CHG_STATUS = 3 (AC) or 2/4 (DC)
    // - CHARGING = 1
    // But batteryCurrent becomes positive or near-zero (no power flowing)
    //
    // Rule: If HV current is NOT negative (< -0.5A), we are NOT charging,
    // regardless of what the status PIDs say.

    final isCurrentIndicatingCharging = hvCurrent != null && hvCurrent < -_chargingCurrentThreshold;

    // Priority 1: HV battery current is NEGATIVE and speed=0 for 2+ samples
    // This is the most reliable indicator - matches what's shown on dashboard
    if (isCurrentIndicatingCharging && isConfirmedStationary) {
      // Negative current = charging. Determine AC vs DC by current magnitude and BMS status
      // BMS_CHG_STATUS: 2=DC charging, 3=AC charging, 4=DC charging (high power)
      if (bmsChgStatus == 3 || (hvCurrent!.abs() < 50 && acPowerKw > 0)) {
        detectedType = ChargingType.ac;
        detectedPower = hvPowerKw > 0 ? hvPowerKw : acPowerKw;
        detectionReason = 'HV current ${hvCurrent.toStringAsFixed(1)}A (AC): ${detectedPower.toStringAsFixed(1)} kW';
      } else if (bmsChgStatus == 2 || bmsChgStatus == 4 || hvCurrent!.abs() >= 50) {
        detectedType = ChargingType.dc;
        // For DC charging, prefer DC charger power if available (more accurate than HV pack current)
        detectedPower = dcPowerKw > 0 ? dcPowerKw : hvPowerKw;
        detectionReason = 'HV current ${hvCurrent.toStringAsFixed(1)}A (DC, BMS=$bmsChgStatus): ${detectedPower.toStringAsFixed(1)} kW';
      } else {
        detectedType = ChargingType.unknown;
        detectedPower = hvPowerKw;
        detectionReason = 'HV current ${hvCurrent!.toStringAsFixed(1)}A: ${detectedPower.toStringAsFixed(1)} kW';
      }
    }
    // Only check status PIDs if we don't have HV current data
    // If HV current is available and NOT negative, charging has stopped
    // even if status PIDs still show charging (cable plugged in but not charging)
    else if (hvCurrent == null) {
      // Priority 2: Check direct charging status PID (only if no current data)
      if (chargingStatus != null && chargingStatus > 0 && isConfirmedStationary) {
        // Charging status is active, determine type using BMS status and power
        // BMS_CHG_STATUS: 2=DC charging, 3=AC charging, 4=DC charging (high power)
        if (bmsChgStatus == 3 || (acPowerKw > _minChargePower && dcPowerKw < _minChargePower)) {
          detectedType = ChargingType.ac;
          detectedPower = acPowerKw > 0 ? acPowerKw : hvPowerKw;
          detectionReason = 'Charging PID (BMS=$bmsChgStatus): ${detectedPower.toStringAsFixed(1)} kW AC';
        } else if (bmsChgStatus == 2 || bmsChgStatus == 4 || dcPowerKw > _minChargePower) {
          detectedType = ChargingType.dc;
          detectedPower = dcPowerKw > 0 ? dcPowerKw : hvPowerKw;
          detectionReason = 'Charging PID (BMS=$bmsChgStatus): ${detectedPower.toStringAsFixed(1)} kW DC';
        } else {
          detectedType = bmsChgStatus == 3 ? ChargingType.ac :
                         (bmsChgStatus == 2 || bmsChgStatus == 4) ? ChargingType.dc : ChargingType.unknown;
          detectedPower = dcPowerKw > 0 ? dcPowerKw : hvPowerKw;
          detectionReason = 'Charging status active (BMS=$bmsChgStatus)';
        }
      }
      // Priority 3: Check BMS charging status (only if no current data)
      else if (bmsChgStatus != null && bmsChgStatus > 0 && isConfirmedStationary) {
        if (bmsChgStatus == 3) {
          detectedType = ChargingType.ac;
          detectedPower = acPowerKw > 0 ? acPowerKw : hvPowerKw;
          detectionReason = 'BMS AC status: ${detectedPower.toStringAsFixed(1)} kW';
        } else if (bmsChgStatus == 2 || bmsChgStatus == 4) {
          detectedType = ChargingType.dc;
          detectedPower = dcPowerKw > 0 ? dcPowerKw : hvPowerKw;
          detectionReason = 'BMS DC status ($bmsChgStatus): ${detectedPower.toStringAsFixed(1)} kW';
        }
      }
      // Priority 4: Check DC charging status PID with high current (only if no current data)
      else if (dcChgStatus != null && dcChgStatus > 0 && dcPowerKw > _minChargePower && isConfirmedStationary) {
        detectedType = ChargingType.dc;
        detectedPower = dcPowerKw;
        detectionReason = 'DC status active: ${dcPowerKw.toStringAsFixed(1)} kW';
      }
      // Priority 5: Check for significant DC power (only if no current data)
      else if (dcPowerKw > _minChargePower && isConfirmedStationary) {
        detectedType = ChargingType.dc;
        detectedPower = dcPowerKw;
        detectionReason = 'DC power: ${dcPowerKw.toStringAsFixed(1)} kW';
      }
      // Priority 6: Check for significant AC power (only if no current data)
      else if (acPowerKw > _minChargePower && isConfirmedStationary) {
        detectedType = ChargingType.ac;
        detectedPower = acPowerKw;
        detectionReason = 'AC power: ${acPowerKw.toStringAsFixed(1)} kW';
      }
      // Priority 7: Check cumulative charge increase (only if no current data)
      else if (data.cumulativeCharge != null && _lastCumulativeCharge != null && isConfirmedStationary) {
        final chargeIncrease = data.cumulativeCharge! - _lastCumulativeCharge!;
        if (chargeIncrease > _minChargeChange) {
          detectedType = ChargingType.unknown;
          detectedPower = hvPowerKw;
          detectionReason = 'Cumulative +${chargeIncrease.toStringAsFixed(3)} Ah';
        }
      }
    }
    // If HV current is available but NOT negative, log why we're not detecting charging
    else if (_isCharging && hvCurrent >= -_chargingCurrentThreshold) {
      _logger.log('[Charging] Current not negative (${hvCurrent.toStringAsFixed(1)}A) - charging stopped or cable idle');
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

    final completedSession = _currentSession!.complete(
      endTime: data.timestamp,
      endCumulativeCharge: data.cumulativeCharge ?? _currentSession!.startCumulativeCharge,
      endSoc: data.stateOfCharge ?? _currentSession!.startSoc,
      endOdometer: data.odometer,
      averageVoltage: _lastVoltage,
      previousOdometer: _previousSessionEndOdometer,
    );

    _logger.log('[Charging] === SESSION COMPLETE ===');
    _logger.log('[Charging] Type: ${completedSession.chargingType?.toUpperCase() ?? "unknown"}');
    _logger.log('[Charging] Duration: ${completedSession.duration}');
    _logger.log('[Charging] Energy: ${completedSession.energyAddedAh?.toStringAsFixed(2)} Ah');
    if (completedSession.energyAddedKwh != null) {
      _logger.log('[Charging] Energy: ${completedSession.energyAddedKwh?.toStringAsFixed(2)} kWh');
    }
    _logger.log('[Charging] SOC: ${completedSession.startSoc.toStringAsFixed(1)}% -> ${completedSession.endSoc?.toStringAsFixed(1)}%');
    _logger.log('[Charging] Max Power: ${completedSession.maxPowerKw?.toStringAsFixed(1)} kW');
    if (completedSession.distanceSinceLastCharge != null) {
      _logger.log('[Charging] Distance since last charge: ${completedSession.distanceSinceLastCharge?.toStringAsFixed(1)} km');
    }
    if (completedSession.consumptionKwhPer100km != null) {
      _logger.log('[Charging] Consumption: ${completedSession.consumptionKwhPer100km?.toStringAsFixed(1)} kWh/100km');
    }

    final energyAdded = completedSession.energyAddedAh ?? 0;
    if (energyAdded >= _minChargeChange) {
      // Save to database
      try {
        await _db.insertChargingSession(completedSession);
        _logger.log('[Charging] Session saved to database');
      } catch (e) {
        _logger.log('[Charging] Failed to save session: $e');
      }

      // Update previous session odometer for next consumption calculation
      if (completedSession.endOdometer != null) {
        _previousSessionEndOdometer = completedSession.endOdometer;
      }

      _sessionController.add(completedSession);
      _publishSessionToMqtt(completedSession);
    } else {
      _logger.log('[Charging] Discarded - no energy added');
    }

    _currentSession = null;
  }

  /// Update active session with current values
  void _updateActiveSession(VehicleData data, ChargingType type, double powerKw) {
    if (_currentSession == null) return;

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
        'SOC=${data.stateOfCharge?.toStringAsFixed(1)}%, +${energyAdded.toStringAsFixed(2)}Ah');
  }

  /// Publish charging session to MQTT
  void _publishSessionToMqtt(ChargingSession session) {
    if (_mqttService == null || !_mqttService.isConnected) return;
    _mqttService.publishChargingSession(session);
    _logger.log('[Charging] Published to MQTT');
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
    try {
      return await _db.getChargingSessions(limit: limit);
    } catch (e) {
      _logger.log('[Charging] Failed to get sessions: $e');
      return [];
    }
  }

  /// Get all charging sessions from database
  Future<List<ChargingSession>> getAllSessions() async {
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
