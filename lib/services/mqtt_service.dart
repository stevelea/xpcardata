import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vehicle_data.dart';
import '../models/alert.dart';
import '../models/charging_session.dart';
import '../providers/vehicle_data_provider.dart' show vehicleBatteryCapacities;
import 'data_usage_service.dart';
import 'hive_storage_service.dart';

/// App version constant (updated during build)
const String _appVersion = '1.2.0';

/// Service for publishing vehicle data to MQTT broker
class MqttService {
  MqttServerClient? _client;
  String? _vehicleId;

  final StreamController<MqttConnectionState> _connectionStateController =
      StreamController<MqttConnectionState>.broadcast();

  // Configuration
  String? _broker;
  int? _port;
  String? _username;
  String? _password;
  bool _useTLS = true;
  bool _haDiscoveryEnabled = false;
  bool _discoveryPublished = false;
  static const String _discoveryPrefix = 'homeassistant';

  // Connection state
  bool _isConnecting = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  Timer? _reconnectTimer;
  Timer? _periodicReconnectTimer;
  int _periodicReconnectIntervalSeconds = 0; // 0 = disabled

  /// Get Home Assistant discovery enabled state
  bool get haDiscoveryEnabled => _haDiscoveryEnabled;

  /// Set Home Assistant discovery enabled state
  set haDiscoveryEnabled(bool value) {
    _haDiscoveryEnabled = value;
    if (value && isConnected && !_discoveryPublished) {
      _publishHADiscovery();
    }
  }

  Stream<MqttConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  /// Get periodic reconnect interval in seconds (0 = disabled)
  int get periodicReconnectInterval => _periodicReconnectIntervalSeconds;

  /// Set periodic reconnect interval in seconds (0 = disabled)
  /// When enabled, will attempt to reconnect at this interval if disconnected
  set periodicReconnectInterval(int seconds) {
    _periodicReconnectIntervalSeconds = seconds;
    _updatePeriodicReconnect();
  }

  /// Initialize and connect to MQTT broker
  Future<bool> connect({
    required String broker,
    required int port,
    required String vehicleId,
    String? username,
    String? password,
    bool useTLS = true,
  }) async {
    if (_isConnecting) {
      return false;
    }

    try {
      _isConnecting = true;
      _broker = broker;
      _port = port;
      _vehicleId = vehicleId;
      _username = username;
      _password = password;
      _useTLS = useTLS;

      // Create client
      _client = MqttServerClient.withPort(broker, vehicleId, port);
      _client!.logging(on: false);
      _client!.keepAlivePeriod = 60;
      _client!.autoReconnect = false; // We'll handle reconnection manually
      _client!.onConnected = _onConnected;
      _client!.onDisconnected = _onDisconnected;
      _client!.onAutoReconnect = _onAutoReconnect;
      _client!.onAutoReconnected = _onAutoReconnected;

      // Set up TLS if enabled
      if (useTLS) {
        _client!.secure = true;
        _client!.securityContext = SecurityContext.defaultContext;
        // Allow self-signed certificates for testing (remove in production)
        _client!.onBadCertificate = (dynamic certificate) => true;
      }

      // Set up last will and testament
      final willTopic = 'vehicles/$vehicleId/status';
      final willPayload = jsonEncode({
        'status': 'offline',
        'timestamp': DateTime.now().toIso8601String(),
      });
      _client!.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(vehicleId)
          .withWillTopic(willTopic)
          .withWillMessage(willPayload)
          .withWillQos(MqttQos.atLeastOnce)
          .withWillRetain()
          .startClean();

      // Set credentials if provided
      if (username != null && password != null) {
        _client!.connectionMessage =
            _client!.connectionMessage!.authenticateAs(username, password);
      }

      // Connect
      await _client!.connect();

      if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
        _reconnectAttempts = 0;
        _publishOnlineStatus();
        return true;
      } else {
        _client!.disconnect();
        return false;
      }
    } catch (e) {
      _client?.disconnect();
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  /// Disconnect from MQTT broker
  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    if (_client != null && isConnected) {
      _publishOfflineStatus();
      _client!.disconnect();
    }
  }

