import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../providers/mqtt_provider.dart';
import '../providers/vehicle_data_provider.dart';
import '../services/database_service.dart';
import '../services/data_usage_service.dart';
import '../services/background_service.dart';
import '../services/tailscale_service.dart';
import '../services/obd_proxy_service.dart';
import 'debug_log_screen.dart';
import 'obd_connection_screen.dart';
import 'obd_pid_config_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings screen for app configuration
/// Allows users to configure MQTT, alerts, and other app settings
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // MQTT Settings Controllers
  final _brokerController = TextEditingController();
  final _portController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _vehicleIdController = TextEditingController();
  bool _useTLS = true;
  bool _mqttEnabled = false;
  bool _haDiscoveryEnabled = false;

  // ABRP Settings Controllers
  final _abrpTokenController = TextEditingController();
  final _abrpCarModelController = TextEditingController();
  bool _abrpEnabled = false;
  int _abrpIntervalSeconds = 60; // Default 1 minute

  // Alert Threshold Controllers
  double _lowBatteryThreshold = 20.0;
  double _criticalBatteryThreshold = 10.0;
  double _highTempThreshold = 45.0;

  // Data Retention
  int _dataRetentionDays = 30;

  // Update Frequency (in seconds)
  int _updateFrequencySeconds = 2;

  // App Behavior
  bool _startMinimised = false;
  bool _backgroundServiceEnabled = false;

  // Version Info
  String _version = '';
  String _buildNumber = '';
  String _buildDate = '';

  // Tailscale
  bool _tailscaleInstalled = false;
  bool _tailscaleAutoConnect = false;

  // Background service availability
  bool _backgroundServiceAvailable = false;

  // OBD WiFi Proxy (uses singleton)
  bool _proxyEnabled = false;
  String? _proxyClientAddress;
  int _proxyPort = 35000;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadVersionInfo();
    _checkTailscale();
    _checkBackgroundService();
    _restoreProxyState();
  }

  /// Restore proxy state from singleton (in case we navigated away and back)
  void _restoreProxyState() {
    final proxyService = OBDProxyService.instance;
    if (proxyService.isRunning) {
      setState(() {
        _proxyEnabled = true;
        _proxyClientAddress = proxyService.clientAddress;
      });

      // Re-register the status callback
      final dataSourceManager = ref.read(dataSourceManagerProvider);
      proxyService.onStatusChanged = (isRunning, clientAddress) {
        if (mounted) {
          setState(() {
            _proxyEnabled = isRunning;
            _proxyClientAddress = clientAddress;
          });

          // Pause/resume OBD polling based on client connection
          if (clientAddress != null) {
            dataSourceManager.obdService.pausePolling();
          } else if (isRunning) {
            dataSourceManager.obdService.resumePolling();
          }
        }
      };
    }
  }

  Future<void> _checkBackgroundService() async {
    // Check if background service is available on this device
    final available = BackgroundServiceManager.instance.isAvailable;
    if (mounted) {
      setState(() {
        _backgroundServiceAvailable = available;
      });
    }
  }

  Future<void> _checkTailscale() async {
    final installed = await TailscaleService.instance.isInstalled();
    if (mounted) {
      setState(() {
        _tailscaleInstalled = installed;
      });
    }
  }

  Future<void> _loadVersionInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _version = packageInfo.version;
      _buildNumber = packageInfo.buildNumber;
      // Build date - update this when releasing new builds
      _buildDate = '2026-01-07';
    });
  }

  @override
  void dispose() {
    _brokerController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _vehicleIdController.dispose();
    _abrpTokenController.dispose();
    _abrpCarModelController.dispose();
    // Note: Don't dispose proxy service here - let it run in background
    super.dispose();
  }

  /// Load settings from SharedPreferences with file fallback
  Future<void> _loadSettings() async {
    // Try SharedPreferences first
    bool loadedFromPrefs = false;
    try {
      final prefs = await SharedPreferences.getInstance();

      setState(() {
        // MQTT Settings
        _brokerController.text = prefs.getString('mqtt_broker') ?? 'mqtt.eclipseprojects.io';
        _portController.text = prefs.getInt('mqtt_port')?.toString() ?? '1883';
        _usernameController.text = prefs.getString('mqtt_username') ?? '';
        _passwordController.text = prefs.getString('mqtt_password') ?? '';
        _vehicleIdController.text = prefs.getString('mqtt_vehicle_id') ?? 'TEST_VEHICLE_001';
        _useTLS = prefs.getBool('mqtt_use_tls') ?? false;
        _mqttEnabled = prefs.getBool('mqtt_enabled') ?? false;
        _haDiscoveryEnabled = prefs.getBool('ha_discovery_enabled') ?? false;

        // Alert Thresholds
        _lowBatteryThreshold = prefs.getDouble('alert_low_battery') ?? 20.0;
        _criticalBatteryThreshold = prefs.getDouble('alert_critical_battery') ?? 10.0;
        _highTempThreshold = prefs.getDouble('alert_high_temp') ?? 45.0;

        // Data Retention
        _dataRetentionDays = prefs.getInt('data_retention_days') ?? 30;

        // Update Frequency
        _updateFrequencySeconds = prefs.getInt('update_frequency_seconds') ?? 2;

        // App Behavior
        _startMinimised = prefs.getBool('start_minimised') ?? false;
        _backgroundServiceEnabled = prefs.getBool('background_service_enabled') ?? false;

        // ABRP Settings
        _abrpTokenController.text = prefs.getString('abrp_token') ?? '';
        _abrpCarModelController.text = prefs.getString('abrp_car_model') ?? 'xpeng:g6:23:87:other';
        _abrpEnabled = prefs.getBool('abrp_enabled') ?? false;
        _abrpIntervalSeconds = prefs.getInt('abrp_interval_seconds') ?? 60;

        // Tailscale Settings
        _tailscaleAutoConnect = prefs.getBool('tailscale_auto_connect') ?? false;
      });
      loadedFromPrefs = true;
    } catch (e) {
      print('SharedPreferences load failed: $e');
    }

    // If SharedPreferences failed or returned defaults, try file fallback
    if (!loadedFromPrefs || _brokerController.text == 'mqtt.eclipseprojects.io') {
      await _loadSettingsFromFile();
    }

    // Configure ABRP service with loaded settings
    try {
      final dataSourceManager = ref.read(dataSourceManagerProvider);
      dataSourceManager.abrpService.configure(
        token: _abrpTokenController.text,
        carModel: _abrpCarModelController.text,
        enabled: _abrpEnabled,
      );
    } catch (e) {
      // Data source manager not available yet, skip
    }
  }

  /// Load settings from file (fallback)
  Future<void> _loadSettingsFromFile() async {
    try {
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/app_settings.json';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/app_settings.json';
      }

      final file = File(filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> settings = jsonDecode(content);

        setState(() {
          _brokerController.text = settings['mqtt_broker'] ?? _brokerController.text;
          _portController.text = (settings['mqtt_port'] ?? 1883).toString();
          _usernameController.text = settings['mqtt_username'] ?? '';
          _passwordController.text = settings['mqtt_password'] ?? '';
          _vehicleIdController.text = settings['mqtt_vehicle_id'] ?? 'TEST_VEHICLE_001';
          _useTLS = settings['mqtt_use_tls'] ?? false;
          _mqttEnabled = settings['mqtt_enabled'] ?? false;
          _haDiscoveryEnabled = settings['ha_discovery_enabled'] ?? false;
          _lowBatteryThreshold = (settings['alert_low_battery'] ?? 20.0).toDouble();
          _criticalBatteryThreshold = (settings['alert_critical_battery'] ?? 10.0).toDouble();
          _highTempThreshold = (settings['alert_high_temp'] ?? 45.0).toDouble();
          _dataRetentionDays = settings['data_retention_days'] ?? 30;
          _updateFrequencySeconds = settings['update_frequency_seconds'] ?? 2;
          _startMinimised = settings['start_minimised'] ?? false;
          _backgroundServiceEnabled = settings['background_service_enabled'] ?? false;

          // ABRP Settings
          _abrpTokenController.text = settings['abrp_token'] ?? '';
          _abrpCarModelController.text = settings['abrp_car_model'] ?? 'xpeng:g6:23:87:other';
          _abrpEnabled = settings['abrp_enabled'] ?? false;
          _abrpIntervalSeconds = settings['abrp_interval_seconds'] ?? 60;

          // Tailscale Settings
          _tailscaleAutoConnect = settings['tailscale_auto_connect'] ?? false;
        });
        print('Settings loaded from file: $filePath');
      }
    } catch (e) {
      print('File-based settings load failed: $e');
    }
  }

  /// Save settings to file (primary) and SharedPreferences (backup)
  Future<void> _saveSettings() async {
    bool savedToFile = false;
    bool savedToPrefs = false;

    // Always save to file first (most reliable)
    savedToFile = await _saveSettingsToFile();

    // Also try SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();

      // MQTT Settings
      await prefs.setString('mqtt_broker', _brokerController.text);
      await prefs.setInt('mqtt_port', int.tryParse(_portController.text) ?? 1883);
      await prefs.setString('mqtt_username', _usernameController.text);
      await prefs.setString('mqtt_password', _passwordController.text);
      await prefs.setString('mqtt_vehicle_id', _vehicleIdController.text);
      await prefs.setBool('mqtt_use_tls', _useTLS);
      await prefs.setBool('mqtt_enabled', _mqttEnabled);
      await prefs.setBool('ha_discovery_enabled', _haDiscoveryEnabled);

      // Alert Thresholds
      await prefs.setDouble('alert_low_battery', _lowBatteryThreshold);
      await prefs.setDouble('alert_critical_battery', _criticalBatteryThreshold);
      await prefs.setDouble('alert_high_temp', _highTempThreshold);

      // Data Retention
      await prefs.setInt('data_retention_days', _dataRetentionDays);

      // Update Frequency
      await prefs.setInt('update_frequency_seconds', _updateFrequencySeconds);

      // App Behavior
      await prefs.setBool('start_minimised', _startMinimised);
      await prefs.setBool('background_service_enabled', _backgroundServiceEnabled);

      // ABRP Settings
      await prefs.setString('abrp_token', _abrpTokenController.text);
      await prefs.setString('abrp_car_model', _abrpCarModelController.text);
      await prefs.setBool('abrp_enabled', _abrpEnabled);
      await prefs.setInt('abrp_interval_seconds', _abrpIntervalSeconds);

      // Tailscale Settings
      await prefs.setBool('tailscale_auto_connect', _tailscaleAutoConnect);

      savedToPrefs = true;
    } catch (e) {
      print('SharedPreferences save failed (file save used): $e');
    }

    // Apply update frequency immediately
    try {
      final dataSourceManager = ref.read(dataSourceManagerProvider);
      await dataSourceManager.updateFrequency(_updateFrequencySeconds);

      // Configure ABRP service
      dataSourceManager.abrpService.configure(
        token: _abrpTokenController.text,
        carModel: _abrpCarModelController.text,
        enabled: _abrpEnabled,
      );
      // Apply ABRP interval
      dataSourceManager.abrpService.setUpdateInterval(_abrpIntervalSeconds);
    } catch (e) {
      // Data source manager not available, skip
    }

    // Apply Home Assistant discovery setting to MQTT service
    try {
      final mqttService = ref.read(mqttServiceProvider);
      mqttService.haDiscoveryEnabled = _haDiscoveryEnabled;
    } catch (e) {
      // MQTT service not available, skip
    }

    if (mounted) {
      if (savedToFile || savedToPrefs) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved successfully')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save settings'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Save settings to file
  Future<bool> _saveSettingsToFile() async {
    try {
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/app_settings.json';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/app_settings.json';
      }

      final settings = {
        'mqtt_broker': _brokerController.text,
        'mqtt_port': int.tryParse(_portController.text) ?? 1883,
        'mqtt_username': _usernameController.text,
        'mqtt_password': _passwordController.text,
        'mqtt_vehicle_id': _vehicleIdController.text,
        'mqtt_use_tls': _useTLS,
        'mqtt_enabled': _mqttEnabled,
        'ha_discovery_enabled': _haDiscoveryEnabled,
        'alert_low_battery': _lowBatteryThreshold,
        'alert_critical_battery': _criticalBatteryThreshold,
        'alert_high_temp': _highTempThreshold,
        'data_retention_days': _dataRetentionDays,
        'update_frequency_seconds': _updateFrequencySeconds,
        'start_minimised': _startMinimised,
        'background_service_enabled': _backgroundServiceEnabled,
        'abrp_token': _abrpTokenController.text,
        'abrp_car_model': _abrpCarModelController.text,
        'abrp_enabled': _abrpEnabled,
        'abrp_interval_seconds': _abrpIntervalSeconds,
        'tailscale_auto_connect': _tailscaleAutoConnect,
      };

      final file = File(filePath);
      await file.writeAsString(jsonEncode(settings));
      print('Settings saved to file: $filePath');
      return true;
    } catch (e) {
      print('File-based settings save failed: $e');
      return false;
    }
  }

  /// Test MQTT connection
  Future<void> _testMqttConnection() async {
    try {
      final mqttService = ref.read(mqttServiceProvider);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      await mqttService.connect(
        broker: _brokerController.text,
        port: int.tryParse(_portController.text) ?? 1883,
        vehicleId: _vehicleIdController.text,
        username: _usernameController.text.isNotEmpty ? _usernameController.text : null,
        password: _passwordController.text.isNotEmpty ? _passwordController.text : null,
        useTLS: _useTLS,
      );

      if (mounted) {
        Navigator.pop(context); // Close loading dialog

        if (mqttService.isConnected) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('MQTT connection successful!'),
              backgroundColor: Colors.green,
            ),
          );
          mqttService.disconnect();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('MQTT connection failed'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Control Tailscale VPN (connect or disconnect)
  Future<void> _controlTailscale({required bool connect}) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      bool success;
      String action;

      if (connect) {
        success = await TailscaleService.instance.connect();
        action = 'connect';
      } else {
        success = await TailscaleService.instance.disconnect();
        action = 'disconnect';
      }

      if (mounted) {
        if (success) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text('Tailscale $action intent sent'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text('Failed to $action Tailscale'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Open Tailscale app
  Future<void> _openTailscaleApp() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      final success = await TailscaleService.instance.openApp();

      if (!success && mounted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text('Failed to open Tailscale app'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Start OBD WiFi Proxy
  Future<void> _startProxy() async {
    final dataSourceManager = ref.read(dataSourceManagerProvider);
    final proxyService = OBDProxyService.instance;

    proxyService.onStatusChanged = (isRunning, clientAddress) {
      if (mounted) {
        setState(() {
          _proxyEnabled = isRunning;
          _proxyClientAddress = clientAddress;
        });

        // Pause/resume OBD polling based on client connection
        if (clientAddress != null) {
          // Client connected - pause polling to avoid collisions
          dataSourceManager.obdService.pausePolling();
        } else if (isRunning) {
          // Client disconnected but proxy still running - resume polling
          dataSourceManager.obdService.resumePolling();
        }
      }
    };

    final success = await proxyService.start(port: _proxyPort);

    if (mounted) {
      setState(() {
        _proxyEnabled = success;
      });

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('OBD Proxy started on port $_proxyPort'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to start OBD Proxy'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Stop OBD WiFi Proxy
  Future<void> _stopProxy() async {
    await OBDProxyService.instance.stop();

    // Resume OBD polling when proxy is stopped
    final dataSourceManager = ref.read(dataSourceManagerProvider);
    dataSourceManager.obdService.resumePolling();

    if (mounted) {
      setState(() {
        _proxyEnabled = false;
        _proxyClientAddress = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('OBD Proxy stopped')),
      );
    }
  }

  /// Clear all data from database
  Future<void> _clearAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Data'),
        content: const Text(
          'Are you sure you want to delete all vehicle data and alerts? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final db = await DatabaseService.instance.database;
        await db.delete('vehicle_data');
        await db.delete('alerts');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('All data cleared successfully')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error clearing data: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveSettings,
            tooltip: 'Save Settings',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // MQTT Settings Section
          _buildSectionHeader('MQTT Configuration'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                  title: const Text('Enable MQTT Publishing'),
                  subtitle: const Text('Send vehicle data to remote broker'),
                  value: _mqttEnabled,
                  onChanged: (value) => setState(() => _mqttEnabled = value),
                ),
                const Divider(),
                TextField(
                  controller: _brokerController,
                  decoration: const InputDecoration(
                    labelText: 'Broker Address',
                    hintText: 'mqtt.eclipseprojects.io',
                    prefixIcon: Icon(Icons.cloud),
                  ),
                  enabled: _mqttEnabled,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _portController,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    hintText: '1883',
                    prefixIcon: Icon(Icons.settings_ethernet),
                  ),
                  keyboardType: TextInputType.number,
                  enabled: _mqttEnabled,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _vehicleIdController,
                  decoration: const InputDecoration(
                    labelText: 'Vehicle ID',
                    hintText: 'MY_VEHICLE_001',
                    prefixIcon: Icon(Icons.directions_car),
                  ),
                  enabled: _mqttEnabled,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username (optional)',
                    prefixIcon: Icon(Icons.person),
                  ),
                  enabled: _mqttEnabled,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'Password (optional)',
                    prefixIcon: Icon(Icons.lock),
                  ),
                  obscureText: true,
                  enabled: _mqttEnabled,
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text('Use TLS/SSL'),
                  subtitle: const Text('Secure connection (port 8883)'),
                  value: _useTLS,
                  onChanged: _mqttEnabled
                      ? (value) {
                          setState(() {
                            _useTLS = value;
                            _portController.text = value ? '8883' : '1883';
                          });
                        }
                      : null,
                ),
                SwitchListTile(
                  title: const Text('Home Assistant Discovery'),
                  subtitle: const Text('Auto-configure entities in Home Assistant'),
                  value: _haDiscoveryEnabled,
                  onChanged: _mqttEnabled
                      ? (value) => setState(() => _haDiscoveryEnabled = value)
                      : null,
                  secondary: const Icon(Icons.home),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _mqttEnabled ? _testMqttConnection : null,
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('Test Connection'),
                ),
              ],
            ),
          ),),
          const SizedBox(height: 24),

          // Tailscale VPN Section
          _buildSectionHeader('Tailscale VPN'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.vpn_key,
                      color: _tailscaleInstalled ? Colors.green : Colors.grey,
                    ),
                    title: const Text('Tailscale'),
                    subtitle: Text(
                      _tailscaleInstalled
                          ? 'Installed - Use buttons below to control VPN'
                          : 'Not detected - Install Tailscale for VPN control',
                    ),
                  ),
                  if (_tailscaleInstalled) ...[
                    const Divider(),
                    Text(
                      'Control Tailscale VPN connection for MQTT access to your home network.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _controlTailscale(connect: true),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Connect'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _controlTailscale(connect: false),
                            icon: const Icon(Icons.stop),
                            label: const Text('Disconnect'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _openTailscaleApp,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open Tailscale App'),
                    ),
                    const Divider(),
                    SwitchListTile(
                      title: const Text('Auto-connect on App Start'),
                      subtitle: const Text('Automatically connect Tailscale when app launches'),
                      value: _tailscaleAutoConnect,
                      onChanged: (value) => setState(() => _tailscaleAutoConnect = value),
                      secondary: const Icon(Icons.autorenew),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Note: Tailscale must be running in background for intents to work reliably.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ] else ...[
                    const Divider(),
                    Text(
                      'Install Tailscale from Google Play Store to enable VPN control from this app.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ABRP Settings Section
          _buildSectionHeader('A Better Route Planner (ABRP)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    title: const Text('Enable ABRP Telemetry'),
                    subtitle: const Text('Send data to ABRP for range prediction'),
                    value: _abrpEnabled,
                    onChanged: (value) => setState(() => _abrpEnabled = value),
                  ),
                  const Divider(),
                  TextField(
                    controller: _abrpTokenController,
                    decoration: const InputDecoration(
                      labelText: 'ABRP User Token',
                      hintText: 'Enter your ABRP generic token',
                      prefixIcon: Icon(Icons.key),
                      helperText: 'Get from ABRP app: Settings > Car > Link',
                    ),
                    enabled: _abrpEnabled,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _abrpCarModelController,
                    decoration: const InputDecoration(
                      labelText: 'Car Model (optional)',
                      hintText: 'xpeng:g6:23:87:other',
                      prefixIcon: Icon(Icons.directions_car),
                      helperText: 'ABRP car model identifier',
                    ),
                    enabled: _abrpEnabled,
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: const Icon(Icons.timer),
                    title: const Text('Update Interval'),
                    subtitle: Text(_formatAbrpInterval(_abrpIntervalSeconds)),
                    enabled: _abrpEnabled,
                  ),
                  Slider(
                    value: _abrpIntervalSeconds.toDouble(),
                    min: 5,
                    max: 300,
                    divisions: 59,
                    label: _formatAbrpInterval(_abrpIntervalSeconds),
                    onChanged: _abrpEnabled
                        ? (value) => setState(() => _abrpIntervalSeconds = value.toInt())
                        : null,
                  ),
                  Text(
                    'Min 5 sec (ABRP rate limit), Max 5 min',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'ABRP uses your telemetry data to provide accurate range predictions and optimal charging stops.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Alert Thresholds Section
          _buildSectionHeader('Alert Thresholds'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                _buildThresholdSlider(
                  'Low Battery Warning',
                  _lowBatteryThreshold,
                  0,
                  50,
                  '%',
                  (value) => setState(() => _lowBatteryThreshold = value),
                ),
                const Divider(),
                _buildThresholdSlider(
                  'Critical Battery Alert',
                  _criticalBatteryThreshold,
                  0,
                  30,
                  '%',
                  (value) => setState(() => _criticalBatteryThreshold = value),
                ),
                const Divider(),
                _buildThresholdSlider(
                  'High Temperature Alert',
                  _highTempThreshold,
                  30,
                  70,
                  '°C',
                  (value) => setState(() => _highTempThreshold = value),
                ),
              ],
            ),
          ),),
          const SizedBox(height: 24),

          // Data Management Section
          _buildSectionHeader('Data Management'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                ListTile(
                  leading: const Icon(Icons.timer),
                  title: const Text('Data Retention Period'),
                  subtitle: Text('$_dataRetentionDays days'),
                ),
                Slider(
                  value: _dataRetentionDays.toDouble(),
                  min: 7,
                  max: 365,
                  divisions: 51,
                  label: '$_dataRetentionDays days',
                  onChanged: (value) => setState(() => _dataRetentionDays = value.toInt()),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.delete_forever, color: Colors.red),
                  title: const Text('Clear All Data'),
                  subtitle: const Text('Delete all vehicle data and alerts'),
                  onTap: _clearAllData,
                ),
              ],
            ),
          ),),
          const SizedBox(height: 24),

          // App Behavior Section
          _buildSectionHeader('App Behavior'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.speed),
                    title: const Text('Update Frequency'),
                    subtitle: Text(_formatUpdateFrequency(_updateFrequencySeconds)),
                  ),
                  Slider(
                    value: _updateFrequencySeconds.toDouble(),
                    min: 1,
                    max: 600, // 10 minutes
                    divisions: _getUpdateFrequencyDivisions(),
                    label: _formatUpdateFrequency(_updateFrequencySeconds),
                    onChanged: (value) => setState(() => _updateFrequencySeconds = value.toInt()),
                  ),
                  const Divider(),
                  SwitchListTile(
                    title: const Text('Start Minimised'),
                    subtitle: const Text('App starts in background/notification'),
                    value: _startMinimised,
                    onChanged: (value) => setState(() => _startMinimised = value),
                    secondary: const Icon(Icons.minimize),
                  ),
                  const Divider(),
                  SwitchListTile(
                    title: const Text('Run in Background'),
                    subtitle: Text(_backgroundServiceAvailable
                        ? 'Keep collecting data when app is minimised'
                        : 'Not available on this device'),
                    value: _backgroundServiceEnabled && _backgroundServiceAvailable,
                    onChanged: !_backgroundServiceAvailable ? null : (value) async {
                      final scaffoldMessenger = ScaffoldMessenger.of(context);
                      try {
                        if (value) {
                          // Request notification permission (Android 13+)
                          try {
                            if (await Permission.notification.isDenied) {
                              final status = await Permission.notification.request();
                              if (status.isPermanentlyDenied) {
                                if (mounted) {
                                  _showPermissionSettingsDialog('Notification');
                                }
                                return;
                              }
                            }
                          } catch (e) {
                            debugPrint('Notification permission error: $e');
                            // Continue anyway - permission may already be granted
                          }

                          // Request battery optimization exemption (recommended for background service)
                          try {
                            if (!await Permission.ignoreBatteryOptimizations.isGranted) {
                              await Permission.ignoreBatteryOptimizations.request();
                              // Don't block on this - just inform user if needed
                            }
                          } catch (e) {
                            debugPrint('Battery optimization permission error: $e');
                            // Continue anyway - this is optional
                          }
                        }

                        setState(() => _backgroundServiceEnabled = value);

                        try {
                          if (value) {
                            await BackgroundServiceManager.instance.start();
                          } else {
                            await BackgroundServiceManager.instance.stop();
                          }
                        } catch (e) {
                          debugPrint('Background service error: $e');
                          // Revert the toggle if service fails to start/stop
                          if (mounted) {
                            setState(() => _backgroundServiceEnabled = !value);
                            scaffoldMessenger.showSnackBar(
                              SnackBar(
                                content: Text('Background service error: ${e.toString()}'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      } catch (e) {
                        debugPrint('Background toggle error: $e');
                        if (mounted) {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text('Error: ${e.toString()}'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
                    secondary: const Icon(Icons.sync),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Data Sources Section
          _buildSectionHeader('Data Sources'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: const Text('OBD-II Bluetooth Adapter'),
                  subtitle: ref.watch(dataSourceManagerProvider).isObdConnected
                      ? const Text('Connected', style: TextStyle(color: Colors.green))
                      : const Text('Not connected'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final dataSourceManager = ref.read(dataSourceManagerProvider);
                    final result = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (context) => OBDConnectionScreen(
                          obdService: dataSourceManager.obdService,
                        ),
                      ),
                    );

                    // If OBD connection successful, reinitialize data source
                    if (result == true && mounted) {
                      await dataSourceManager.initialize();
                      setState(() {});
                    }
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.settings_input_component),
                  title: const Text('Configure OBD-II PIDs'),
                  subtitle: const Text('Customize data parameters'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const OBDPIDConfigScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // OBD WiFi Proxy Section
          _buildSectionHeader('OBD WiFi Proxy'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.wifi_tethering,
                      color: _proxyEnabled ? Colors.green : Colors.grey,
                    ),
                    title: const Text('WiFi-to-Bluetooth Bridge'),
                    subtitle: Text(
                      _proxyEnabled
                          ? (_proxyClientAddress != null
                              ? 'Client connected: $_proxyClientAddress'
                              : 'Running on port $_proxyPort')
                          : 'Allow OBD scanner apps to connect via WiFi',
                    ),
                  ),
                  const Divider(),
                  Text(
                    'When enabled, OBD scanner apps can connect to this device via WiFi '
                    'and communicate with your Bluetooth OBD adapter through XPCarData.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!ref.watch(dataSourceManagerProvider).isObdConnected) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.withOpacity(0.3)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.warning, color: Colors.orange, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Connect to Bluetooth OBD adapter first',
                              style: TextStyle(color: Colors.orange),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: ref.watch(dataSourceManagerProvider).isObdConnected
                              ? (_proxyEnabled ? _stopProxy : _startProxy)
                              : null,
                          icon: Icon(_proxyEnabled ? Icons.stop : Icons.play_arrow),
                          label: Text(_proxyEnabled ? 'Stop Proxy' : 'Start Proxy'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _proxyEnabled ? Colors.red : Colors.green,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_proxyEnabled) ...[
                    const SizedBox(height: 16),
                    FutureBuilder<String>(
                      future: OBDProxyService.instance.getConnectionInfo(),
                      builder: (context, snapshot) {
                        if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.green.withOpacity(0.3)),
                            ),
                            child: Text(
                              snapshot.data!,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Data Usage Section
          _buildSectionHeader('Data Usage'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: StreamBuilder<DataUsageStats>(
                stream: DataUsageService.instance.usageStream,
                builder: (context, snapshot) {
                  final sessionStats = DataUsageService.instance.sessionStats;
                  final totalStats = DataUsageService.instance.totalStats;

                  return Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.access_time),
                        title: const Text('Current Session'),
                        subtitle: Text(
                          'Duration: ${DataUsageStats.formatDuration(sessionStats.sessionDuration)}',
                        ),
                      ),
                      const Divider(),
                      Row(
                        children: [
                          Expanded(
                            child: _buildDataUsageItem(
                              'MQTT',
                              sessionStats.mqttBytesSent,
                              sessionStats.mqttRequestCount,
                              Icons.cloud_upload,
                            ),
                          ),
                          Expanded(
                            child: _buildDataUsageItem(
                              'ABRP',
                              sessionStats.abrpBytesSent,
                              sessionStats.abrpRequestCount,
                              Icons.route,
                            ),
                          ),
                        ],
                      ),
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.data_usage),
                        title: const Text('Session Total'),
                        subtitle: Text(
                          '${DataUsageStats.formatBytes(sessionStats.totalBytesSent)} sent (${sessionStats.totalRequestCount} requests)',
                        ),
                      ),
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.history),
                        title: const Text('All-Time Total'),
                        subtitle: Text(
                          '${DataUsageStats.formatBytes(totalStats.totalBytesSent)} sent (${totalStats.totalRequestCount} requests)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          TextButton.icon(
                            onPressed: () {
                              DataUsageService.instance.resetSession();
                              setState(() {});
                            },
                            icon: const Icon(Icons.refresh),
                            label: const Text('Reset Session'),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Reset All Data Usage'),
                                  content: const Text('This will reset all data usage statistics. Continue?'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: const Text('Reset'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                await DataUsageService.instance.resetAll();
                                setState(() {});
                              }
                            },
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Reset All'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Debug Section
          _buildSectionHeader('Debug'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.bug_report),
              title: const Text('View Debug Logs'),
              subtitle: const Text('See diagnostic information'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const DebugLogScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // About Section
          _buildSectionHeader('About'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                ListTile(
                  leading: const Icon(Icons.info),
                  title: const Text('XPCarData'),
                  subtitle: Text(
                    'by Steve Lea\n'
                    'Version $_version (Build $_buildNumber)\n'
                    'Built: $_buildDate\n'
                    'Battery Monitor for XPENG Vehicles',
                  ),
                ),
                const Divider(),
                const ListTile(
                  leading: Icon(Icons.description),
                  title: Text('Data Sources'),
                  subtitle: Text('CarInfo API • OBD-II • MQTT • ABRP'),
                ),
              ],
            ),
          ),),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _buildThresholdSlider(
    String label,
    double value,
    double min,
    double max,
    String unit,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(label),
          trailing: Text(
            '${value.toStringAsFixed(0)}$unit',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: ((max - min) / 5).toInt(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildDataUsageItem(String label, int bytes, int requests, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          DataUsageStats.formatBytes(bytes),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          '$requests requests',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// Format update frequency for display
  String _formatUpdateFrequency(int seconds) {
    if (seconds < 60) {
      return '$seconds second${seconds == 1 ? '' : 's'}';
    } else {
      final minutes = (seconds / 60).round();
      return '$minutes minute${minutes == 1 ? '' : 's'}';
    }
  }

  /// Format ABRP interval for display
  String _formatAbrpInterval(int seconds) {
    if (seconds < 60) {
      return '$seconds sec';
    }
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    if (secs == 0) {
      return '$mins min';
    }
    return '$mins min $secs sec';
  }

  /// Show dialog to direct user to app settings for permission
  void _showPermissionSettingsDialog(String permissionName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$permissionName Permission Required'),
        content: Text(
          '$permissionName permission is required for background service to work properly. '
          'Please enable it in app settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  /// Get number of divisions for update frequency slider
  /// This provides better granularity at lower values
  int _getUpdateFrequencyDivisions() {
    // 1-10s: every second (10 divisions)
    // 10-60s: every 5 seconds (10 divisions)
    // 1-10m: every 30 seconds (18 divisions)
    // Total: ~38 divisions
    return 99;
  }
}
