import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers/mqtt_provider.dart';
import '../../services/tailscale_service.dart';
import '../../services/obd_proxy_service.dart';
import '../../services/obd_service.dart';
import '../obd_connection_screen.dart';

/// Connections settings sub-screen
/// Includes: MQTT, Tailscale, OBD Proxy, Data Sources
class ConnectionsSettingsScreen extends ConsumerStatefulWidget {
  const ConnectionsSettingsScreen({super.key});

  @override
  ConsumerState<ConnectionsSettingsScreen> createState() => _ConnectionsSettingsScreenState();
}

class _ConnectionsSettingsScreenState extends ConsumerState<ConnectionsSettingsScreen> {
  // MQTT Settings Controllers
  final _brokerController = TextEditingController();
  final _portController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _vehicleIdController = TextEditingController();
  bool _useTLS = true;
  bool _mqttEnabled = false;
  bool _haDiscoveryEnabled = false;
  int _mqttReconnectIntervalSeconds = 0;

  // Tailscale
  bool _tailscaleInstalled = false;
  bool _tailscaleAutoConnect = false;

  // OBD WiFi Proxy
  bool _proxyEnabled = false;
  String? _proxyClientAddress;
  int _proxyPort = 35000;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkTailscale();
    _restoreProxyState();
  }

  @override
  void dispose() {
    _brokerController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _vehicleIdController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _brokerController.text = prefs.getString('mqtt_broker') ?? '';
        _portController.text = (prefs.getInt('mqtt_port') ?? 8883).toString();
        _usernameController.text = prefs.getString('mqtt_username') ?? '';
        _passwordController.text = prefs.getString('mqtt_password') ?? '';
        _vehicleIdController.text = prefs.getString('mqtt_vehicle_id') ?? '';
        _useTLS = prefs.getBool('mqtt_use_tls') ?? true;
        _mqttEnabled = prefs.getBool('mqtt_enabled') ?? false;
        _haDiscoveryEnabled = prefs.getBool('ha_discovery_enabled') ?? false;
        _mqttReconnectIntervalSeconds = prefs.getInt('mqtt_reconnect_interval') ?? 0;
        _tailscaleAutoConnect = prefs.getBool('tailscale_auto_connect') ?? false;
      });
    } catch (e) {
      debugPrint('Failed to load settings: $e');
    }
  }

  Future<void> _checkTailscale() async {
    final installed = await TailscaleService.instance.isInstalled();
    if (mounted) {
      setState(() => _tailscaleInstalled = installed);
    }
  }

  void _restoreProxyState() {
    final proxy = OBDProxyService.instance;
    setState(() {
      _proxyEnabled = proxy.isRunning;
      _proxyClientAddress = proxy.clientAddress;
      _proxyPort = proxy.port;
    });
  }

  Future<void> _autoSaveString(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (e) {
      debugPrint('Failed to save $key: $e');
    }
  }

  Future<void> _autoSaveInt(String key, int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, value);
    } catch (e) {
      debugPrint('Failed to save $key: $e');
    }
  }

  Future<void> _autoSaveBool(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      debugPrint('Failed to save $key: $e');
    }
  }

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

      // Save settings first
      await _autoSaveString('mqtt_broker', _brokerController.text);
      await _autoSaveInt('mqtt_port', int.tryParse(_portController.text) ?? 8883);
      await _autoSaveString('mqtt_username', _usernameController.text);
      await _autoSaveString('mqtt_password', _passwordController.text);
      await _autoSaveString('mqtt_vehicle_id', _vehicleIdController.text);
      await _autoSaveBool('mqtt_use_tls', _useTLS);
      await _autoSaveInt('mqtt_reconnect_interval', _mqttReconnectIntervalSeconds);

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

  String _formatReconnectInterval(int seconds) {
    if (seconds == 0) return 'Disabled';
    if (seconds < 60) return '${seconds}s';
    return '${seconds ~/ 60}m ${seconds % 60}s';
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mqttState = ref.watch(mqttServiceProvider);
    final proxy = OBDProxyService.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // MQTT Configuration
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
                    onChanged: (value) {
                      setState(() => _mqttEnabled = value);
                      _autoSaveBool('mqtt_enabled', value);
                    },
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
                    onChanged: (value) => _autoSaveString('mqtt_broker', value),
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
                    onChanged: (value) => _autoSaveInt('mqtt_port', int.tryParse(value) ?? 1883),
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
                    onChanged: (value) => _autoSaveString('mqtt_vehicle_id', value),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username (optional)',
                      prefixIcon: Icon(Icons.person),
                    ),
                    enabled: _mqttEnabled,
                    onChanged: (value) => _autoSaveString('mqtt_username', value),
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
                    onChanged: (value) => _autoSaveString('mqtt_password', value),
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
                            _autoSaveBool('mqtt_use_tls', value);
                          }
                        : null,
                  ),
                  SwitchListTile(
                    title: const Text('Home Assistant Discovery'),
                    subtitle: const Text('Auto-configure entities in Home Assistant'),
                    value: _haDiscoveryEnabled,
                    onChanged: _mqttEnabled
                        ? (value) {
                            setState(() => _haDiscoveryEnabled = value);
                            _autoSaveBool('ha_discovery_enabled', value);
                          }
                        : null,
                    secondary: const Icon(Icons.home),
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('Auto-Reconnect Interval'),
                    subtitle: Text(_formatReconnectInterval(_mqttReconnectIntervalSeconds)),
                    enabled: _mqttEnabled,
                  ),
                  Slider(
                    value: _mqttReconnectIntervalSeconds.toDouble(),
                    min: 0,
                    max: 300,
                    divisions: 30,
                    label: _formatReconnectInterval(_mqttReconnectIntervalSeconds),
                    onChanged: _mqttEnabled
                        ? (value) => setState(() => _mqttReconnectIntervalSeconds = value.toInt())
                        : null,
                  ),
                  Text(
                    '0 = disabled, or 10-300 seconds',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _mqttEnabled ? _testMqttConnection : null,
                          icon: const Icon(Icons.wifi_tethering),
                          label: const Text('Test Connection'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: mqttState.isConnected ? Colors.green : Colors.grey,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          mqttState.isConnected ? 'Connected' : 'Disconnected',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
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
                      _tailscaleInstalled ? Icons.vpn_lock : Icons.vpn_lock_outlined,
                      color: _tailscaleInstalled ? Colors.blue : Colors.grey,
                    ),
                    title: Text(_tailscaleInstalled ? 'Tailscale Installed' : 'Tailscale Not Found'),
                    subtitle: Text(_tailscaleInstalled
                        ? 'VPN available for remote access'
                        : 'Install Tailscale for remote MQTT access'),
                  ),
                  if (_tailscaleInstalled) ...[
                    const Divider(),
                    SwitchListTile(
                      title: const Text('Auto-Connect on Startup'),
                      subtitle: const Text('Automatically connect to Tailscale when app starts'),
                      value: _tailscaleAutoConnect,
                      onChanged: (value) {
                        setState(() => _tailscaleAutoConnect = value);
                        _autoSaveBool('tailscale_auto_connect', value);
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => TailscaleService.instance.connect(),
                            icon: const Icon(Icons.link),
                            label: const Text('Connect'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => TailscaleService.instance.openApp(),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Open App'),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Text(
                      'Install Tailscale from the Play Store to enable VPN features.',
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

          // Data Sources Section
          _buildSectionHeader('Data Sources'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: const Icon(Icons.bluetooth, color: Colors.blue),
                    title: const Text('OBD-II Bluetooth'),
                    subtitle: const Text('Connect to ELM327 adapter'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => OBDConnectionScreen(obdService: OBDService())),
                    ),
                  ),
                ],
              ),
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
                  SwitchListTile(
                    title: const Text('Enable WiFi Proxy Server'),
                    subtitle: Text(_proxyEnabled
                        ? 'Listening on port $_proxyPort'
                        : 'Allow other apps to access OBD data'),
                    value: _proxyEnabled,
                    onChanged: (value) async {
                      if (value) {
                        await proxy.start();
                      } else {
                        await proxy.stop();
                      }
                      setState(() {
                        _proxyEnabled = proxy.isRunning;
                        _proxyClientAddress = proxy.clientAddress;
                      });
                    },
                  ),
                  if (_proxyEnabled) ...[
                    const Divider(),
                    ListTile(
                      leading: Icon(
                        _proxyClientAddress != null ? Icons.link : Icons.link_off,
                        color: _proxyClientAddress != null ? Colors.green : Colors.grey,
                      ),
                      title: Text(_proxyClientAddress != null
                          ? 'Client Connected'
                          : 'Waiting for connection...'),
                      subtitle: Text(_proxyClientAddress ?? 'Port $_proxyPort'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'Other apps can connect to this proxy to receive OBD data. '
                    'Useful for apps that need direct ELM327 access.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
