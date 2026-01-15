import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/fleet_analytics_service.dart';
import '../../services/hive_storage_service.dart';
import '../../services/healthcheck_service.dart';
import '../fleet_stats_screen.dart';

/// Integrations settings sub-screen
/// Includes: ABRP, Fleet Statistics
class IntegrationsSettingsScreen extends ConsumerStatefulWidget {
  const IntegrationsSettingsScreen({super.key});

  @override
  ConsumerState<IntegrationsSettingsScreen> createState() => _IntegrationsSettingsScreenState();
}

class _IntegrationsSettingsScreenState extends ConsumerState<IntegrationsSettingsScreen> {
  // ABRP Settings
  final _abrpTokenController = TextEditingController();
  final _abrpCarModelController = TextEditingController();
  bool _abrpEnabled = false;
  int _abrpIntervalSeconds = 60;

  // Fleet Analytics
  bool _fleetAnalyticsEnabled = false;
  String _vehicleModel = '24LR';

  // Healthcheck Settings
  final _healthcheckUrlController = TextEditingController();
  bool _healthcheckEnabled = false;
  int _healthcheckIntervalSeconds = 60;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _abrpTokenController.dispose();
    _abrpCarModelController.dispose();
    _healthcheckUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final hive = HiveStorageService.instance;

