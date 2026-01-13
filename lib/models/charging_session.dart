import 'dart:convert';

/// Model representing a charging session with start/end data and consumption tracking
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
  final String? chargingType; // 'ac', 'dc', or 'unknown'
  final double? maxPowerKw; // Maximum power during session (kW)

  // New fields for consumption tracking
  final double? energyAddedKwh; // Energy added in kWh (calculated from Ah * avg voltage)
  final double? distanceSinceLastCharge; // km driven since last charge
  final double? consumptionKwhPer100km; // Calculated consumption
  final double? previousSessionOdometer; // Odometer at end of previous charge

  // Location data (from GPS)
  final double? latitude; // GPS latitude
  final double? longitude; // GPS longitude

  // Manual/editable fields
  final String? locationName; // User-entered location name or reverse geocoded
  final double? chargingCost; // Cost in user's currency
  final String? notes; // User notes

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
    this.chargingType,
    this.maxPowerKw,
    this.energyAddedKwh,
    this.distanceSinceLastCharge,
    this.consumptionKwhPer100km,
    this.previousSessionOdometer,
    this.latitude,
    this.longitude,
    this.locationName,
    this.chargingCost,
    this.notes,
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
    double? averageVoltage,
    double? previousOdometer,
  }) {
    final energyAh = endCumulativeCharge - startCumulativeCharge;
    final energyKwh = averageVoltage != null ? (energyAh * averageVoltage) / 1000.0 : null;
    final distance = previousOdometer != null ? startOdometer - previousOdometer : null;
    final consumption = (distance != null && distance > 0 && energyKwh != null)
        ? (energyKwh / distance) * 100.0
        : null;

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
      chargingType: chargingType,
      maxPowerKw: maxPowerKw,
      energyAddedKwh: energyKwh,
      distanceSinceLastCharge: distance,
      consumptionKwhPer100km: consumption,
      previousSessionOdometer: previousOdometer,
      latitude: latitude,
      longitude: longitude,
      locationName: locationName,
      chargingCost: chargingCost,
      notes: notes,
    );
  }

  /// Create a copy with updated manual fields
  ChargingSession copyWith({
    String? locationName,
    double? chargingCost,
    String? notes,
    double? energyAddedKwh,
    double? latitude,
    double? longitude,
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
      endOdometer: endOdometer,
      isActive: isActive,
      chargingType: chargingType,
      maxPowerKw: maxPowerKw,
      energyAddedKwh: energyAddedKwh ?? this.energyAddedKwh,
      distanceSinceLastCharge: distanceSinceLastCharge,
      consumptionKwhPer100km: consumptionKwhPer100km,
      previousSessionOdometer: previousSessionOdometer,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      chargingCost: chargingCost ?? this.chargingCost,
      notes: notes ?? this.notes,
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
      'energyAddedKwh': energyAddedKwh,
      'startSoc': startSoc,
      'endSoc': endSoc,
      'socGained': socGained,
      'startOdometer': startOdometer,
      'endOdometer': endOdometer,
      'durationSeconds': duration?.inSeconds,
      'averageChargingRateAh': averageChargingRateAh,
      'isActive': isActive,
      'chargingType': chargingType,
      'maxPowerKw': maxPowerKw,
      'distanceSinceLastCharge': distanceSinceLastCharge,
      'consumptionKwhPer100km': consumptionKwhPer100km,
      'previousSessionOdometer': previousSessionOdometer,
      'latitude': latitude,
      'longitude': longitude,
      'locationName': locationName,
      'chargingCost': chargingCost,
      'notes': notes,
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
      chargingType: json['chargingType'] as String?,
      maxPowerKw: (json['maxPowerKw'] as num?)?.toDouble(),
      energyAddedKwh: (json['energyAddedKwh'] as num?)?.toDouble(),
      distanceSinceLastCharge: (json['distanceSinceLastCharge'] as num?)?.toDouble(),
      consumptionKwhPer100km: (json['consumptionKwhPer100km'] as num?)?.toDouble(),
      previousSessionOdometer: (json['previousSessionOdometer'] as num?)?.toDouble(),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      locationName: json['locationName'] as String?,
      chargingCost: (json['chargingCost'] as num?)?.toDouble(),
      notes: json['notes'] as String?,
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
      'chargingType': chargingType,
      'maxPowerKw': maxPowerKw,
      'energyAddedKwh': energyAddedKwh,
      'distanceSinceLastCharge': distanceSinceLastCharge,
      'consumptionKwhPer100km': consumptionKwhPer100km,
      'previousSessionOdometer': previousSessionOdometer,
      'latitude': latitude,
      'longitude': longitude,
      'locationName': locationName,
      'chargingCost': chargingCost,
      'notes': notes,
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
      startCumulativeCharge: (map['startCumulativeCharge'] as num).toDouble(),
      endCumulativeCharge: (map['endCumulativeCharge'] as num?)?.toDouble(),
      startSoc: (map['startSoc'] as num).toDouble(),
      endSoc: (map['endSoc'] as num?)?.toDouble(),
      startOdometer: (map['startOdometer'] as num).toDouble(),
      endOdometer: (map['endOdometer'] as num?)?.toDouble(),
      isActive: (map['isActive'] as int) == 1,
      chargingType: map['chargingType'] as String?,
      maxPowerKw: (map['maxPowerKw'] as num?)?.toDouble(),
      energyAddedKwh: (map['energyAddedKwh'] as num?)?.toDouble(),
      distanceSinceLastCharge: (map['distanceSinceLastCharge'] as num?)?.toDouble(),
      consumptionKwhPer100km: (map['consumptionKwhPer100km'] as num?)?.toDouble(),
      previousSessionOdometer: (map['previousSessionOdometer'] as num?)?.toDouble(),
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      locationName: map['locationName'] as String?,
      chargingCost: (map['chargingCost'] as num?)?.toDouble(),
      notes: map['notes'] as String?,
    );
  }

  @override
  String toString() {
    return 'ChargingSession(id: $id, type: ${chargingType ?? "unknown"}, '
        'start: $startTime, end: $endTime, '
        'energyAdded: ${energyAddedAh?.toStringAsFixed(2)} Ah, '
        'SOC: $startSoc% -> ${endSoc ?? "ongoing"}%, '
        'maxPower: ${maxPowerKw?.toStringAsFixed(1)} kW, '
        'active: $isActive)';
  }
}
