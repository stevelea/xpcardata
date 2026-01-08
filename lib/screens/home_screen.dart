import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vehicle_data_provider.dart';
import '../providers/mqtt_provider.dart';
import '../services/data_source_manager.dart';
import '../services/background_service.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Exit the app with proper cleanup
  Future<void> _exitApp() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Exit App'),
        content: const Text(
          'This will stop all data collection, disconnect from MQTT, and close the app.\n\nAre you sure you want to exit?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Exit'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // Stop background service
      try {
        await BackgroundServiceManager.instance.stop();
      } catch (e) {
        debugPrint('Error stopping background service: $e');
      }

      // Disconnect MQTT
      try {
        final mqttService = ref.read(mqttServiceProvider);
        mqttService.disconnect();
      } catch (e) {
        debugPrint('Error disconnecting MQTT: $e');
      }

      // Disconnect OBD
      try {
        final manager = ref.read(dataSourceManagerProvider);
        await manager.obdService.disconnect();
      } catch (e) {
        debugPrint('Error disconnecting OBD: $e');
      }

      // Exit the app
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final vehicleDataAsync = ref.watch(vehicleDataStreamProvider);
    final currentDataSource = ref.watch(currentDataSourceProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('XPCarData'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ),
              );
            },
            tooltip: 'Settings',
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            onPressed: _exitApp,
            tooltip: 'Exit App',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          // Trigger refresh
          ref.invalidate(vehicleDataStreamProvider);
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Data source indicator
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Text(
                        'Data Source',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      currentDataSource.when(
                        data: (source) {
                          String sourceName;
                          IconData icon;
                          Color color;

                          switch (source) {
                            case DataSource.carInfo:
                              sourceName = 'CarInfo API';
                              icon = Icons.car_rental;
                              color = Colors.green;
                              break;
                            case DataSource.obd:
                              sourceName = 'OBD-II';
                              icon = Icons.bluetooth;
                              color = Colors.blue;
                              break;
                          }

                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(icon, color: color, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                sourceName,
                                style: TextStyle(
                                  color: color,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          );
                        },
                        loading: () => const CircularProgressIndicator(),
                        error: (_, __) => const Text('Unknown'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Vehicle data display
              vehicleDataAsync.when(
                data: (data) {
                  if (data == null) {
                    return const Card(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(Icons.error_outline, size: 48, color: Colors.grey),
                              SizedBox(height: 16),
                              Text(
                                'No vehicle data available',
                                style: TextStyle(color: Colors.grey),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Waiting for data source to initialize...',
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }

                  return Column(
                    children: [
                      // Battery SOC - Large display (kept as is)
                      Card(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              const Text(
                                'Battery Level',
                                style: TextStyle(fontSize: 14),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                data.stateOfCharge?.toStringAsFixed(1) ?? '--',
                                style: const TextStyle(
                                  fontSize: 48,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Text(
                                '%',
                                style: TextStyle(fontSize: 18),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Wider grid of metrics - 2 columns for better readability
                      GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 2,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 2.2,
                        children: [
                          _buildMetricCard('State of Health', data.stateOfHealth?.toStringAsFixed(1) ?? '--', '%'),
                          _buildMetricCard('Battery Temp', data.batteryTemperature?.toStringAsFixed(1) ?? '--', '°C'),
                          _buildMetricCard('Voltage', data.batteryVoltage?.toStringAsFixed(1) ?? '--', 'V'),
                          _buildMetricCard('Current', data.batteryCurrent?.toStringAsFixed(1) ?? '--', 'A'),
                          _buildMetricCard('Power', data.power?.toStringAsFixed(1) ?? '--', 'kW'),
                          _buildMetricCard('Speed', data.speed?.toStringAsFixed(0) ?? '--', 'km/h'),
                          _buildMetricCard('Odometer', data.odometer?.toStringAsFixed(0) ?? '--', 'km'),
                          if (data.range != null)
                            _buildMetricCard('Range', data.range?.toStringAsFixed(0) ?? '--', 'km'),
                        ],
                      ),

                      // Additional properties from custom PIDs - styled as metric cards
                      // Filter out unsupported/error PIDs that return invalid values
                      if (data.additionalProperties != null && data.additionalProperties!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Builder(
                          builder: (context) {
                            // PIDs to exclude (unsupported on this vehicle)
                            const excludedPids = {
                              'COOLANT_T',
                              'MOTOR_T',
                              'DC_CHG_A',
                              'DC_CHG_V',
                              'CHARGING',
                            };

                            final filteredEntries = data.additionalProperties!.entries
                                .where((entry) => !excludedPids.contains(entry.key))
                                .where((entry) {
                                  // Also filter out NaN values
                                  if (entry.value is double) {
                                    return !(entry.value as double).isNaN;
                                  }
                                  return true;
                                })
                                .toList();

                            if (filteredEntries.isEmpty) {
                              return const SizedBox.shrink();
                            }

                            return GridView.count(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              crossAxisCount: 2,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                              childAspectRatio: 2.2,
                              children: filteredEntries.map((entry) {
                                final value = entry.value is double
                                    ? (entry.value as double).toStringAsFixed(1)
                                    : entry.value.toString();
                                return _buildMetricCard(entry.key, value, '');
                              }).toList(),
                            );
                          },
                        ),
                      ],
                    ],
                  );
                },
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(48),
                    child: Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Loading vehicle data...'),
                      ],
                    ),
                  ),
                ),
                error: (error, stack) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Column(
                        children: [
                          const Icon(Icons.error, size: 48, color: Colors.red),
                          const SizedBox(height: 16),
                          Text('Error: $error'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, String unit) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (unit.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
