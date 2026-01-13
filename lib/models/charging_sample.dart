/// Represents a single data point during a charging session for curve visualization
class ChargingSample {
  /// Timestamp when this sample was recorded
  final DateTime timestamp;

  /// State of charge percentage (0-100)
  final double soc;

  /// Charging power in kW (positive = charging)
  final double powerKw;

  /// Battery temperature in Celsius (optional)
  final double? temperature;

  /// Battery voltage in Volts (optional)
  final double? voltage;

  /// Battery current in Amps (optional, negative = charging)
  final double? current;

  const ChargingSample({
    required this.timestamp,
    required this.soc,
    required this.powerKw,
    this.temperature,
    this.voltage,
    this.current,
  });

  /// Create from map (for storage deserialization)
  factory ChargingSample.fromMap(Map<String, dynamic> map) {
    return ChargingSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      soc: (map['soc'] as num).toDouble(),
      powerKw: (map['powerKw'] as num).toDouble(),
      temperature: map['temperature'] != null
          ? (map['temperature'] as num).toDouble()
          : null,
      voltage:
          map['voltage'] != null ? (map['voltage'] as num).toDouble() : null,
      current:
          map['current'] != null ? (map['current'] as num).toDouble() : null,
    );
  }

  /// Convert to map (for storage serialization)
  Map<String, dynamic> toMap() {
    return {
      'timestamp': timestamp.millisecondsSinceEpoch,
      'soc': double.parse(soc.toStringAsFixed(2)),
      'powerKw': double.parse(powerKw.toStringAsFixed(2)),
      if (temperature != null)
        'temperature': double.parse(temperature!.toStringAsFixed(1)),
      if (voltage != null) 'voltage': double.parse(voltage!.toStringAsFixed(1)),
      if (current != null) 'current': double.parse(current!.toStringAsFixed(2)),
    };
  }

  /// Create from JSON (alias for fromMap)
  factory ChargingSample.fromJson(Map<String, dynamic> json) =>
      ChargingSample.fromMap(json);

  /// Convert to JSON (alias for toMap)
  Map<String, dynamic> toJson() => toMap();

  @override
  String toString() {
    return 'ChargingSample(timestamp: $timestamp, soc: $soc%, power: ${powerKw}kW)';
  }

  /// Create a copy with modified fields
  ChargingSample copyWith({
    DateTime? timestamp,
    double? soc,
    double? powerKw,
    double? temperature,
    double? voltage,
    double? current,
  }) {
    return ChargingSample(
      timestamp: timestamp ?? this.timestamp,
      soc: soc ?? this.soc,
      powerKw: powerKw ?? this.powerKw,
      temperature: temperature ?? this.temperature,
      voltage: voltage ?? this.voltage,
      current: current ?? this.current,
    );
  }
}
