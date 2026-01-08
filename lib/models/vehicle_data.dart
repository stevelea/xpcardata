import 'dart:convert';

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
    this.additionalProperties,
  });

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
      additionalProperties: map['additionalProperties'] != null
          ? jsonDecode(map['additionalProperties'] as String) as Map<String, dynamic>
          : null,
    );
  }

  /// Convert to JSON for MQTT transmission
  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.toIso8601String(),
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
