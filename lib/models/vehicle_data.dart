import 'dart:convert';
import 'package:intl/intl.dart';

class VehicleData {
  final DateTime timestamp;
  final double? stateOfCharge; // Battery SOC (%)
  final double? stateOfHealth; // Battery SOH (%)
  final double? batteryCapacity; // kWh
  final double? batteryVoltage; // Volts
  final double? batteryCurrent; // Amps
  final double? batteryTemperature; // Celsius
  final double? range; // km
  final double? speed; // km/h
  final double? odometer; // km
  final double? power; // kW
  final double? cumulativeCharge; // Ah - total energy charged into battery
  final double? cumulativeDischarge; // Ah - total energy discharged from battery
  final double? latitude; // GPS latitude
  final double? longitude; // GPS longitude
  final double? altitude; // GPS altitude (meters)
  final double? gpsSpeed; // GPS speed (km/h)
  final double? heading; // GPS heading (degrees)
  final Map<String, dynamic>? additionalProperties;

  VehicleData({
    required this.timestamp,
    this.stateOfCharge,
    this.stateOfHealth,
    this.batteryCapacity,
    this.batteryVoltage,
    this.batteryCurrent,
    this.batteryTemperature,
    this.range,
    this.speed,
    this.odometer,
    this.power,
    this.cumulativeCharge,
    this.cumulativeDischarge,
    this.latitude,
    this.longitude,
    this.altitude,
    this.gpsSpeed,
    this.heading,
    this.additionalProperties,
  });

  /// Check if location data is available
  bool get hasLocation => latitude != null && longitude != null;