  /// Publish vehicle data to MQTT (single topic with all data)
  Future<void> publishVehicleData(VehicleData data) async {
    if (!isConnected || _vehicleId == null) {
      return;
    }

    try {
      final topic = 'vehicles/$_vehicleId/data';
      final json = data.toJson();

      // Fill in battery capacity from user settings if not provided by OBD
      if (json['batteryCapacity'] == null || json['batteryCapacity'] == 0) {
        json['batteryCapacity'] = await _getBatteryCapacityFromSettings();
      }

      final payload = jsonEncode(json);
      _publishMessage(topic, payload, MqttQos.atLeastOnce, retain: true);
    } catch (e) {
      // Silently fail - connection issues will trigger reconnection
    }
  }

  /// Get battery capacity from user settings (cached)
  double? _cachedBatteryCapacity;
  Future<double> _getBatteryCapacityFromSettings() async {
    if (_cachedBatteryCapacity != null) return _cachedBatteryCapacity!;

    String vehicleModel = '24LR'; // Default

    // Try Hive first (most reliable on AAOS)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      vehicleModel = hive.getSetting<String>('vehicle_model') ?? vehicleModel;
    } else {
      // Fall back to SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        vehicleModel = prefs.getString('vehicle_model') ?? vehicleModel;
      } catch (e) {
        // Use default
      }
    }

    _cachedBatteryCapacity = vehicleBatteryCapacities[vehicleModel] ?? 87.5;
    return _cachedBatteryCapacity!;
  }

  /// Publish alert to MQTT
  Future<void> publishAlert(VehicleAlert alert) async {
    if (!isConnected || _vehicleId == null) {
      return;
    }

    try {
      final topic = 'vehicles/$_vehicleId/alerts';
      final payload = jsonEncode(alert.toJson());
      _publishMessage(topic, payload, MqttQos.atLeastOnce);
    } catch (e) {
      // Silently fail
    }
  }

  /// Publish system alert (12V battery, connectivity issues, etc.)
  /// [alertType] identifies the alert: '12v_low', 'obd_disconnected', etc.
  /// [isActive] true = alert is active, false = alert cleared
  /// Publishes to vehicles/{id}/system_alert with retain flag for HA persistence
  Future<void> publishSystemAlert({
    required String alertType,
    required bool isActive,
    required String message,
    Map<String, dynamic>? additionalData,
  }) async {
    if (!isConnected || _vehicleId == null) {
      return;
    }

    try {
      final topic = 'vehicles/$_vehicleId/system_alert';
      final payload = jsonEncode({
        'alert_type': alertType,
        'status': isActive ? 'ALERT' : 'CLEAR',
        'message': message,
        'timestamp': DateTime.now().toIso8601String(),
        if (additionalData != null) ...additionalData,
      });
      _publishMessage(topic, payload, MqttQos.atLeastOnce, retain: true);
    } catch (e) {
      // Silently fail
    }
  }

  /// Publish charging notification (start/stop events with SOC)
  /// [event] is 'CHARGE_STARTED' or 'CHARGE_STOPPED'
  /// Publishes to vehicles/{id}/charging_notification for HA automations
  Future<void> publishChargingNotification({
    required String event,
    required double soc,
    String? chargingType,
    double? powerKw,
    String? locationName,
  }) async {
    if (!isConnected || _vehicleId == null) {
      return;
    }

    try {
      final topic = 'vehicles/$_vehicleId/charging_notification';
      final payload = jsonEncode({
        'event': event,
        'soc': soc,
        if (chargingType != null) 'charging_type': chargingType,
        if (powerKw != null) 'power_kw': powerKw,
        if (locationName != null) 'location': locationName,
        'timestamp': DateTime.now().toIso8601String(),
      });
      _publishMessage(topic, payload, MqttQos.atLeastOnce, retain: true);
    } catch (e) {
      // Silently fail
    }
  }

  /// Publish charging session to MQTT with retain flag
  /// [status] can be 'START', 'UPDATE', or 'STOP'
  /// [currentOdometer] is the current vehicle odometer reading
  /// [previousSessionOdometer] is the odometer from the end of the previous charging session
  Future<void> publishChargingSession(
    ChargingSession session, {
    required String status,
    double? currentOdometer,
    double? previousSessionOdometer,
  }) async {
    if (!isConnected || _vehicleId == null) {
      return;
    }

    try {
      final topic = 'vehicles/$_vehicleId/charging';
      final sessionData = session.toJson();
      // Add status and odometer fields
      sessionData['status'] = status;
      sessionData['currentOdometer'] = currentOdometer ?? session.endOdometer ?? session.startOdometer;
      sessionData['previousSessionOdometer'] = previousSessionOdometer ?? session.previousSessionOdometer;
      sessionData['timestamp'] = DateTime.now().toIso8601String();
      final payload = jsonEncode(sessionData);
      _publishMessage(topic, payload, MqttQos.atLeastOnce, retain: true);
    } catch (e) {
      // Silently fail
    }
  }

  /// Publish charging history (list of sessions) to MQTT with retain flag
  Future<void> publishChargingHistory(List<ChargingSession> sessions) async {
    if (!isConnected || _vehicleId == null) {
      return;
    }

    try {
      final topic = 'vehicles/$_vehicleId/charging_history';
      final payload = jsonEncode({
        'sessions': sessions.map((s) => s.toJson()).toList(),
        'count': sessions.length,
        'lastUpdated': DateTime.now().toIso8601String(),
      });
      _publishMessage(topic, payload, MqttQos.atLeastOnce, retain: true);
    } catch (e) {
      // Silently fail
    }
  }

  /// Helper method to publish message
  void _publishMessage(
    String topic,
    String payload,
    MqttQos qos, {
    bool retain = false,
  }) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);
    _client?.publishMessage(topic, qos, builder.payload!, retain: retain);

    // Track data usage (topic + payload bytes)
    final bytesSent = topic.length + payload.length;
    DataUsageService.instance.recordMqttSent(bytesSent);
  }

  /// Publish online status
  void _publishOnlineStatus() {
    if (_vehicleId == null) return;

    final topic = 'vehicles/$_vehicleId/status';
    final payload = jsonEncode({
      'status': 'online',
      'timestamp': DateTime.now().toIso8601String(),
    });
    _publishMessage(topic, payload, MqttQos.atLeastOnce, retain: true);

    // Publish HA discovery if enabled
    if (_haDiscoveryEnabled && !_discoveryPublished) {
      _publishHADiscovery();
    }
  }

  /// Publish Home Assistant MQTT Discovery configuration
  void _publishHADiscovery() {
    if (_vehicleId == null || !isConnected) return;

    final nodeId = _vehicleId!.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_').toLowerCase();
    final stateTopic = 'vehicles/$_vehicleId/data';
    final availabilityTopic = 'vehicles/$_vehicleId/status';

    // Device configuration shared by all entities
    final device = {
      'identifiers': [nodeId],
      'name': 'XPCarData $_vehicleId',
      'manufacturer': 'XPENG',
      'model': 'G6',
      'sw_version': _appVersion,
    };

    // Define all sensors with their configurations
    final sensors = <Map<String, dynamic>>[
      {
        'name': 'State of Charge',
        'object_id': 'soc',
        'device_class': 'battery',
        'unit_of_measurement': '%',
        'value_template': '{{ value_json.stateOfCharge | default(0) | round(1) }}',
        'icon': 'mdi:battery',
        'state_class': 'measurement',
      },
      {
        'name': 'State of Health',
        'object_id': 'soh',
        'device_class': 'battery',
        'unit_of_measurement': '%',
        'value_template': '{{ value_json.stateOfHealth | default(0) | round(1) }}',
        'icon': 'mdi:battery-heart-variant',
        'state_class': 'measurement',
      },
      {
        'name': 'Battery Voltage',
        'object_id': 'voltage',
        'device_class': 'voltage',
        'unit_of_measurement': 'V',
        'value_template': '{{ value_json.batteryVoltage | default(0) | round(1) }}',
        'state_class': 'measurement',
      },
      {
        'name': 'Battery Current',
        'object_id': 'current',
        'device_class': 'current',
        'unit_of_measurement': 'A',
        'value_template': '{{ value_json.batteryCurrent | default(0) | round(1) }}',
        'state_class': 'measurement',
      },
      {
        'name': 'Battery Temperature',
        'object_id': 'temperature',
        'device_class': 'temperature',
        'unit_of_measurement': '°C',
        'value_template': '{{ value_json.batteryTemperature | default(0) | round(1) }}',
        'state_class': 'measurement',
      },
      {
        'name': 'Power',
        'object_id': 'power',
        'device_class': 'power',
        'unit_of_measurement': 'kW',
        'value_template': '{{ value_json.power | default(0) | round(2) }}',
        'state_class': 'measurement',
      },
      {
        'name': 'Range',
        'object_id': 'range',
        'device_class': 'distance',
        'unit_of_measurement': 'km',
        'value_template': '{{ value_json.range | default(0) | round(0) }}',
        'icon': 'mdi:map-marker-distance',
        'state_class': 'measurement',
      },
      {
        'name': 'Speed',
        'object_id': 'speed',
        'device_class': 'speed',
        'unit_of_measurement': 'km/h',
        'value_template': '{{ value_json.speed | default(0) | round(0) }}',
        'state_class': 'measurement',
      },
      {
        'name': 'Odometer',
        'object_id': 'odometer',
        'device_class': 'distance',
        'unit_of_measurement': 'km',
        'value_template': '{{ value_json.odometer | default(0) | round(0) }}',
        'icon': 'mdi:counter',
        'state_class': 'total_increasing',
      },
      {
        'name': 'Battery Capacity',
        'object_id': 'capacity',
        'device_class': 'energy_storage',
        'unit_of_measurement': 'kWh',
        'value_template': '{{ value_json.batteryCapacity | default(0) | round(1) }}',
        'icon': 'mdi:battery-high',
        'state_class': 'measurement',
      },
      {
        'name': 'Latitude',
        'object_id': 'latitude',
        'unit_of_measurement': '°',
        'value_template': '{{ value_json.latitude | default(0) | round(6) }}',
        'icon': 'mdi:crosshairs-gps',
        'state_class': 'measurement',
      },
      {
        'name': 'Longitude',
        'object_id': 'longitude',
        'unit_of_measurement': '°',
        'value_template': '{{ value_json.longitude | default(0) | round(6) }}',
        'icon': 'mdi:crosshairs-gps',
        'state_class': 'measurement',
      },
      {
        'name': 'Altitude',
        'object_id': 'altitude',
        'unit_of_measurement': 'm',
        'value_template': '{{ value_json.altitude | default(0) | round(0) }}',
        'icon': 'mdi:altimeter',
        'state_class': 'measurement',
      },
      {
        'name': 'GPS Speed',
        'object_id': 'gps_speed',
        'device_class': 'speed',
        'unit_of_measurement': 'km/h',
        'value_template': '{{ value_json.gpsSpeed | default(0) | round(0) }}',
        'state_class': 'measurement',
      },
      {
        'name': 'Heading',
        'object_id': 'heading',
        'unit_of_measurement': '°',
        'value_template': '{{ value_json.heading | default(0) | round(0) }}',
        'icon': 'mdi:compass',
        'state_class': 'measurement',
      },
      {
        'name': 'Charging Status',
        'object_id': 'charging_status',
        'value_template': '{{ value_json.chargingStatus | default("Unknown") }}',
        'icon': 'mdi:ev-station',
      },
      {
        'name': 'Local Time',
        'object_id': 'local_time',
        'device_class': 'timestamp',
        'value_template': '{{ value_json.localTime | default("") }}',
        'icon': 'mdi:clock-outline',
      },
    ];

    // Publish discovery config for each sensor
    for (final sensor in sensors) {
      final objectId = sensor['object_id'] as String;
      final discoveryTopic = '$_discoveryPrefix/sensor/$nodeId/${objectId}/config';

      final config = {
        'name': sensor['name'],
        'unique_id': '${nodeId}_$objectId',
        'state_topic': stateTopic,
        'availability_topic': availabilityTopic,
        'availability_template': '{{ value_json.status }}',
        'payload_available': 'online',
        'payload_not_available': 'offline',
        'device': device,
        'device_class': sensor['device_class'],
        'unit_of_measurement': sensor['unit_of_measurement'],
        'value_template': sensor['value_template'],
        'state_class': sensor['state_class'],
        if (sensor.containsKey('icon')) 'icon': sensor['icon'],
      };

      _publishMessage(
        discoveryTopic,
        jsonEncode(config),
        MqttQos.atLeastOnce,
        retain: true,
      );
    }

    // Publish binary sensor for charging status
    final chargingDiscoveryTopic = '$_discoveryPrefix/binary_sensor/$nodeId/charging/config';
    final chargingConfig = {
      'name': 'Charging',
      'unique_id': '${nodeId}_charging',
      'state_topic': stateTopic,
      'availability_topic': availabilityTopic,
      'availability_template': '{{ value_json.status }}',
      'payload_available': 'online',
      'payload_not_available': 'offline',
      'device': device,
      'device_class': 'battery_charging',
      'value_template': '{{ "ON" if value_json.isCharging | default(false) else "OFF" }}',
      'payload_on': 'ON',
      'payload_off': 'OFF',
    };

    _publishMessage(
      chargingDiscoveryTopic,
      jsonEncode(chargingConfig),
      MqttQos.atLeastOnce,
      retain: true,
    );

    // Publish sensor for system alerts (12V battery low, etc.)
    final systemAlertTopic = 'vehicles/$_vehicleId/system_alert';
    final systemAlertDiscoveryTopic = '$_discoveryPrefix/sensor/$nodeId/system_alert/config';
    final systemAlertConfig = {
      'name': 'System Alert',
      'unique_id': '${nodeId}_system_alert',
      'state_topic': systemAlertTopic,
      'availability_topic': availabilityTopic,
      'availability_template': '{{ value_json.status }}',
      'payload_available': 'online',
      'payload_not_available': 'offline',
      'device': device,
      'value_template': '{{ value_json.status }}',
      'icon': 'mdi:alert-circle',
      'json_attributes_topic': systemAlertTopic,
      'json_attributes_template': '{{ value_json | tojson }}',
    };

    _publishMessage(
      systemAlertDiscoveryTopic,
      jsonEncode(systemAlertConfig),
      MqttQos.atLeastOnce,
      retain: true,
    );

    // Publish sensor for charging notifications
    final chargingNotificationTopic = 'vehicles/$_vehicleId/charging_notification';
    final chargingNotificationDiscoveryTopic = '$_discoveryPrefix/sensor/$nodeId/charging_notification/config';
    final chargingNotificationConfig = {
      'name': 'Charging Event',
      'unique_id': '${nodeId}_charging_notification',
      'state_topic': chargingNotificationTopic,
      'availability_topic': availabilityTopic,
      'availability_template': '{{ value_json.status }}',
      'payload_available': 'online',
      'payload_not_available': 'offline',
      'device': device,
      'value_template': '{{ value_json.event }}',
      'icon': 'mdi:ev-station',
      'json_attributes_topic': chargingNotificationTopic,
      'json_attributes_template': '{{ value_json | tojson }}',
    };

    _publishMessage(
      chargingNotificationDiscoveryTopic,
      jsonEncode(chargingNotificationConfig),
      MqttQos.atLeastOnce,
      retain: true,
    );

    _discoveryPublished = true;
  }

  /// Remove Home Assistant discovery configuration (for cleanup)
  void removeHADiscovery() {
    if (_vehicleId == null || !isConnected) return;

    final nodeId = _vehicleId!.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_').toLowerCase();
    final sensorIds = ['soc', 'soh', 'voltage', 'current', 'temperature', 'power', 'range', 'speed', 'odometer', 'capacity', 'system_alert', 'charging_notification'];

    // Remove sensor configs by publishing empty retained message
    for (final objectId in sensorIds) {
      final discoveryTopic = '$_discoveryPrefix/sensor/$nodeId/${objectId}/config';
      _publishMessage(discoveryTopic, '', MqttQos.atLeastOnce, retain: true);
    }

    // Remove charging binary sensor
    final chargingDiscoveryTopic = '$_discoveryPrefix/binary_sensor/$nodeId/charging/config';
    _publishMessage(chargingDiscoveryTopic, '', MqttQos.atLeastOnce, retain: true);

    _discoveryPublished = false;
  }

  /// Publish offline status
  void _publishOfflineStatus() {
    if (_vehicleId == null) return;

    final topic = 'vehicles/$_vehicleId/status';
    final payload = jsonEncode({
      'status': 'offline',
      'timestamp': DateTime.now().toIso8601String(),
    });
    _publishMessage(topic, payload, MqttQos.atLeastOnce, retain: true);
  }

  /// Handle successful connection
  void _onConnected() {
    _connectionStateController.add(MqttConnectionState.connected);
    _reconnectAttempts = 0;
  }

  /// Handle disconnection
  void _onDisconnected() {
    _connectionStateController.add(MqttConnectionState.disconnected);
    _attemptReconnection();
  }

  /// Handle auto-reconnect initiated
  void _onAutoReconnect() {
    _connectionStateController.add(MqttConnectionState.connecting);
  }

  /// Handle auto-reconnect completed
  void _onAutoReconnected() {
    _connectionStateController.add(MqttConnectionState.connected);
    _reconnectAttempts = 0;
    _publishOnlineStatus();
  }

  /// Attempt reconnection with exponential backoff
  void _attemptReconnection() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      return;
    }

    // Calculate backoff delay (exponential: 2^attempt seconds, max 60s)
    final delay = Duration(
      seconds: (2 << _reconnectAttempts).clamp(1, 60),
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      _reconnectAttempts++;

      if (_broker != null && _port != null && _vehicleId != null) {
        await connect(
          broker: _broker!,
          port: _port!,
          vehicleId: _vehicleId!,
          username: _username,
          password: _password,
          useTLS: _useTLS,
        );
      }
    });
  }

  /// Update periodic reconnect timer based on current settings
  void _updatePeriodicReconnect() {
    _periodicReconnectTimer?.cancel();
    _periodicReconnectTimer = null;

    if (_periodicReconnectIntervalSeconds > 0) {
      _periodicReconnectTimer = Timer.periodic(
        Duration(seconds: _periodicReconnectIntervalSeconds),
        (_) => _tryPeriodicReconnect(),
      );
    }
  }

  /// Try to reconnect if not connected (called by periodic timer)
  Future<void> _tryPeriodicReconnect() async {
    if (isConnected || _isConnecting) {
      return; // Already connected or connecting
    }

    if (_broker == null || _port == null || _vehicleId == null) {
      return; // No connection settings configured
    }

    // Reset reconnect attempts to allow a fresh try
    _reconnectAttempts = 0;

    await connect(
      broker: _broker!,
      port: _port!,
      vehicleId: _vehicleId!,
      username: _username,
      password: _password,
      useTLS: _useTLS,
    );
  }

  /// Dispose resources
  void dispose() {
    _reconnectTimer?.cancel();
    _periodicReconnectTimer?.cancel();
    disconnect();
    _connectionStateController.close();
  }
}
