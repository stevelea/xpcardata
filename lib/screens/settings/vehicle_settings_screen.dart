import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers/vehicle_data_provider.dart';
import '../../providers/mqtt_provider.dart';
import '../../services/open_charge_map_service.dart';
import '../../services/hive_storage_service.dart';

/// Vehicle settings sub-screen
/// Includes: Vehicle Model, Location Services
class VehicleSettingsScreen extends ConsumerStatefulWidget {
  const VehicleSettingsScreen({super.key});

  @override
  ConsumerState<VehicleSettingsScreen> createState() => _VehicleSettingsScreenState();
}

class _VehicleSettingsScreenState extends ConsumerState<VehicleSettingsScreen> {
  String _vehicleModel = '24LR';
  double? _customBatteryKwh; // Only used when _vehicleModel == customVehicleModelKey
  bool _useLegacyV3Pids = false; // Back-out switch for the WiCAN-corrected v4 XPENG profile
  bool? _locationEnabled; // null = not yet loaded, use Hive/DataSourceManager

  // Display labels for vehicle selection (only new keys shown in picker).
  // The `CUSTOM` entry lets users running non-XPENG community profiles
  // supply their own battery capacity (issue #7).
  static const Map<String, String> _modelLabels = {
    // XPENG G6
    'G6_24LR': 'G6 2024 LR/AWD (87.5 kWh)',
    'G6_24SR': 'G6 2024 SR (66 kWh)',
    'G6_25LR': 'G6 2025 LR/AWD (80.8 kWh)',
    'G6_25SR': 'G6 2025 SR (68.5 kWh)',
    // XPENG G9
    'G9_LR_AWD': 'G9 AWD Long Range (93 kWh)',
    'G9_LR_RWD': 'G9 RWD Long Range (93 kWh)',
    'G9_SR_RWD': 'G9 RWD Standard Range (75 kWh)',
    // XPENG P7
    'P7_LR_RWD': 'P7 RWD Long Range (82.7 kWh)',
    // Custom (community profile / other brand)
    customVehicleModelKey: 'Other / Custom (enter capacity below)',
  };

  // Legacy key mappings for display (existing users with old keys)
  static const Map<String, String> _legacyLabels = {
    '24LR': 'G6 2024 LR/AWD (87.5 kWh)',
    '24SR': 'G6 2024 SR (66 kWh)',
    '25LR': 'G6 2025 LR/AWD (80.8 kWh)',
    '25SR': 'G6 2025 SR (68.5 kWh)',
  };

  /// Get display label for any model key (new or legacy)
  String _getModelLabel(String key) {
    return _modelLabels[key] ?? _legacyLabels[key] ?? 'Unknown';
  }

  bool get _isCustomModel => _vehicleModel == customVehicleModelKey;

  /// Effective capacity for the current selection (custom override or table).
  double get _effectiveBatteryKwh =>
      resolveBatteryCapacity(_vehicleModel, _customBatteryKwh);

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    String? loadedModel;
    double? loadedCustomKwh;
    bool loadedLegacy = false;

