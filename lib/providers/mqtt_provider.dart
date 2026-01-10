import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/mqtt_service.dart';

// ==================== MQTT Settings Model ====================

/// MQTT connection settings
class MqttSettings {
  final String broker;
  final int port;
  final String vehicleId;
  final String? username;
  final String? password;
  final bool useTLS;

  const MqttSettings({
    required this.broker,
    required this.port,
    required this.vehicleId,
    this.username,
    this.password,
    this.useTLS = true,
  });

  MqttSettings copyWith({
    String? broker,
    int? port,
    String? vehicleId,
    String? username,
    String? password,
    bool? useTLS,
  }) {
    return MqttSettings(
      broker: broker ?? this.broker,
      port: port ?? this.port,
      vehicleId: vehicleId ?? this.vehicleId,
      username: username ?? this.username,
      password: password ?? this.password,
      useTLS: useTLS ?? this.useTLS,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'broker': broker,
      'port': port,
      'vehicleId': vehicleId,
      'username': username,
      'password': password,
      'useTLS': useTLS,
    };
  }

  factory MqttSettings.fromJson(Map<String, dynamic> json) {
    return MqttSettings(
      broker: json['broker'] as String,
      port: json['port'] as int,
      vehicleId: json['vehicleId'] as String,
      username: json['username'] as String?,
      password: json['password'] as String?,
      useTLS: json['useTLS'] as bool? ?? true,
    );
  }

  // Default settings
  factory MqttSettings.defaultSettings() {
    return const MqttSettings(
      broker: 'mqtt.eclipseprojects.io',
      port: 1883,
      vehicleId: 'vehicle_001',
      useTLS: false,
    );
  }
}

// ==================== Service Provider ====================

/// MQTT service provider (singleton)
final mqttServiceProvider = Provider<MqttService>((ref) {
  final service = MqttService();
  ref.onDispose(() => service.dispose());
  return service;
});

// ==================== Settings Providers ====================

/// SharedPreferences provider
final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) async {
  return await SharedPreferences.getInstance();
});

/// MQTT settings state provider
final mqttSettingsProvider = StateNotifierProvider<MqttSettingsNotifier, MqttSettings>((ref) {
  return MqttSettingsNotifier(ref);
});

/// Notifier for MQTT settings with persistence
class MqttSettingsNotifier extends StateNotifier<MqttSettings> {
  final Ref ref;

  MqttSettingsNotifier(this.ref) : super(MqttSettings.defaultSettings()) {
    _loadSettings();
  }

  /// Load settings from SharedPreferences
  /// Uses the same keys as the SettingsScreen for consistency
  Future<void> _loadSettings() async {
    try {
      final prefs = await ref.read(sharedPreferencesProvider.future);

      // Load individual settings using the same keys as SettingsScreen
      final broker = prefs.getString('mqtt_broker') ?? 'mqtt.eclipseprojects.io';
      final port = prefs.getInt('mqtt_port') ?? 1883;
      final vehicleId = prefs.getString('mqtt_vehicle_id') ?? 'vehicle_001';
      final username = prefs.getString('mqtt_username');
      final password = prefs.getString('mqtt_password');
      final useTLS = prefs.getBool('mqtt_use_tls') ?? false;

      state = MqttSettings(
        broker: broker,
        port: port,
        vehicleId: vehicleId,
        username: username?.isNotEmpty == true ? username : null,
        password: password?.isNotEmpty == true ? password : null,
        useTLS: useTLS,
      );
    } catch (e) {
      // Use default settings on error
      state = MqttSettings.defaultSettings();
    }
  }

  /// Save settings to SharedPreferences
  /// Uses the same keys as the SettingsScreen for consistency
  Future<void> saveSettings(MqttSettings settings) async {
    try {
      state = settings;
      final prefs = await ref.read(sharedPreferencesProvider.future);

      await prefs.setString('mqtt_broker', settings.broker);
      await prefs.setInt('mqtt_port', settings.port);
      await prefs.setString('mqtt_vehicle_id', settings.vehicleId);
      await prefs.setString('mqtt_username', settings.username ?? '');
      await prefs.setString('mqtt_password', settings.password ?? '');
      await prefs.setBool('mqtt_use_tls', settings.useTLS);
    } catch (e) {
      // Handle error
    }
  }

  /// Update individual setting fields
  void updateBroker(String broker) {
    state = state.copyWith(broker: broker);
  }

  void updatePort(int port) {
    state = state.copyWith(port: port);
  }

  void updateVehicleId(String vehicleId) {
    state = state.copyWith(vehicleId: vehicleId);
  }

  void updateUsername(String? username) {
    state = state.copyWith(username: username);
  }

  void updatePassword(String? password) {
    state = state.copyWith(password: password);
  }

  void updateUseTLS(bool useTLS) {
    state = state.copyWith(useTLS: useTLS);
  }
}

// ==================== Connection State Providers ====================

/// MQTT connection state stream provider
final mqttConnectionStateProvider = StreamProvider<MqttConnectionState>((ref) {
  final service = ref.watch(mqttServiceProvider);
  return service.connectionStateStream;
});

/// MQTT connection status provider (boolean for UI)
final mqttIsConnectedProvider = Provider<bool>((ref) {
  final service = ref.watch(mqttServiceProvider);
  return service.isConnected;
});

// ==================== Connection Control ====================

/// Provider for connecting to MQTT broker
final mqttConnectProvider = FutureProvider.autoDispose.family<bool, MqttSettings>(
  (ref, settings) async {
    final service = ref.watch(mqttServiceProvider);

    return await service.connect(
      broker: settings.broker,
      port: settings.port,
      vehicleId: settings.vehicleId,
      username: settings.username,
      password: settings.password,
      useTLS: settings.useTLS,
    );
  },
);

/// Provider for disconnecting from MQTT broker
final mqttDisconnectProvider = Provider<void Function()>((ref) {
  final service = ref.watch(mqttServiceProvider);
  return () => service.disconnect();
});
