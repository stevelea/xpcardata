import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/fleet_analytics_service.dart';
import '../providers/vehicle_data_provider.dart';

/// Screen showing fleet-wide statistics compared to user's vehicle
class FleetStatsScreen extends ConsumerStatefulWidget {
  const FleetStatsScreen({super.key});

  @override
  ConsumerState<FleetStatsScreen> createState() => _FleetStatsScreenState();
}

class _FleetStatsScreenState extends ConsumerState<FleetStatsScreen> {
  FleetStats? _fleetStats;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFleetStats();
  }

  Future<void> _loadFleetStats() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final stats = await FleetAnalyticsService.instance.getFleetStats();
      if (mounted) {
        setState(() {
          _fleetStats = stats;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vehicleData = ref.watch(vehicleDataStreamProvider).valueOrNull;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet Statistics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFleetStats,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorState()
              : _fleetStats == null
                  ? _buildNoDataState()
                  : RefreshIndicator(
                      onRefresh: _loadFleetStats,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          // Fleet overview card
                          _buildOverviewCard(theme),
                          const SizedBox(height: 16),

                          // Battery health comparison
                          _buildBatteryHealthCard(theme, vehicleData?.stateOfHealth),
                          const SizedBox(height: 16),

                          // Charging statistics
                          _buildChargingStatsCard(theme),
                          const SizedBox(height: 16),

                          // SOH distribution chart
                          _buildSohDistributionCard(theme),
                          const SizedBox(height: 16),

                          // Country distribution
                          _buildCountryDistributionCard(theme),
                          const SizedBox(height: 16),

                          // Last updated info
                          _buildLastUpdatedCard(theme),
                        ],
                      ),
                    ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Failed to load fleet statistics',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Unknown error',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadFleetStats,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoDataState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.analytics_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No Fleet Data Available Yet',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Fleet statistics will appear here once enough users have contributed anonymous data.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadFleetStats,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.people, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Fleet Overview',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(
                  icon: Icons.directions_car,
                  value: '${_fleetStats?.totalContributors ?? 0}',
                  label: 'Contributors',
                  color: Colors.blue,
                ),
                _buildStatItem(
                  icon: Icons.battery_full,
                  value: '${_fleetStats?.avgSoh.toStringAsFixed(1) ?? "--"}%',
                  label: 'Avg SOH',
                  color: Colors.green,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, size: 32, color: color),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  Widget _buildBatteryHealthCard(ThemeData theme, double? userSoh) {
    final fleetAvgSoh = _fleetStats?.avgSoh ?? 0;
    final difference = userSoh != null ? userSoh - fleetAvgSoh : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.health_and_safety, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Battery Health Comparison',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: _buildComparisonBar(
                    label: 'Your SOH',
                    value: userSoh,
                    maxValue: 100,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildComparisonBar(
                    label: 'Fleet Average',
                    value: fleetAvgSoh,
                    maxValue: 100,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
            if (difference != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: difference >= 0
                      ? Colors.green.withAlpha(30)
                      : Colors.orange.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      difference >= 0 ? Icons.trending_up : Icons.trending_down,
                      color: difference >= 0 ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        difference >= 0
                            ? 'Your battery is ${difference.abs().toStringAsFixed(1)}% above fleet average'
                            : 'Your battery is ${difference.abs().toStringAsFixed(1)}% below fleet average',
                        style: TextStyle(
                          color: difference >= 0 ? Colors.green[700] : Colors.orange[700],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonBar({
    required String label,
    required double? value,
    required double maxValue,
    required Color color,
  }) {
    final percentage = value != null ? (value / maxValue).clamp(0.0, 1.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        const SizedBox(height: 4),
        Text(
          value != null ? '${value.toStringAsFixed(1)}%' : '--',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: percentage,
          backgroundColor: Colors.grey[200],
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ],
    );
  }

  Widget _buildChargingStatsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.ev_station, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Charging Statistics',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildChargingStatItem(
                  icon: Icons.power,
                  value: _fleetStats?.avgChargingPowerAc.toStringAsFixed(0) ?? "--",
                  unit: 'kW',
                  label: 'Avg AC Power',
                  color: Colors.green,
                ),
                _buildChargingStatItem(
                  icon: Icons.flash_on,
                  value: _fleetStats?.avgChargingPowerDc.toStringAsFixed(0) ?? "--",
                  unit: 'kW',
                  label: 'Avg DC Power',
                  color: Colors.orange,
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Charging type distribution
            if (_fleetStats?.chargingTypeDistribution.isNotEmpty == true) ...[
              Text(
                'Charging Type Distribution',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              _buildChargingTypeBar(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChargingStatItem({
    required IconData icon,
    required String value,
    required String unit,
    required String label,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, size: 28, color: color),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 2),
            Text(
              unit,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  Widget _buildChargingTypeBar() {
    final distribution = _fleetStats?.chargingTypeDistribution ?? {};
    final acCount = distribution['ac'] ?? 0;
    final dcCount = distribution['dc'] ?? 0;
    final total = acCount + dcCount;

    if (total == 0) {
      return const Text('No charging data available');
    }

    final acPercentage = acCount / total;
    final dcPercentage = dcCount / total;

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              Expanded(
                flex: (acPercentage * 100).round(),
                child: Container(
                  height: 24,
                  color: Colors.green,
                  child: Center(
                    child: Text(
                      'AC ${(acPercentage * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: (dcPercentage * 100).round(),
                child: Container(
                  height: 24,
                  color: Colors.orange,
                  child: Center(
                    child: Text(
                      'DC ${(dcPercentage * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '$acCount AC sessions',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
            Text(
              '$dcCount DC sessions',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSohDistributionCard(ThemeData theme) {
    final distribution = _fleetStats?.sohDistribution ?? {};

    if (distribution.isEmpty) {
      return const SizedBox.shrink();
    }

    // Convert to sorted list of entries
    final entries = distribution.entries.toList()
      ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bar_chart, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'SOH Distribution',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            SizedBox(
              height: 200,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: entries.map((e) => e.value.toDouble()).reduce((a, b) => a > b ? a : b) * 1.2,
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        return BarTooltipItem(
                          '${entries[groupIndex].key}%: ${entries[groupIndex].value}',
                          const TextStyle(color: Colors.white),
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          if (value.toInt() >= entries.length) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '${entries[value.toInt()].key}%',
                              style: const TextStyle(fontSize: 10),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            value.toInt().toString(),
                            style: const TextStyle(fontSize: 10),
                          );
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  barGroups: entries.asMap().entries.map((entry) {
                    return BarChartGroupData(
                      x: entry.key,
                      barRods: [
                        BarChartRodData(
                          toY: entry.value.value.toDouble(),
                          color: Colors.blue,
                          width: 16,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Number of vehicles at each SOH level',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountryDistributionCard(ThemeData theme) {
    final distribution = _fleetStats?.countryDistribution ?? {};

    if (distribution.isEmpty) {
      return const SizedBox.shrink();
    }

    // Sort by count (descending) and take top 10
    final entries = distribution.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topEntries = entries.take(10).toList();
    final totalContributions = distribution.values.fold(0, (a, b) => a + b);

    // Country code to flag emoji mapping
    String countryFlag(String code) {
      // Convert country code to flag emoji
      if (code.length != 2) return code;
      final firstLetter = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
      final secondLetter = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
      return String.fromCharCodes([firstLetter, secondLetter]);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.public, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Contributors by Country',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            ...topEntries.map((entry) {
              final percentage = (entry.value / totalContributions * 100);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Text(
                      countryFlag(entry.key),
                      style: const TextStyle(fontSize: 20),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      entry.key,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: percentage / 100,
                          minHeight: 16,
                          backgroundColor: Colors.grey[200],
                          valueColor: AlwaysStoppedAnimation<Color>(
                            theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 50,
                      child: Text(
                        '${percentage.toStringAsFixed(0)}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
            if (entries.length > 10) ...[
              const SizedBox(height: 8),
              Text(
                '+ ${entries.length - 10} more countries',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLastUpdatedCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.update, size: 20, color: Colors.grey[600]),
            const SizedBox(width: 8),
            Text(
              'Last updated: ${_formatDateTime(_fleetStats?.lastUpdated)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime? dateTime) {
    if (dateTime == null) return 'Unknown';
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes} minutes ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours} hours ago';
    } else {
      return '${difference.inDays} days ago';
    }
  }
}
