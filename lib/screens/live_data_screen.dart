import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vehicle_data_provider.dart';
import '../models/vehicle_data.dart';
import '../models/obd_pid_config.dart';

/// Screen showing all live vehicle data including cell voltages and temperatures
class LiveDataScreen extends ConsumerStatefulWidget {
  const LiveDataScreen({super.key});

  @override
  ConsumerState<LiveDataScreen> createState() => _LiveDataScreenState();
}

class _LiveDataScreenState extends ConsumerState<LiveDataScreen> {
  bool _cellVoltagesExpanded = true;
  bool _cellTempsExpanded = true;
  bool _additionalDataExpanded = true;

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(dataSourceManagerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Vehicle Data'),
        actions: [
          // Connection status indicator
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Icon(
                  manager.obdService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: manager.obdService.isConnected ? Colors.green : Colors.grey,
                  size: 20,
                ),
                const SizedBox(width: 4),
                Text(
                  manager.obdService.isConnected ? 'Connected' : 'Disconnected',
                  style: TextStyle(
                    color: manager.obdService.isConnected ? Colors.green : Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: StreamBuilder<VehicleData>(
        stream: manager.vehicleDataStream,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bluetooth_searching, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'Waiting for vehicle data...',
                    style: TextStyle(color: Colors.grey[600], fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Connect to OBD adapter to see live data',
                    style: TextStyle(color: Colors.grey[500], fontSize: 14),
                  ),
                ],
              ),
            );
          }

          final data = snapshot.data!;
          final pidConfigs = manager.obdService.customPIDs;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Primary vehicle data section
              _buildPrimaryDataCard(data, theme),
              const SizedBox(height: 16),

              // Cell Voltages Section
              _buildCellVoltagesCard(data, pidConfigs, theme),
              const SizedBox(height: 16),

              // Cell Temperatures Section
              _buildCellTemperaturesCard(data, pidConfigs, theme),
              const SizedBox(height: 16),

              // Additional PID Data Section
              _buildAdditionalDataCard(data, pidConfigs, theme),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPrimaryDataCard(VehicleData data, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.battery_charging_full, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Primary Data',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(),
            _buildDataRow('State of Charge', '${data.stateOfCharge?.toStringAsFixed(1) ?? '--'}%'),
            _buildDataRow('State of Health', '${data.stateOfHealth?.toStringAsFixed(1) ?? '--'}%'),
            _buildDataRow('Battery Voltage', '${data.batteryVoltage?.toStringAsFixed(1) ?? '--'} V'),
            _buildDataRow('Battery Current', '${data.batteryCurrent?.toStringAsFixed(1) ?? '--'} A'),
            _buildDataRow('Battery Temperature', '${data.batteryTemperature?.toStringAsFixed(1) ?? '--'} °C'),
            _buildDataRow('Power', '${data.power?.toStringAsFixed(1) ?? '--'} kW'),
            _buildDataRow('Speed', '${data.speed?.toStringAsFixed(0) ?? '--'} km/h'),
            _buildDataRow('Odometer', '${data.odometer?.toStringAsFixed(0) ?? '--'} km'),
            _buildDataRow('Range', '${data.range?.toStringAsFixed(0) ?? '--'} km'),
            _buildDataRow('Cumulative Charge', '${data.cumulativeCharge?.toStringAsFixed(1) ?? '--'} Ah'),
            _buildDataRow('Cumulative Discharge', '${data.cumulativeDischarge?.toStringAsFixed(1) ?? '--'} Ah'),
          ],
        ),
      ),
    );
  }

  Widget _buildCellVoltagesCard(VehicleData data, List<OBDPIDConfig> pidConfigs, ThemeData theme) {
    final cellVoltagesRaw = data.additionalProperties?['cellVoltages'];
    final hasData = cellVoltagesRaw != null && cellVoltagesRaw is List && cellVoltagesRaw.isNotEmpty;

    List<double> voltages = [];
    double minV = 0, maxV = 0, avgV = 0, deltaV = 0;
    if (hasData) {
      voltages = cellVoltagesRaw.cast<double>();
      minV = voltages.reduce((a, b) => a < b ? a : b);
      maxV = voltages.reduce((a, b) => a > b ? a : b);
      avgV = voltages.reduce((a, b) => a + b) / voltages.length;
      deltaV = (maxV - minV) * 1000; // mV
    }

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.battery_std, color: theme.colorScheme.primary),
            title: Text(
              'Cell Voltages',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            subtitle: hasData
                ? Text('${voltages.length} cells • ΔV: ${deltaV.toStringAsFixed(0)} mV')
                : const Text('No data - waiting for low priority poll'),
            trailing: hasData
                ? IconButton(
                    icon: Icon(_cellVoltagesExpanded ? Icons.expand_less : Icons.expand_more),
                    onPressed: () => setState(() => _cellVoltagesExpanded = !_cellVoltagesExpanded),
                  )
                : null,
          ),
          if (hasData) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatChip('Min', '${minV.toStringAsFixed(3)} V', Colors.blue),
                  _buildStatChip('Avg', '${avgV.toStringAsFixed(3)} V', Colors.green),
                  _buildStatChip('Max', '${maxV.toStringAsFixed(3)} V', Colors.orange),
                  _buildStatChip('ΔV', '${deltaV.toStringAsFixed(0)} mV', Colors.purple),
                ],
              ),
            ),
            if (_cellVoltagesExpanded) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: _buildVoltageGrid(voltages, minV, maxV),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildCellTemperaturesCard(VehicleData data, List<OBDPIDConfig> pidConfigs, ThemeData theme) {
    final cellTempsRaw = data.additionalProperties?['cellTemperatures'];
    final hasData = cellTempsRaw != null && cellTempsRaw is List && cellTempsRaw.isNotEmpty;

    List<double> temps = [];
    double minT = 0, maxT = 0, avgT = 0, deltaT = 0;
    if (hasData) {
      temps = cellTempsRaw.cast<double>();
      minT = temps.reduce((a, b) => a < b ? a : b);
      maxT = temps.reduce((a, b) => a > b ? a : b);
      avgT = temps.reduce((a, b) => a + b) / temps.length;
      deltaT = maxT - minT;
    }

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.thermostat, color: theme.colorScheme.primary),
            title: Text(
              'Cell Temperatures',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            subtitle: hasData
                ? Text('${temps.length} sensors • ΔT: ${deltaT.toStringAsFixed(1)} °C')
                : const Text('No data - waiting for low priority poll'),
            trailing: hasData
                ? IconButton(
                    icon: Icon(_cellTempsExpanded ? Icons.expand_less : Icons.expand_more),
                    onPressed: () => setState(() => _cellTempsExpanded = !_cellTempsExpanded),
                  )
                : null,
          ),
          if (hasData) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatChip('Min', '${minT.toStringAsFixed(1)} °C', Colors.blue),
                  _buildStatChip('Avg', '${avgT.toStringAsFixed(1)} °C', Colors.green),
                  _buildStatChip('Max', '${maxT.toStringAsFixed(1)} °C', Colors.orange),
                  _buildStatChip('ΔT', '${deltaT.toStringAsFixed(1)} °C', Colors.purple),
                ],
              ),
            ),
            if (_cellTempsExpanded) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: _buildTemperatureGrid(temps, minT, maxT),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildAdditionalDataCard(VehicleData data, List<OBDPIDConfig> pidConfigs, ThemeData theme) {
    if (data.additionalProperties == null || data.additionalProperties!.isEmpty) {
      return const SizedBox.shrink();
    }

    // Exclude cell voltages/temps (shown above) and list values
    final filteredEntries = data.additionalProperties!.entries
        .where((entry) => entry.key != 'cellVoltages' && entry.key != 'cellTemperatures')
        .where((entry) => entry.value is! List)
        .where((entry) {
          if (entry.value is double) {
            return !(entry.value as double).isNaN;
          }
          return true;
        })
        .toList();

    if (filteredEntries.isEmpty) {
      return const SizedBox.shrink();
    }

    // Create a map of PID name to priority
    final pidPriorityMap = <String, PIDPriority>{};
    for (final pid in pidConfigs) {
      pidPriorityMap[pid.name] = pid.priority;
    }

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.analytics, color: theme.colorScheme.primary),
            title: Text(
              'Additional PID Data',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('${filteredEntries.length} values'),
            trailing: IconButton(
              icon: Icon(_additionalDataExpanded ? Icons.expand_less : Icons.expand_more),
              onPressed: () => setState(() => _additionalDataExpanded = !_additionalDataExpanded),
            ),
          ),
          if (_additionalDataExpanded) ...[
            const Divider(height: 1),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filteredEntries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = filteredEntries[index];
                final value = entry.value is double
                    ? (entry.value as double).toStringAsFixed(2)
                    : entry.value.toString();
                final priority = pidPriorityMap[entry.key] ?? PIDPriority.high;
                final isLowPriority = priority == PIDPriority.low;

                return ListTile(
                  dense: true,
                  title: Text(entry.key),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLowPriority)
                        Tooltip(
                          message: 'Low priority: updates every ~1 min',
                          child: Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: Colors.grey[400],
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      Text(
                        value,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDataRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: color,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVoltageGrid(List<double> voltages, double minV, double maxV) {
    final range = maxV - minV;

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: List.generate(voltages.length, (index) {
        final v = voltages[index];
        // Color based on position in range (green = close to avg, red/blue = extreme)
        final normalized = range > 0 ? (v - minV) / range : 0.5;
        Color color;
        if (normalized < 0.2) {
          color = Colors.blue; // Low voltage
        } else if (normalized > 0.8) {
          color = Colors.orange; // High voltage
        } else {
          color = Colors.green; // Normal
        }

        return Tooltip(
          message: 'Cell ${index + 1}: ${v.toStringAsFixed(3)} V',
          child: Container(
            width: 28,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: color.withOpacity(0.5), width: 1),
            ),
            child: Text(
              v.toStringAsFixed(2).substring(2), // Just show decimal part
              style: TextStyle(fontSize: 8, color: color, fontWeight: FontWeight.bold),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildTemperatureGrid(List<double> temps, double minT, double maxT) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: List.generate(temps.length, (index) {
        final t = temps[index];
        // Color based on temperature (blue = cold, green = normal, orange/red = hot)
        Color color;
        if (t < 15) {
          color = Colors.blue;
        } else if (t < 35) {
          color = Colors.green;
        } else if (t < 45) {
          color = Colors.orange;
        } else {
          color = Colors.red;
        }

        return Tooltip(
          message: 'Sensor ${index + 1}: ${t.toStringAsFixed(1)} °C',
          child: Container(
            width: 44,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withOpacity(0.5), width: 1),
            ),
            child: Text(
              '${t.toStringAsFixed(0)}°',
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold),
            ),
          ),
        );
      }),
    );
  }
}
