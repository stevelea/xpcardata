import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/vehicle_data.dart';
import 'debug_logger.dart';
import 'data_usage_service.dart';

/// Service for sending telemetry data to A Better Route Planner (ABRP)
/// ABRP uses this data to provide accurate range predictions and charging planning
class AbrpService {
  final _logger = DebugLogger.instance;

  // ABRP API endpoint
  static const String _abrpEndpoint = 'https://api.iternio.com/1/tlm/send';

  // ABRP API key - required for all API requests
  // This is a generic/public API key used by open-source projects
  // Users should provide their own user token from ABRP app
  static const String _apiKey = '6f6a554f-d8c8-4c72-8914-d5895f58b1eb';

  String? _token;
  String? _carModel;
  bool _isEnabled = false;

  // Rate limiting - configurable, minimum 5 seconds (ABRP recommendation)
  DateTime? _lastSendTime;
  int _minIntervalSeconds = 5;
  Duration get _minInterval => Duration(seconds: _minIntervalSeconds);

  /// Configure the ABRP service
  void configure({
    required String token,
    String? carModel,
    bool enabled = true,
  }) {
    _token = token;
    _carModel = carModel;
    _isEnabled = enabled && token.isNotEmpty;
    _logger.log('[ABRP] Configured: enabled=$_isEnabled, carModel=$_carModel');
  }

  /// Update the minimum send interval (in seconds)
  /// Note: ABRP recommends minimum 5 seconds between updates
  void setUpdateInterval(int seconds) {
    // Enforce minimum of 5 seconds as per ABRP recommendation
    _minIntervalSeconds = seconds < 5 ? 5 : seconds;
    _logger.log('[ABRP] Update interval set to $_minIntervalSeconds seconds');
  }

  /// Check if ABRP is enabled and configured
  bool get isEnabled => _isEnabled && _token != null && _token!.isNotEmpty;

  /// Send vehicle data to ABRP
  Future<bool> sendTelemetry(VehicleData data, {bool? isCharging}) async {
    _logger.log('[ABRP] sendTelemetry called, isEnabled=$isEnabled, token=${_token?.isNotEmpty == true ? "SET" : "EMPTY"}');
    if (!isEnabled) {
      _logger.log('[ABRP] Skipping - not enabled or no token');
      return false;
    }

    // Rate limiting
    final now = DateTime.now();
    if (_lastSendTime != null) {
      final elapsed = now.difference(_lastSendTime!);
      if (elapsed < _minInterval) {
        _logger.log('[ABRP] Rate limited, skipping (${elapsed.inSeconds}s < ${_minInterval.inSeconds}s)');
        return false;
      }
    }

    try {
      // Build the telemetry data object (tlm parameter)
      final tlm = <String, dynamic>{};

      // UTC timestamp (seconds since epoch)
      tlm['utc'] = data.timestamp.millisecondsSinceEpoch ~/ 1000;

      // State of Charge (%)
      if (data.stateOfCharge != null) {
        tlm['soc'] = double.parse(data.stateOfCharge!.toStringAsFixed(1));
      }

      // State of Health (%)
      if (data.stateOfHealth != null) {
        tlm['soh'] = double.parse(data.stateOfHealth!.toStringAsFixed(1));
      }

      // Speed (km/h)
      if (data.speed != null) {
        tlm['speed'] = double.parse(data.speed!.toStringAsFixed(1));
      }

      // Battery voltage (V)
      if (data.batteryVoltage != null) {
        tlm['voltage'] = double.parse(data.batteryVoltage!.toStringAsFixed(1));
      }

      // Battery current (A)
      if (data.batteryCurrent != null) {
        tlm['current'] = double.parse(data.batteryCurrent!.toStringAsFixed(1));
      }

      // Power (kW)
      if (data.power != null) {
        tlm['power'] = double.parse(data.power!.toStringAsFixed(2));
      }

      // Battery temperature (°C)
      if (data.batteryTemperature != null) {
        tlm['batt_temp'] = double.parse(data.batteryTemperature!.toStringAsFixed(1));
      }

      // Odometer (km)
      if (data.odometer != null) {
        tlm['odometer'] = double.parse(data.odometer!.toStringAsFixed(1));
      }

      // Charging status
      // Note: The isCharging parameter should already be filtered by speed in the caller
      // (data_source_manager.dart), but we add a safety check here as well to ensure
      // we don't report charging while driving (e.g., during regenerative braking)
      if (isCharging != null) {
        // Trust the caller's determination (should already account for speed)
        tlm['is_charging'] = isCharging ? 1 : 0;
      } else {
        // Fallback: only report charging if vehicle is stationary
        final isStationary = data.speed == null || data.speed! < 1.0;
        if (isStationary && data.additionalProperties != null) {
          final charging = data.additionalProperties!['CHARGING'];
          if (charging != null) {
            tlm['is_charging'] = (charging == 1 || charging == 1.0) ? 1 : 0;
          }
        } else if (!isStationary) {
          // Vehicle is moving - explicitly not charging
          tlm['is_charging'] = 0;
        }
      }

      // Car model (optional but helpful for ABRP)
      if (_carModel != null && _carModel!.isNotEmpty) {
        tlm['car_model'] = _carModel!;
      }

      // Build the URL with api_key, token, and tlm as JSON
      final tlmJson = jsonEncode(tlm);
      final uri = Uri.parse(_abrpEndpoint).replace(queryParameters: {
        'api_key': _apiKey,
        'token': _token!,
        'tlm': tlmJson,
      });

      _logger.log('[ABRP] Sending telemetry: soc=${tlm['soc']}, soh=${tlm['soh']}, odometer=${tlm['odometer']}, is_charging=${tlm['is_charging']}');
      _logger.log('[ABRP] Request URL: ${uri.toString().substring(0, 80)}...');

      // Send the request as GET with query parameters (as per ABRP API spec)
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      _lastSendTime = now;

      // Track data usage (full URL length)
      final bytesSent = uri.toString().length + 50; // ~50 bytes for headers
      DataUsageService.instance.recordAbrpSent(bytesSent);

      if (response.statusCode == 200) {
        _logger.log('[ABRP] Telemetry sent successfully');
        return true;
      } else {
        _logger.log('[ABRP] Failed to send telemetry: ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      _logger.log('[ABRP] Error sending telemetry: $e');
      return false;
    }
  }

  /// Disable ABRP service
  void disable() {
    _isEnabled = false;
    _logger.log('[ABRP] Disabled');
  }
}