  /// Convert to Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'timestamp': timestamp.millisecondsSinceEpoch,
      'stateOfCharge': stateOfCharge,
      'stateOfHealth': stateOfHealth,
      'batteryCapacity': batteryCapacity,
      'batteryVoltage': batteryVoltage,
      'batteryCurrent': batteryCurrent,
      'batteryTemperature': batteryTemperature,
      'range': range,
      'speed': speed,
      'odometer': odometer,
      'power': power,
      'cumulativeCharge': cumulativeCharge,
      'cumulativeDischarge': cumulativeDischarge,
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'gpsSpeed': gpsSpeed,
      'heading': heading,
      'additionalProperties':
          additionalProperties != null ? jsonEncode(additionalProperties) : null,
    };
  }

  /// Create from Map (database)
  factory VehicleData.fromMap(Map<String, dynamic> map) {
    return VehicleData(
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      stateOfCharge: map['stateOfCharge'] as double?,
      stateOfHealth: map['stateOfHealth'] as double?,
      batteryCapacity: map['batteryCapacity'] as double?,
      batteryVoltage: map['batteryVoltage'] as double?,
      batteryCurrent: map['batteryCurrent'] as double?,
      batteryTemperature: map['batteryTemperature'] as double?,
      range: map['range'] as double?,
      speed: map['speed'] as double?,
      odometer: map['odometer'] as double?,
      power: map['power'] as double?,
      cumulativeCharge: map['cumulativeCharge'] as double?,
      cumulativeDischarge: map['cumulativeDischarge'] as double?,
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      altitude: map['altitude'] as double?,
      gpsSpeed: map['gpsSpeed'] as double?,
      heading: map['heading'] as double?,
      additionalProperties: map['additionalProperties'] != null
          ? jsonDecode(map['additionalProperties'] as String) as Map<String, dynamic>
          : null,
    );
  }

  /// Convert to JSON for MQTT transmission
  Map<String, dynamic> toJson() {
    // Determine actual charging status based on current/power
    // Negative current = charging (current flowing INTO battery)
    // Speed must be near zero to distinguish from regenerative braking
    final bool isStationary = (speed ?? 0) < 1.0;
    final bool currentIndicatesCharging = (batteryCurrent ?? 0) < -0.5;
    final bool powerIndicatesCharging = (power ?? 0) < -0.5;
    final bool isCharging = isStationary && (currentIndicatesCharging || powerIndicatesCharging);

    // IEC 61851 charging status codes:
    // A = Standby (not connected/not charging)
    // B = Vehicle detected (connected but not charging) - cannot detect from OBD
    // C = Ready/Charging (charging in progress)
    // D = With ventilation (not applicable)
    // E = No power (not applicable)
    // F = Error (not applicable)
    String chargingStatus;
    String chargingStatusDescription;
    if (isCharging) {
      chargingStatus = 'C'; // IEC 61851 Status C = Charging
      final absPower = (power ?? 0).abs();
      chargingStatusDescription = absPower > 11.0 ? 'DC Charging' : 'AC Charging';
    } else {
      chargingStatus = 'A'; // IEC 61851 Status A = Standby
      chargingStatusDescription = 'Not Charging';
    }

    // Format local time in human-readable format
    final localTime = DateFormat('yyyy-MM-dd HH:mm:ss').format(timestamp.toLocal());

    return {
      'timestamp': timestamp.toIso8601String(),
      'localTime': localTime,
      'stateOfCharge': stateOfCharge,
      'stateOfHealth': stateOfHealth,
      'batteryCapacity': batteryCapacity,
      'batteryVoltage': batteryVoltage,
      'batteryCurrent': batteryCurrent,
      'batteryTemperature': batteryTemperature,
      'range': range,
      'speed': speed,
      'odometer': odometer,
      'power': power,
      'cumulativeCharge': cumulativeCharge,
      'cumulativeDischarge': cumulativeDischarge,
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'gpsSpeed': gpsSpeed,
      'heading': heading,
      'chargingStatus': chargingStatus,
      'chargingStatusDescription': chargingStatusDescription,
      'isCharging': isCharging,
      if (additionalProperties != null) ...additionalProperties!,
    };
  }

  /// Create from JSON
  factory VehicleData.fromJson(Map<String, dynamic> json) {
    return VehicleData(
      timestamp: DateTime.parse(json['timestamp'] as String),
      stateOfCharge: (json['stateOfCharge'] as num?)?.toDouble(),
      stateOfHealth: (json['stateOfHealth'] as num?)?.toDouble(),
      batteryCapacity: (json['batteryCapacity'] as num?)?.toDouble(),
      batteryVoltage: (json['batteryVoltage'] as num?)?.toDouble(),
      batteryCurrent: (json['batteryCurrent'] as num?)?.toDouble(),
      batteryTemperature: (json['batteryTemperature'] as num?)?.toDouble(),
      range: (json['range'] as num?)?.toDouble(),
      speed: (json['speed'] as num?)?.toDouble(),
      odometer: (json['odometer'] as num?)?.toDouble(),
      power: (json['power'] as num?)?.toDouble(),
      cumulativeCharge: (json['cumulativeCharge'] as num?)?.toDouble(),
      cumulativeDischarge: (json['cumulativeDischarge'] as num?)?.toDouble(),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      gpsSpeed: (json['gpsSpeed'] as num?)?.toDouble(),
      heading: (json['heading'] as num?)?.toDouble(),
    );
  }

  /// Create a copy with updated fields
  VehicleData copyWith({
    DateTime? timestamp,
    double? stateOfCharge,
    double? stateOfHealth,
    double? batteryCapacity,
    double? batteryVoltage,
    double? batteryCurrent,
    double? batteryTemperature,
    double? range,
    double? speed,
    double? odometer,
    double? power,
    double? cumulativeCharge,
    double? cumulativeDischarge,
    double? latitude,
    double? longitude,
    double? altitude,
    double? gpsSpeed,
    double? heading,
    Map<String, dynamic>? additionalProperties,
  }) {
    return VehicleData(
      timestamp: timestamp ?? this.timestamp,
      stateOfCharge: stateOfCharge ?? this.stateOfCharge,
      stateOfHealth: stateOfHealth ?? this.stateOfHealth,
      batteryCapacity: batteryCapacity ?? this.batteryCapacity,
      batteryVoltage: batteryVoltage ?? this.batteryVoltage,
      batteryCurrent: batteryCurrent ?? this.batteryCurrent,
      batteryTemperature: batteryTemperature ?? this.batteryTemperature,
      range: range ?? this.range,
      speed: speed ?? this.speed,
      odometer: odometer ?? this.odometer,
      power: power ?? this.power,
      cumulativeCharge: cumulativeCharge ?? this.cumulativeCharge,
      cumulativeDischarge: cumulativeDischarge ?? this.cumulativeDischarge,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      altitude: altitude ?? this.altitude,
      gpsSpeed: gpsSpeed ?? this.gpsSpeed,
      heading: heading ?? this.heading,
      additionalProperties: additionalProperties ?? this.additionalProperties,
    );
  }

  @override
  String toString() {
    return 'VehicleData(timestamp: $timestamp, SOC: $stateOfCharge%, SOH: $stateOfHealth%, '
        'voltage: $batteryVoltage V, temp: $batteryTemperature°C, range: $range km, '
        'speed: $speed km/h, power: $power kW)';
  }
}
