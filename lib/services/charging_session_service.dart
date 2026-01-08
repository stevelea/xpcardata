import 'dart:async';
import '../models/vehicle_data.dart';
import '../models/charging_session.dart';
import 'debug_logger.dart';
import 'mqtt_service.dart';

/// Service for detecting and tracking charging sessions
/// Monitors cumulative charge values and current to detect charging state
class ChargingSessionService {
  final _logger = DebugLogger.instance;
  final MqttService? _mqttService;

  ChargingSession? _currentSession;
  double? _lastCumulativeCharge;
  bool _isCharging = false;

  // Threshold for detecting charging (positive current indicates charging)
  static const double _chargingCurrentThreshold = 0.5; // Amps
  // Minimum change in cumulative charge to consider it valid (filter noise)
  static const double _minChargeChange = 0.1; // Ah

  final StreamController<ChargingSession> _sessionController =
      StreamController<ChargingSession>.broadcast();

  /// Stream of charging session updates
  Stream<ChargingSession> get sessionStream => _sessionController.stream;

  /// Current active charging session (null if not charging)
  ChargingSession? get currentSession => _currentSession;

  /// Whether vehicle is currently charging
  bool get isCharging => _isCharging;

  ChargingSessionService({MqttService? mqttService}) : _mqttService = mqttService;

  /// Process new vehicle data to detect charging state changes
  void processVehicleData(VehicleData data) {
    // Check if we have cumulative charge data
    if (data.cumulativeCharge == null) {
      _logger.log('[ChargingSession] No cumulative charge data available');
      return;
    }

    final currentCharge = data.cumulativeCharge!;
    final current = data.batteryCurrent ?? 0;

    // Debug logging for charging detection
    _logger.log('[ChargingSession] Current: ${current.toStringAsFixed(2)}A, '
        'CumulativeCharge: ${currentCharge.toStringAsFixed(2)}Ah, '
        'LastCumulative: ${_lastCumulativeCharge?.toStringAsFixed(2) ?? "null"}Ah');

    // Detect charging based on positive current (charging into battery)
    // and/or increasing cumulative charge
    final wasCharging = _isCharging;

    // Check if charging: positive current indicates charging
    // Some vehicles may report current differently, so also check cumulative increase
    bool chargingDetected = false;
    String detectionReason = '';

    if (current > _chargingCurrentThreshold) {
      chargingDetected = true;
      detectionReason = 'current > ${_chargingCurrentThreshold}A';
    } else if (_lastCumulativeCharge != null) {
      final chargeIncrease = currentCharge - _lastCumulativeCharge!;
      if (chargeIncrease > _minChargeChange) {
        chargingDetected = true;
        detectionReason = 'cumulative increase ${chargeIncrease.toStringAsFixed(3)}Ah';
      }
    }

    if (chargingDetected != wasCharging) {
      _logger.log('[ChargingSession] State change: ${wasCharging ? "charging" : "not charging"} -> '
          '${chargingDetected ? "charging" : "not charging"} (reason: $detectionReason)');
    }

    _isCharging = chargingDetected;

    // Handle state transitions
    if (!wasCharging && _isCharging) {
      // Started charging - create new session
      _startNewSession(data);
    } else if (wasCharging && !_isCharging) {
      // Stopped charging - complete session
      _completeSession(data);
    } else if (_isCharging && _currentSession != null) {
      // Still charging - update session periodically (for MQTT updates)
      _updateActiveSession(data);
    }

    _lastCumulativeCharge = currentCharge;
  }

  /// Start a new charging session
  void _startNewSession(VehicleData data) {
    final sessionId = 'charge_${DateTime.now().millisecondsSinceEpoch}';

    // Use the LAST cumulative charge value (before charging started) if available
    // This ensures we capture energy added even if app started mid-charge
    final startCumulative = _lastCumulativeCharge ?? data.cumulativeCharge!;

    _currentSession = ChargingSession(
      id: sessionId,
      startTime: data.timestamp,
      startCumulativeCharge: startCumulative,
      startSoc: data.stateOfCharge ?? 0,
      startOdometer: data.odometer ?? 0,
      isActive: true,
    );

    _logger.log('[ChargingSession] Started new session: $sessionId');
    _logger.log('[ChargingSession] Start SOC: ${data.stateOfCharge}%, '
        'Start cumulative: $startCumulative Ah (current: ${data.cumulativeCharge} Ah)');

    // Add to stream for internal tracking
    _sessionController.add(_currentSession!);
    // Note: Don't publish to MQTT on start - wait for session completion
  }

  /// Complete the current charging session
  void _completeSession(VehicleData data) {
    if (_currentSession == null) return;

    final completedSession = _currentSession!.complete(
      endTime: data.timestamp,
      endCumulativeCharge: data.cumulativeCharge!,
      endSoc: data.stateOfCharge ?? _currentSession!.startSoc,
      endOdometer: data.odometer,
    );

    _logger.log('[ChargingSession] Completed session: ${completedSession.id}');
    _logger.log('[ChargingSession] Duration: ${completedSession.duration}');
    _logger.log('[ChargingSession] Energy added: ${completedSession.energyAddedAh?.toStringAsFixed(2)} Ah');
    _logger.log('[ChargingSession] SOC: ${completedSession.startSoc}% -> ${completedSession.endSoc}%');

    // Only publish if actual charging occurred (energy was added)
    final energyAdded = completedSession.energyAddedAh ?? 0;
    if (energyAdded >= _minChargeChange) {
      _sessionController.add(completedSession);
      _publishSessionToMqtt(completedSession);
      _logger.log('[ChargingSession] Published completed session to MQTT');
    } else {
      _logger.log('[ChargingSession] Session discarded - no significant energy added (${energyAdded.toStringAsFixed(2)} Ah)');
    }

    _currentSession = null;
  }

  /// Update active session (just track, don't publish until complete)
  void _updateActiveSession(VehicleData data) {
    if (_currentSession == null) return;

    // Just log the progress - MQTT will be published when session completes
    final currentCharge = data.cumulativeCharge ?? _currentSession!.startCumulativeCharge;
    final energyAddedSinceStart = currentCharge - _currentSession!.startCumulativeCharge;

    _logger.log('[ChargingSession] Charging in progress: energyAdded=${energyAddedSinceStart.toStringAsFixed(2)}Ah, '
        'SOC=${data.stateOfCharge}%');
  }

  /// Publish charging session to MQTT with retain flag
  void _publishSessionToMqtt(ChargingSession session) {
    if (_mqttService == null) {
      _logger.log('[ChargingSession] MQTT publish skipped - no MQTT service');
      return;
    }
    if (!_mqttService.isConnected) {
      _logger.log('[ChargingSession] MQTT publish skipped - not connected');
      return;
    }

    _logger.log('[ChargingSession] Publishing to MQTT: session=${session.id}, active=${session.isActive}');
    _mqttService.publishChargingSession(session);
  }

  /// Manually end the current session (e.g., when app closes)
  void endCurrentSession(VehicleData? lastData) {
    if (_currentSession == null) return;

    if (lastData != null) {
      _completeSession(lastData);
    } else {
      // No data available, just close the session without publishing
      // (no energy was added since we don't have end data)
      _logger.log('[ChargingSession] Session closed without data - not publishing');
      _currentSession = null;
    }
  }

  /// Get list of recent charging sessions from database
  /// TODO: Implement database storage for historical sessions
  Future<List<ChargingSession>> getRecentSessions({int limit = 10}) async {
    // Placeholder - implement database query
    return [];
  }

  /// Dispose resources
  void dispose() {
    _sessionController.close();
  }
}
