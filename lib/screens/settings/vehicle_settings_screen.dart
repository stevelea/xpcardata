import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers/vehicle_data_provider.dart';
import '../../services/open_charge_map_service.dart';

/// Vehicle settings sub-screen
/// Includes: Vehicle Model, Location Services
class VehicleSettingsScreen extends ConsumerStatefulWidget {
  const VehicleSettingsScreen({super.key});

  @override
  ConsumerState<VehicleSettingsScreen> createState() => _VehicleSettingsScreenState();
}

class _VehicleSettingsScreenState extends ConsumerState<VehicleSettingsScreen> {
  String _vehicleModel = '24LR';
  bool _locationEnabled = false;

  static const Map<String, double> _batteryCapacities = {
    '24LR': 87.5,
    '24SR': 66.0,
    '25LR': 80.8,
    '25SR': 68.5,
  };

  static const Map<String, String> _modelLabels = {
    '24LR': '2024 LR/AWD (87.5 kWh)',
    '24SR': '2024 SR (66 kWh)',
    '25LR': '2025 LR/AWD (80.8 kWh)',
    '25SR': '2025 SR (68.5 kWh)',
  };

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _vehicleModel = prefs.getString('vehicle_model') ?? '24LR';
        _locationEnabled = prefs.getBool('location_enabled') ?? false;
      });
    } catch (e) {
      debugPrint('Failed to load settings: $e');
    }
  }

  Future<void> _autoSaveString(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (e) {
      debugPrint('Failed to save $key: $e');
    }
  }

  void _showVehicleModelPicker() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Vehicle Model'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _modelLabels.entries.map((entry) {
            return RadioListTile<String>(
              title: Text(entry.value),
              value: entry.key,
              groupValue: _vehicleModel,
              onChanged: (value) {
                if (value != null) {
                  setState(() => _vehicleModel = value);
                  _autoSaveString('vehicle_model', value);
                  Navigator.pop(context);
                }
              },
            );
          }).toList(),
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
                    subtitle: Text(_modelLabels[_vehicleModel] ?? 'Unknown'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _showVehicleModelPicker,
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.battery_full),
                    title: const Text('Battery Capacity'),
                    subtitle: Text('${_batteryCapacities[_vehicleModel]?.toStringAsFixed(1) ?? "--"} kWh'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Battery capacity is used for range estimation and energy calculations.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
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
                    value: _locationEnabled,
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
                      color: _locationEnabled ? Colors.teal : Colors.grey,
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
                  if (_locationEnabled) ...[
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
                  if (_locationEnabled) ...[
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
