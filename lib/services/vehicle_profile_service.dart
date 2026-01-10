import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/vehicle_profile.dart';
import '../models/obd_pid_config.dart';
import 'debug_logger.dart';

/// Service for loading and managing WiCAN vehicle profiles
class VehicleProfileService {
  final _logger = DebugLogger.instance;
  static const String profilesUrl =
      'https://raw.githubusercontent.com/meatpiHQ/wican-fw/main/vehicle_profiles.json';

  VehicleProfiles? _cachedProfiles;

  /// Fetch vehicle profiles from WiCAN repository
  Future<VehicleProfiles?> fetchProfiles() async {
    if (_cachedProfiles != null) {
      return _cachedProfiles;
    }

    try {
      _logger.log('[VehicleProfileService] Fetching profiles from $profilesUrl');

      final response = await http.get(Uri.parse(profilesUrl));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        _cachedProfiles = VehicleProfiles.fromJson(json);

        _logger.log('[VehicleProfileService] Loaded ${_cachedProfiles!.cars.length} vehicle profiles');
        return _cachedProfiles;
      } else {
        _logger.log('[VehicleProfileService] Failed to fetch profiles: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      _logger.log('[VehicleProfileService] Error fetching profiles: $e');
      return null;
    }
  }

  /// Convert a WiCAN vehicle profile to OBDPIDConfig list
  List<OBDPIDConfig> convertProfileToPIDs(VehicleProfile profile) {
    final pids = <OBDPIDConfig>[];

    for (final profilePid in profile.pids) {
      for (final param in profilePid.parameters) {
        // Determine PID type based on name or class
        final pidType = _determinePIDType(param.name, param.class_);

        // Convert WiCAN expression to our formula format
        final formula = param.toFormula();

        // WiCAN PIDs often have trailing '1' for single-frame request
        // Strip it for ELM327 compatibility (e.g., "2211011" -> "221101")
        String pid = profilePid.pid;
        if (pid.length == 7 && pid.endsWith('1') && pid.startsWith('22')) {
          pid = pid.substring(0, 6);
          _logger.log('[VehicleProfileService] Stripped trailing 1 from PID: ${profilePid.pid} -> $pid');
        }

        final pidConfig = OBDPIDConfig(
          name: param.name,
          pid: pid,
          description: '${param.name} (${param.unit})',
          type: pidType,
          formula: formula,
          parser: (response) => OBDPIDConfig.parseWithFormula(response, formula),
        );

        pids.add(pidConfig);
      }
    }

    _logger.log('[VehicleProfileService] Converted ${pids.length} PIDs from ${profile.carModel}');
    return pids;
  }

  /// Determine PID type based on parameter name or class
  OBDPIDType _determinePIDType(String name, String? class_) {
    final nameLower = name.toLowerCase();

    // Check for state of charge
    if (nameLower.contains('soc') ||
        nameLower.contains('state of charge') ||
        nameLower.contains('battery level')) {
      return OBDPIDType.stateOfCharge;
    }

    // Check for speed
    if (nameLower.contains('speed') || nameLower == 'spd') {
      return OBDPIDType.speed;
    }

    // Check for voltage
    if (nameLower.contains('voltage') ||
        nameLower.contains('volt') ||
        nameLower == 'hv') {
      return OBDPIDType.batteryVoltage;
    }

    // Check for odometer
    if (nameLower.contains('odometer') ||
        nameLower.contains('mileage') ||
        nameLower.contains('distance')) {
      return OBDPIDType.odometer;
    }

    // Check for cumulative charge
    if (nameLower.contains('cumulative') && nameLower.contains('charg')) {
      return OBDPIDType.cumulativeCharge;
    }

    // Check for cumulative discharge
    if (nameLower.contains('cumulative') && nameLower.contains('discharg')) {
      return OBDPIDType.cumulativeDischarge;
    }

    return OBDPIDType.custom;
  }

  /// Get initialization command for a vehicle (if specified)
  String? getInitCommand(VehicleProfile profile) {
    return profile.init;
  }
}
