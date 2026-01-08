import 'dart:convert';

/// Model representing a charging session with start/end data
class ChargingSession {
  final String id;
  final DateTime startTime;
  final DateTime? endTime;
  final double startCumulativeCharge; // Ah at start
  final double? endCumulativeCharge; // Ah at end
  final double startSoc; // SOC % at start
  final double? endSoc; // SOC % at end
  final double startOdometer; // km at start
  final double? endOdometer; // km at end (should be same if charging)
  final bool isActive; // true if session is ongoing

  ChargingSession({
    required this.id,
    required this.startTime,
    this.endTime,
    required this.startCumulativeCharge,
    this.endCumulativeCharge,
    required this.startSoc,
    this.endSoc,
    required this.startOdometer,
    this.endOdometer,
    this.isActive = true,
  });

  /// Calculate energy added during this session (Ah)
  double? get energyAddedAh {
    if (endCumulativeCharge == null) return null;
    return endCumulativeCharge! - startCumulativeCharge;
  }

  /// Calculate SOC gained during this session (%)
  double? get socGained {
    if (endSoc == null) return null;
    return endSoc! - startSoc;
  }

  /// Calculate duration of charging session
  Duration? get duration {
    if (endTime == null) return null;
    return endTime!.difference(startTime);
  }

  /// Calculate average charging rate (Ah/hour)
  double? get averageChargingRateAh {
    final dur = duration;
    final energy = energyAddedAh;
    if (dur == null || energy == null || dur.inSeconds == 0) return null;
    return energy / (dur.inSeconds / 3600);
  }

  /// Create a completed session from an active one
  ChargingSession complete({
    required DateTime endTime,
    required double endCumulativeCharge,
    required double endSoc,
    double? endOdometer,
  }) {
    return ChargingSession(
      id: id,
      startTime: startTime,
      endTime: endTime,
      startCumulativeCharge: startCumulativeCharge,
      endCumulativeCharge: endCumulativeCharge,
      startSoc: startSoc,
      endSoc: endSoc,
      startOdometer: startOdometer,
      endOdometer: endOdometer ?? startOdometer,
      isActive: false,
    );
  }

  /// Convert to JSON for MQTT transmission
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime?.toIso8601String(),
      'startCumulativeCharge': startCumulativeCharge,
      'endCumulativeCharge': endCumulativeCharge,
      'energyAddedAh': energyAddedAh,
      'startSoc': startSoc,
      'endSoc': endSoc,
      'socGained': socGained,
      'startOdometer': startOdometer,
      'endOdometer': endOdometer,
      'durationSeconds': duration?.inSeconds,
      'averageChargingRateAh': averageChargingRateAh,
      'isActive': isActive,
    };
  }

  /// Convert to JSON string
  String toJsonString() => jsonEncode(toJson());

  /// Create from JSON
  factory ChargingSession.fromJson(Map<String, dynamic> json) {
    return ChargingSession(
      id: json['id'] as String,
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: json['endTime'] != null
          ? DateTime.parse(json['endTime'] as String)
          : null,
      startCumulativeCharge: (json['startCumulativeCharge'] as num).toDouble(),
      endCumulativeCharge: (json['endCumulativeCharge'] as num?)?.toDouble(),
      startSoc: (json['startSoc'] as num).toDouble(),
      endSoc: (json['endSoc'] as num?)?.toDouble(),
      startOdometer: (json['startOdometer'] as num).toDouble(),
      endOdometer: (json['endOdometer'] as num?)?.toDouble(),
      isActive: json['isActive'] as bool? ?? false,
    );
  }

  /// Create from JSON string
  factory ChargingSession.fromJsonString(String jsonString) {
    return ChargingSession.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
  }

  /// Convert to Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'startTime': startTime.millisecondsSinceEpoch,
      'endTime': endTime?.millisecondsSinceEpoch,
      'startCumulativeCharge': startCumulativeCharge,
      'endCumulativeCharge': endCumulativeCharge,
      'startSoc': startSoc,
      'endSoc': endSoc,
      'startOdometer': startOdometer,
      'endOdometer': endOdometer,
      'isActive': isActive ? 1 : 0,
    };
  }

  /// Create from Map (database)
  factory ChargingSession.fromMap(Map<String, dynamic> map) {
    return ChargingSession(
      id: map['id'] as String,
      startTime: DateTime.fromMillisecondsSinceEpoch(map['startTime'] as int),
      endTime: map['endTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['endTime'] as int)
          : null,
      startCumulativeCharge: map['startCumulativeCharge'] as double,
      endCumulativeCharge: map['endCumulativeCharge'] as double?,
      startSoc: map['startSoc'] as double,
      endSoc: map['endSoc'] as double?,
      startOdometer: map['startOdometer'] as double,
      endOdometer: map['endOdometer'] as double?,
      isActive: (map['isActive'] as int) == 1,
    );
  }

  @override
  String toString() {
    return 'ChargingSession(id: $id, start: $startTime, end: $endTime, '
        'energyAdded: ${energyAddedAh?.toStringAsFixed(2)} Ah, '
        'SOC: $startSoc% -> ${endSoc ?? "ongoing"}%, '
        'active: $isActive)';
  }
}
