import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../providers/vehicle_data_provider.dart';
import '../../services/github_update_service.dart' show GitHubUpdateService, appVersion;
import '../../services/background_service.dart';
import '../../services/theme_service.dart';
import '../../theme/app_themes.dart';
import '../../services/open_charge_map_service.dart';
import '../../services/hive_storage_service.dart';

/// App settings sub-screen
/// Includes: App Behavior, Updates, Alert Thresholds
class AppSettingsScreen extends ConsumerStatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  ConsumerState<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends ConsumerState<AppSettingsScreen> {
  // App Behavior
  int _updateFrequencySeconds = 2;
  bool _startMinimised = false;
  bool _backgroundServiceEnabled = false;
  bool _backgroundServiceAvailable = false;

  // Location/GPS - tracks user interaction, initialized from DataSourceManager
  bool? _locationEnabled; // null means use DataSourceManager value directly

  // Alert Thresholds
  double _lowBatteryThreshold = 20.0;
  double _criticalBatteryThreshold = 10.0;
  double _highTempThreshold = 45.0;
  double _auxBatteryProtectionThreshold = 12.5;
  bool _auxBatteryProtectionEnabled = true;

  // Updates
  bool _checkingForUpdates = false;
  bool _downloadingUpdate = false;
  double _downloadProgress = 0.0;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkBackgroundServiceAvailability();
    _loadVersion();
    // Location state will be initialized in build() from DataSourceManager
    // This ensures ref is properly available
  }

  /// Get effective location enabled state - use local state if set, otherwise read from Hive/DataSourceManager
  bool _getLocationEnabled() {
    if (_locationEnabled != null) {
      return _locationEnabled!;
    }

    // First access - try Hive first (most reliable on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      final hiveState = hive.getSetting<bool>('location_enabled');
      if (hiveState != null) {
        debugPrint('[AppSettings] Reading location from Hive: $hiveState');
        return hiveState;
      }
    }

    // Fallback to DataSourceManager
    final dataSourceManager = ref.read(dataSourceManagerProvider);
    final state = dataSourceManager.isLocationEnabled;
    debugPrint('[AppSettings] Reading location from DataSourceManager: $state');
    return state;
  }

  Future<void> _loadVersion() async {
    // Load version from package info
    setState(() {
      _version = appVersion;
    });
  }

  void _checkBackgroundServiceAvailability() {
    try {
      final available = BackgroundServiceManager.instance.isAvailable;
      setState(() => _backgroundServiceAvailable = available);
    } catch (e) {
      debugPrint('Background service availability check failed: $e');
    }
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _updateFrequencySeconds = prefs.getInt('update_frequency_seconds') ?? 2;
        _startMinimised = prefs.getBool('start_minimised') ?? false;
        _backgroundServiceEnabled = prefs.getBool('background_service_enabled') ?? false;
        _lowBatteryThreshold = prefs.getDouble('alert_low_battery') ?? 20.0;
        _criticalBatteryThreshold = prefs.getDouble('alert_critical_battery') ?? 10.0;
        _highTempThreshold = prefs.getDouble('alert_high_temp') ?? 45.0;
        _auxBatteryProtectionEnabled = prefs.getBool('aux_battery_protection_enabled') ?? true;
        _auxBatteryProtectionThreshold = prefs.getDouble('aux_battery_protection_threshold') ?? 12.5;
      });
    } catch (e) {
      debugPrint('Failed to load settings: $e');
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

  Future<void> _autoSaveDouble(String key, double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(key, value);
    } catch (e) {
      debugPrint('Failed to save $key: $e');
    }
  }

  String _formatUpdateFrequency(int seconds) {
    if (seconds < 60) {
      return '$seconds second${seconds == 1 ? '' : 's'}';
    } else {
      final minutes = (seconds / 60).round();
      return '$minutes minute${minutes == 1 ? '' : 's'}';
    }
  }

  int _getUpdateFrequencyDivisions() {
    return 99;
  }

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

  Future<void> _checkForUpdates() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    setState(() => _checkingForUpdates = true);

    try {
      final hasUpdate = await GitHubUpdateService.instance.checkForUpdates();

      if (!mounted) return;
      setState(() => _checkingForUpdates = false);

      if (hasUpdate) {
        _showUpdateDialog();
      } else if (GitHubUpdateService.instance.error != null) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Error: ${GitHubUpdateService.instance.error}'),
            backgroundColor: Colors.red,
          ),
        );
      } else {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text('You are running the latest version'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkingForUpdates = false);
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Error checking for updates: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showUpdateDialog() {
    final release = GitHubUpdateService.instance.latestRelease;
    if (release == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update Available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Version ${release.version}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text('Released: ${release.formattedDate}'),
            if (release.apkSize != null) Text('Size: ${release.formattedSize}'),
            const SizedBox(height: 16),
            const Text('Release Notes:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: Text(
                  release.body.isNotEmpty ? release.body : 'No release notes available',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          if (release.apkDownloadUrl != null)
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _downloadAndInstallUpdate();
              },
              icon: const Icon(Icons.download),
              label: const Text('Download & Install'),
            ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstallUpdate() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    // Check install permission first
    const channel = MethodChannel('com.example.carsoc/update');
    try {
      final canInstall = await channel.invokeMethod<bool>('canRequestPackageInstalls') ?? false;
      if (!canInstall) {
        if (mounted) {
          final shouldOpenSettings = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Permission Required'),
              content: const Text(
                'To install updates, you need to allow this app to install unknown apps. '
                'Would you like to open settings?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          );

          if (shouldOpenSettings == true) {
            await channel.invokeMethod('openInstallPermissionSettings');
          }
        }
        return;
      }
    } catch (e) {
      debugPrint('Permission check failed: $e');
    }

    setState(() {
      _downloadingUpdate = true;
      _downloadProgress = 0.0;
    });

    try {
      final filePath = await GitHubUpdateService.instance.downloadUpdate(
        onProgress: (progress) {
          if (mounted) {
            setState(() => _downloadProgress = progress);
          }
        },
      );

      if (!mounted) return;
      setState(() => _downloadingUpdate = false);

      if (filePath != null) {
        // Install the APK
        try {
          await channel.invokeMethod('installApk', {'filePath': filePath});
        } catch (e) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text('Failed to launch installer: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } else {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Download failed: ${GitHubUpdateService.instance.error ?? "Unknown error"}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloadingUpdate = false);
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Download error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showGitHubTokenDialog() async {
    final controller = TextEditingController();

    // Load existing token
    await GitHubUpdateService.instance.loadGitHubToken();

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('GitHub Token'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Add a GitHub personal access token to avoid rate limiting.\n\n'
                  'To create a token:\n'
                  '1. Go to github.com → Settings → Developer settings\n'
                  '2. Personal access tokens → Tokens (classic)\n'
                  '3. Generate new token (no scopes needed)\n\n'
                  'Leave empty to use unauthenticated requests (60/hour limit).',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: 'GitHub Token',
                    hintText: 'ghp_xxxxxxxxxxxx',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await GitHubUpdateService.instance.setGitHubToken(
                controller.text.isEmpty ? null : controller.text,
              );
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      controller.text.isEmpty
                          ? 'GitHub token removed'
                          : 'GitHub token saved',
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
            child: const Text('Save'),
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

  Widget _buildThresholdSlider(
    String label,
    double value,
    double min,
    double max,
    String unit,
    String prefKey,
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
          onChanged: (newValue) {
            onChanged(newValue);
            _autoSaveDouble(prefKey, newValue);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dataSourceManager = ref.watch(dataSourceManagerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('App Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
                    onChanged: (value) {
                      setState(() => _updateFrequencySeconds = value.toInt());
                      _autoSaveInt('update_frequency_seconds', value.toInt());
                      dataSourceManager.updateFrequency(value.toInt());
                    },
                  ),
                  const Divider(),
                  SwitchListTile(
                    title: const Text('Start Minimised'),
                    subtitle: const Text('App starts in background/notification'),
                    value: _startMinimised,
                    onChanged: (value) {
                      setState(() => _startMinimised = value);
                      _autoSaveBool('start_minimised', value);
                    },
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
                          }

                          // Request battery optimization exemption
                          try {
                            if (!await Permission.ignoreBatteryOptimizations.isGranted) {
                              await Permission.ignoreBatteryOptimizations.request();
                            }
                          } catch (e) {
                            debugPrint('Battery optimization permission error: $e');
                          }
                        }

                        setState(() => _backgroundServiceEnabled = value);
                        _autoSaveBool('background_service_enabled', value);

                        try {
                          if (value) {
                            await BackgroundServiceManager.instance.start();
                          } else {
                            await BackgroundServiceManager.instance.stop();
                          }
                        } catch (e) {
                          debugPrint('Background service error: $e');
                          if (mounted) {
                            setState(() => _backgroundServiceEnabled = !value);
                            _autoSaveBool('background_service_enabled', !value);
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

          // Appearance Section (Theme)
          _buildSectionHeader('Appearance'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.palette, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  const Text('Theme:', style: TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: AppThemeMode.values.map((mode) {
                          final isSelected = ThemeService.instance.currentTheme == mode;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              avatar: Icon(mode.icon, size: 16),
                              label: Text(mode.displayName, style: const TextStyle(fontSize: 12)),
                              selected: isSelected,
                              onSelected: (selected) {
                                if (selected) {
                                  ThemeService.instance.setTheme(mode);
                                  setState(() {});
                                }
                              },
                              visualDensity: VisualDensity.compact,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // GPS/Location Section
          _buildSectionHeader('Location'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    title: const Text('Enable GPS Tracking'),
                    subtitle: const Text('Track vehicle location via phone GPS'),
                    value: _getLocationEnabled(),
                    onChanged: (value) async {
                      final dataSourceManager = ref.read(dataSourceManagerProvider);
                      final scaffoldMessenger = ScaffoldMessenger.of(context);
                      final success = await dataSourceManager.setLocationEnabled(value);
                      if (success) {
                        setState(() => _locationEnabled = value);
                      } else if (mounted) {
                        scaffoldMessenger.showSnackBar(
                          const SnackBar(
                            content: Text('Failed to enable location - check permissions'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                    secondary: Icon(
                      Icons.location_on,
                      color: _getLocationEnabled() ? Colors.teal : Colors.grey,
                    ),
                  ),
                  const Divider(),
                  Text(
                    'When enabled, GPS coordinates are added to vehicle data and published via MQTT. '
                    'Location is not sent to ABRP (it uses its own GPS).',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_getLocationEnabled()) ...[
                    const SizedBox(height: 16),
                    Builder(
                      builder: (context) {
                        final dataSourceManager = ref.watch(dataSourceManagerProvider);
                        final lastLocation = dataSourceManager.locationService.lastLocation;
                        if (lastLocation != null) {
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.teal.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.teal.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.my_location, color: Colors.teal, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${lastLocation.latitude.toStringAsFixed(5)}, ${lastLocation.longitude.toStringAsFixed(5)}',
                                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ],
                  const Divider(),
                  // Home Location Setting
                  ListTile(
                    leading: Icon(
                      Icons.home,
                      color: OpenChargeMapService.instance.hasHomeLocation
                          ? Colors.blue
                          : Colors.grey,
                    ),
                    title: const Text('Home Location'),
                    subtitle: Text(
                      OpenChargeMapService.instance.hasHomeLocation
                          ? 'Set - charging here shows as "Home"'
                          : 'Not set',
                    ),
                    trailing: OpenChargeMapService.instance.hasHomeLocation
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () async {
                              final scaffoldMessenger = ScaffoldMessenger.of(context);
                              await OpenChargeMapService.instance.clearHomeLocation();
                              setState(() {});
                              if (mounted) {
                                scaffoldMessenger.showSnackBar(
                                  const SnackBar(content: Text('Home location cleared')),
                                );
                              }
                            },
                            tooltip: 'Clear home location',
                          )
                        : null,
                  ),
                  if (_getLocationEnabled()) ...[
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final dataSourceManager = ref.read(dataSourceManagerProvider);
                        final scaffoldMessenger = ScaffoldMessenger.of(context);
                        final location = dataSourceManager.locationService.lastLocation;
                        if (location != null) {
                          await OpenChargeMapService.instance.setHomeLocation(
                            location.latitude,
                            location.longitude,
                            'Home',
                          );
                          setState(() {});
                          if (mounted) {
                            scaffoldMessenger.showSnackBar(
                              const SnackBar(
                                content: Text('Home location set to current position'),
                                backgroundColor: Colors.green,
                              ),
                            );
                          }
                        } else {
                          scaffoldMessenger.showSnackBar(
                            const SnackBar(
                              content: Text('No GPS location available'),
                              backgroundColor: Colors.orange,
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.my_location),
                      label: const Text('Set Current Location as Home'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'Charging sessions at your home location will automatically be labeled "Home" instead of looking up a station name.',
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
                    'alert_low_battery',
                    (value) => setState(() => _lowBatteryThreshold = value),
                  ),
                  const Divider(),
                  _buildThresholdSlider(
                    'Critical Battery Alert',
                    _criticalBatteryThreshold,
                    0,
                    30,
                    '%',
                    'alert_critical_battery',
                    (value) => setState(() => _criticalBatteryThreshold = value),
                  ),
                  const Divider(),
                  _buildThresholdSlider(
                    'High Temperature Alert',
                    _highTempThreshold,
                    30,
                    70,
                    '°C',
                    'alert_high_temp',
                    (value) => setState(() => _highTempThreshold = value),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 12V Battery Protection Section
          _buildSectionHeader('12V Battery Protection'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Enable 12V Battery Protection'),
                    subtitle: Text(
                      _auxBatteryProtectionEnabled
                          ? 'Pauses OBD polling when 12V drops below threshold'
                          : 'OBD polling continues regardless of 12V voltage',
                    ),
                    value: _auxBatteryProtectionEnabled,
                    onChanged: (value) {
                      setState(() => _auxBatteryProtectionEnabled = value);
                      _autoSaveBool('aux_battery_protection_enabled', value);
                    },
                    secondary: Icon(
                      Icons.battery_alert,
                      color: _auxBatteryProtectionEnabled ? Colors.orange : Colors.grey,
                    ),
                  ),
                  if (_auxBatteryProtectionEnabled) ...[
                    const Divider(),
                    ListTile(
                      title: const Text('Minimum 12V Voltage'),
                      trailing: Text(
                        '${_auxBatteryProtectionThreshold.toStringAsFixed(1)}V',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                    Slider(
                      value: _auxBatteryProtectionThreshold,
                      min: 11.0,
                      max: 13.0,
                      divisions: 20, // 0.1V increments
                      label: '${_auxBatteryProtectionThreshold.toStringAsFixed(1)}V',
                      onChanged: (value) {
                        setState(() => _auxBatteryProtectionThreshold = value);
                        _autoSaveDouble('aux_battery_protection_threshold', value);
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'OBD polling will pause when 12V battery drops below this threshold '
                        'to prevent depleting the auxiliary battery. Polling resumes when '
                        'voltage rises above ${(_auxBatteryProtectionThreshold + 0.3).toStringAsFixed(1)}V.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Updates Section
          _buildSectionHeader('Updates'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.system_update,
                      color: GitHubUpdateService.instance.updateAvailable
                          ? Colors.orange
                          : Colors.grey,
                    ),
                    title: const Text('Check for Updates'),
                    subtitle: Text(
                      GitHubUpdateService.instance.updateAvailable
                          ? 'Version ${GitHubUpdateService.instance.latestRelease?.version} available'
                          : 'Current version: $_version',
                    ),
                    trailing: _checkingForUpdates
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: _checkingForUpdates ? null : _checkForUpdates,
                  ),
                  if (_downloadingUpdate) ...[
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Downloading update...'),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: _downloadProgress),
                          const SizedBox(height: 4),
                          Text(
                            '${(_downloadProgress * 100).toStringAsFixed(0)}%',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (GitHubUpdateService.instance.updateAvailable &&
                      !_downloadingUpdate) ...[
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _downloadAndInstallUpdate,
                              icon: const Icon(Icons.download),
                              label: const Text('Download & Install'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _showUpdateDialog,
                            icon: const Icon(Icons.notes),
                            label: const Text('Notes'),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.key),
                    title: const Text('GitHub Token (Optional)'),
                    subtitle: const Text('For higher API rate limits'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _showGitHubTokenDialog,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Updates are downloaded from GitHub releases. Add a token to avoid rate limiting.',
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