    // Try Hive first (works on AI boxes)
    if (hive.isAvailable) {
      setState(() {
        _abrpTokenController.text = hive.getSetting<String>('abrp_token') ?? '';
        _abrpCarModelController.text = hive.getSetting<String>('abrp_car_model') ?? '';
        _abrpEnabled = hive.getSetting<bool>('abrp_enabled') ?? false;
        _abrpIntervalSeconds = hive.getSetting<int>('abrp_interval_seconds') ?? 60;
        _vehicleModel = hive.getSetting<String>('vehicle_model') ?? '24LR';
      });
      debugPrint('[Integrations] Loaded settings from Hive');
    } else {
      // Fallback to SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        setState(() {
          _abrpTokenController.text = prefs.getString('abrp_token') ?? '';
          _abrpCarModelController.text = prefs.getString('abrp_car_model') ?? '';
          _abrpEnabled = prefs.getBool('abrp_enabled') ?? false;
          _abrpIntervalSeconds = prefs.getInt('abrp_interval_seconds') ?? 60;
          _vehicleModel = prefs.getString('vehicle_model') ?? '24LR';
        });
        debugPrint('[Integrations] Loaded settings from SharedPreferences');
      } catch (e) {
        debugPrint('[Integrations] Failed to load settings: $e');
      }
    }

    // Load fleet analytics state (has its own Hive-based storage)
    _fleetAnalyticsEnabled = FleetAnalyticsService.instance.isEnabled;

    // Load healthcheck settings
    final healthcheck = HealthcheckService.instance;
    setState(() {
      _healthcheckEnabled = healthcheck.isEnabled;
      _healthcheckUrlController.text = healthcheck.pingUrl ?? '';
      _healthcheckIntervalSeconds = healthcheck.intervalSeconds;
    });
  }

  Future<void> _autoSaveString(String key, String value) async {
    // Save to Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting(key, value);
      debugPrint('[Integrations] Saved $key to Hive');
    }

    // Also try SharedPreferences as backup
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (e) {
      debugPrint('[Integrations] SharedPreferences save failed for $key: $e');
    }
  }

  Future<void> _autoSaveInt(String key, int value) async {
    // Save to Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting(key, value);
      debugPrint('[Integrations] Saved $key to Hive');
    }

    // Also try SharedPreferences as backup
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, value);
    } catch (e) {
      debugPrint('[Integrations] SharedPreferences save failed for $key: $e');
    }
  }

  Future<void> _autoSaveBool(String key, bool value) async {
    // Save to Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting(key, value);
      debugPrint('[Integrations] Saved $key to Hive');
    }

    // Also try SharedPreferences as backup
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      debugPrint('[Integrations] SharedPreferences save failed for $key: $e');
    }
  }

  String _formatAbrpInterval(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds ~/ 60}m ${seconds % 60}s';
  }

  String _formatHealthcheckInterval(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds ~/ 60}m ${seconds % 60}s';
  }

  Future<void> _testHealthcheck() async {
    final url = _healthcheckUrlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a healthcheck URL')),
      );
      return;
    }

    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Testing healthcheck...')),
    );

    // Configure and test
    await HealthcheckService.instance.configure(
      enabled: _healthcheckEnabled,
      url: url,
      intervalSeconds: _healthcheckIntervalSeconds,
    );

    final success = await HealthcheckService.instance.sendSuccess();

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(success ? 'Healthcheck ping successful!' : 'Healthcheck ping failed'),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  Future<bool?> _showFleetAnalyticsConsentDialog() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.analytics, color: Colors.blue),
            SizedBox(width: 12),
            Text('Fleet Statistics'),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Help improve XPCarData by sharing anonymous statistics about your vehicle\'s battery health and charging patterns.',
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 16),
              Text('What we collect:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text('• Battery State of Health (SoH)'),
              Text('• Charging session statistics'),
              Text('• Battery temperature ranges'),
              Text('• Vehicle model (G6 variant)'),
              SizedBox(height: 16),
              Text('What we DON\'T collect:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text('• Location data'),
              Text('• VIN or personal identifiers'),
              Text('• Trip history'),
              Text('• Any personal information'),
              SizedBox(height: 16),
              Text(
                'All data is aggregated and anonymous. You can disable this at any time.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No Thanks'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('I Agree'),
          ),
        ],
      ),
    );
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Integrations'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ABRP Section
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
                    onChanged: (value) {
                      setState(() => _abrpEnabled = value);
                      _autoSaveBool('abrp_enabled', value);
                    },
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
                    onChanged: (value) => _autoSaveString('abrp_token', value),
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
                    onChanged: (value) => _autoSaveString('abrp_car_model', value),
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
                        ? (value) {
                            setState(() => _abrpIntervalSeconds = value.toInt());
                            _autoSaveInt('abrp_interval_seconds', value.toInt());
                          }
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

          // Fleet Statistics Section
          _buildSectionHeader('Fleet Statistics (Anonymous)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    title: const Text('Share Anonymous Fleet Data'),
                    subtitle: const Text('Help improve the app with aggregated statistics'),
                    value: _fleetAnalyticsEnabled,
                    onChanged: (value) async {
                      if (value && !FleetAnalyticsService.instance.consentGiven) {
                        final consent = await _showFleetAnalyticsConsentDialog();
                        if (consent != true) return;
                      }

                      await FleetAnalyticsService.instance.configure(
                        enabled: value,
                        consentGiven: value ? true : null,
                        vehicleModel: _vehicleModel,
                      );
                      setState(() => _fleetAnalyticsEnabled = value);
                    },
                    secondary: Icon(
                      Icons.analytics,
                      color: _fleetAnalyticsEnabled ? Colors.blue : Colors.grey,
                    ),
                  ),
                  const Divider(),
                  Text(
                    'When enabled, anonymous battery health and charging statistics are shared '
                    'to help build fleet-wide insights. No personal data, location, or vehicle ID is collected.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_fleetAnalyticsEnabled) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const FleetStatsScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.bar_chart),
                      label: const Text('View Fleet Statistics'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Healthcheck Section
          _buildSectionHeader('Health Monitoring (healthchecks.io)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    title: const Text('Enable Health Monitoring'),
                    subtitle: const Text('Ping healthchecks.io to monitor app status'),
                    value: _healthcheckEnabled,
                    onChanged: (value) async {
                      setState(() => _healthcheckEnabled = value);
                      await HealthcheckService.instance.configure(
                        enabled: value,
                        url: _healthcheckUrlController.text.trim(),
                        intervalSeconds: _healthcheckIntervalSeconds,
                      );
                    },
                    secondary: Icon(
                      Icons.monitor_heart,
                      color: _healthcheckEnabled ? Colors.green : Colors.grey,
                    ),
                  ),
                  const Divider(),
                  TextField(
                    controller: _healthcheckUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Ping URL',
                      hintText: 'https://hc-ping.com/your-uuid-here',
                      prefixIcon: Icon(Icons.link),
                      helperText: 'Get your URL from healthchecks.io',
                    ),
                    enabled: _healthcheckEnabled,
                    onChanged: (value) async {
                      await HealthcheckService.instance.configure(
                        enabled: _healthcheckEnabled,
                        url: value.trim(),
                        intervalSeconds: _healthcheckIntervalSeconds,
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    title: const Text('Ping Interval'),
                    subtitle: Text(_formatHealthcheckInterval(_healthcheckIntervalSeconds)),
                  ),
                  Slider(
                    value: _healthcheckIntervalSeconds.toDouble(),
                    min: 30,
                    max: 300,
                    divisions: 9,
                    label: _formatHealthcheckInterval(_healthcheckIntervalSeconds),
                    onChanged: _healthcheckEnabled
                        ? (value) async {
                            setState(() => _healthcheckIntervalSeconds = value.toInt());
                            await HealthcheckService.instance.configure(
                              enabled: _healthcheckEnabled,
                              url: _healthcheckUrlController.text.trim(),
                              intervalSeconds: value.toInt(),
                            );
                          }
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _healthcheckEnabled ? _testHealthcheck : null,
                          icon: const Icon(Icons.send),
                          label: const Text('Test Ping'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Healthchecks.io monitors your app and alerts you if it stops sending pings. '
                    'Create a free check at healthchecks.io and paste the ping URL above.',
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