    // Try Hive first (most reliable on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      loadedModel = hive.getSetting<String>('vehicle_model');
      loadedCustomKwh = hive.getSetting<double>('custom_battery_capacity_kwh');
    }

    // SharedPreferences for anything Hive didn't have + the legacy-profile flag
    try {
      final prefs = await SharedPreferences.getInstance();
      loadedModel ??= prefs.getString('vehicle_model');
      loadedCustomKwh ??= prefs.getDouble('custom_battery_capacity_kwh');
      loadedLegacy = prefs.getBool('use_legacy_pid_profile_v3') ?? false;
    } catch (e) {
      debugPrint('[VehicleSettings] Failed to load settings: $e');
    }

    setState(() {
      _vehicleModel = loadedModel ?? '24LR';
      _customBatteryKwh = loadedCustomKwh;
      _useLegacyV3Pids = loadedLegacy;
    });
    debugPrint('[VehicleSettings] Loaded vehicle_model=$_vehicleModel customKwh=$_customBatteryKwh legacyPids=$_useLegacyV3Pids');
  }

  Future<void> _setUseLegacyV3Pids(bool value) async {
    setState(() => _useLegacyV3Pids = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('use_legacy_pid_profile_v3', value);
    } catch (e) {
      debugPrint('[VehicleSettings] Failed to save legacy PID flag: $e');
    }
    // Force the OBD service to re-migrate so the toggle takes effect immediately
    // without an app restart.
    await ref.read(obdServiceProvider).reloadPidProfile();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value
            ? 'Reverted to legacy v3 PID profile'
            : 'Using v4 PID profile (WiCAN-corrected)'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _autoSaveDouble(String key, double value) async {
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting(key, value);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(key, value);
    } catch (e) {
      debugPrint('[VehicleSettings] SharedPreferences save failed for $key: $e');
    }
  }

  Future<void> _editCustomBatteryCapacity() async {
    final controller = TextEditingController(
      text: _customBatteryKwh != null ? _customBatteryKwh!.toStringAsFixed(1) : '',
    );
    final newValue = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Custom Battery Capacity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Usable pack capacity in kWh. Used for range estimation and charging-session energy math.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Capacity (kWh)',
                hintText: 'e.g. 77.4',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text.trim());
              if (parsed != null && parsed > 0) {
                Navigator.pop(context, parsed);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newValue != null) {
      setState(() => _customBatteryKwh = newValue);
      await _autoSaveDouble('custom_battery_capacity_kwh', newValue);
      ref.read(mqttServiceProvider).invalidateBatteryCapacityCache();
    }
  }

  /// Get effective location enabled state - use local state if set, otherwise read from Hive/DataSourceManager
  bool _getLocationEnabled() {
    // If user has interacted with toggle, use local state
    if (_locationEnabled != null) {
      return _locationEnabled!;
    }

    // Try Hive first (most reliable on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      final hiveState = hive.getSetting<bool>('location_enabled');
      if (hiveState != null) {
        return hiveState;
      }
    }

    // Fallback to DataSourceManager (it knows the runtime state)
    final dataSourceManager = ref.read(dataSourceManagerProvider);
    return dataSourceManager.isLocationEnabled;
  }

  Future<void> _autoSaveString(String key, String value) async {
    // Save to Hive first (most reliable on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting(key, value);
      debugPrint('[VehicleSettings] Saved $key to Hive: $value');
    }

    // Also save to SharedPreferences as backup
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
      debugPrint('[VehicleSettings] Saved $key to SharedPreferences: $value');
    } catch (e) {
      debugPrint('[VehicleSettings] SharedPreferences save failed for $key: $e');
    }
  }

  void _showVehicleModelPicker() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Vehicle Model'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _modelLabels.entries.map((entry) {
              return RadioListTile<String>(
                title: Text(entry.value),
                value: entry.key,
                groupValue: _vehicleModel,
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _vehicleModel = value);
                  await _autoSaveString('vehicle_model', value);
                  ref.read(mqttServiceProvider).invalidateBatteryCapacityCache();
                  if (!mounted) return;
                  Navigator.pop(context);
                  // If user picked CUSTOM and we don't have a capacity yet,
                  // prompt for one immediately so they don't end up at the
                  // 87.5 kWh fallback (issue #7).
                  if (value == customVehicleModelKey && _customBatteryKwh == null) {
                    await _editCustomBatteryCapacity();
                  }
                },
              );
            }).toList(),
          ),
        ),
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
    final dataSourceManager = ref.watch(dataSourceManagerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vehicle'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Vehicle Model Section
          _buildSectionHeader('Vehicle Settings'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: const Icon(Icons.directions_car),
                    title: const Text('Vehicle Model'),
                    subtitle: Text(_getModelLabel(_vehicleModel)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _showVehicleModelPicker,
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.battery_full),
                    title: const Text('Battery Capacity'),
                    subtitle: Text('${_effectiveBatteryKwh.toStringAsFixed(1)} kWh'
                        '${_isCustomModel ? " (custom)" : ""}'),
                    trailing: _isCustomModel
                        ? const Icon(Icons.edit)
                        : null,
                    onTap: _isCustomModel ? _editCustomBatteryCapacity : null,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Battery capacity is used for range estimation and energy calculations.'
                    '${_isCustomModel ? " Tap to edit." : ""}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  if (_vehicleModel != customVehicleModelKey) ...[
                    const Divider(),
                    SwitchListTile(
                      title: const Text('Use legacy v3 PIDs (XPENG only)'),
                      subtitle: const Text(
                        'Reverts to the pre-WiCAN-corrections PID profile. '
                        'Use only if v4 reports incorrect values for your car.',
                      ),
                      value: _useLegacyV3Pids,
                      onChanged: _setUseLegacyV3Pids,
                      secondary: Icon(
                        Icons.history,
                        color: _useLegacyV3Pids ? Colors.orange : Colors.grey,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Location Section
          _buildSectionHeader('Location Services'),
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
                          ? '${OpenChargeMapService.instance.homeLatitude?.toStringAsFixed(5)}, ${OpenChargeMapService.instance.homeLongitude?.toStringAsFixed(5)}'
                          : 'Not set - charging here will be labeled "Home"',
                    ),
                    trailing: OpenChargeMapService.instance.hasHomeLocation
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () async {
                              await OpenChargeMapService.instance.clearHomeLocation();
                              setState(() {});
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Home location cleared')),
                                );
                              }
                            },
                            tooltip: 'Clear home location',
                          )
                        : null,
                  ),
                  if (_getLocationEnabled()) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final location = dataSourceManager.locationService.lastLocation;
                          if (location != null) {
                            await OpenChargeMapService.instance.setHomeLocation(
                              location.latitude,
                              location.longitude,
                              'Home',
                            );
                            setState(() {});
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Home location set to current position'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            }
                          } else {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('No GPS location available'),
                                  backgroundColor: Colors.orange,
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.my_location),
                        label: const Text('Set Current Location as Home'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'Charging sessions at your home location will automatically be labeled "Home".',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Divider(),
                  // Left-Hand Drive Layout Toggle
                  SwitchListTile(
                    title: const Text('Left-Hand Drive Layout'),
                    subtitle: Text(
                      dataSourceManager.isLeftHandDrive
                          ? 'Speed on left, Battery on right (LHD countries)'
                          : 'Battery on left, Speed on right (RHD countries)',
                    ),
                    secondary: Icon(
                      Icons.swap_horiz,
                      color: dataSourceManager.isLeftHandDrive ? Colors.blue : Colors.grey,
                    ),
                    value: dataSourceManager.isLeftHandDrive,
                    onChanged: (value) async {
                      await dataSourceManager.setLeftHandDrive(value);
                      setState(() {});
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'For LHD countries (driver on left), dashboard info is positioned closer to the driver.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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
