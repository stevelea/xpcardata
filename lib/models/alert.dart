enum AlertSeverity { info, warning, critical }

class VehicleAlert {
  final String id;
  final String title;
  final String message;
  final AlertSeverity severity;
  final DateTime timestamp;
  final bool isRead;

  VehicleAlert({
    required this.id,
    required this.title,
    required this.message,
    required this.severity,
    required this.timestamp,
    this.isRead = false,
  });

  /// Convert to Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'message': message,
      'severity': severity.index,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isRead': isRead ? 1 : 0,
    };
  }

  /// Create from Map (database)
  factory VehicleAlert.fromMap(Map<String, dynamic> map) {
    return VehicleAlert(
      id: map['id'] as String,
      title: map['title'] as String,
      message: map['message'] as String,
      severity: AlertSeverity.values[map['severity'] as int],
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      isRead: (map['isRead'] as int) == 1,
    );
  }

  /// Convert to JSON for MQTT transmission
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'message': message,
      'severity': severity.name,
      'timestamp': timestamp.toIso8601String(),
      'isRead': isRead,
    };
  }

  /// Create from JSON
  factory VehicleAlert.fromJson(Map<String, dynamic> json) {
    return VehicleAlert(
      id: json['id'] as String,
      title: json['title'] as String,
      message: json['message'] as String,
      severity: AlertSeverity.values.firstWhere(
        (e) => e.name == json['severity'],
        orElse: () => AlertSeverity.info,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
      isRead: json['isRead'] as bool? ?? false,
    );
  }

  /// Create a copy with updated fields
  VehicleAlert copyWith({
    String? id,
    String? title,
    String? message,
    AlertSeverity? severity,
    DateTime? timestamp,
    bool? isRead,
  }) {
    return VehicleAlert(
      id: id ?? this.id,
      title: title ?? this.title,
      message: message ?? this.message,
      severity: severity ?? this.severity,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
    );
  }

  @override
  String toString() {
    return 'VehicleAlert(id: $id, title: $title, severity: $severity, timestamp: $timestamp, isRead: $isRead)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is VehicleAlert && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
