import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vehicle_data_provider.dart';
import '../providers/mqtt_provider.dart';
import '../services/data_source_manager.dart';
import '../services/background_service.dart';
import '../services/obd_proxy_service.dart';
import '../services/tailscale_service.dart';
import '../services/connectivity_service.dart';
import '../services/fleet_analytics_service.dart';
import '../widgets/dashboard_widgets.dart';
import '../models/vehicle_data.dart';
import '../models/charging_session.dart';
import '../models/obd_pid_config.dart';
import 'settings_screen.dart';
import 'charging_history_screen.dart';
import 'fleet_stats_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isVpnActive = false;
  bool _isInternetConnected = false;
  StreamSubscription<bool>? _vpnStatusSubscription;
  StreamSubscription<bool>? _connectivitySubscription;
  List<ChargingSession> _recentSessions = [];
  bool _isLoadingSessions = true;

  @override
  void initState() {
    super.initState();
    // Start VPN status monitoring
    final tailscale = TailscaleService.instance;
    tailscale.startStatusMonitoring(interval: const Duration(seconds: 10));

    // Listen for VPN status changes
    _vpnStatusSubscription = tailscale.statusStream.listen((isActive) {
      if (mounted) {
        setState(() {
          _isVpnActive = isActive;
        });
      }
    });

    // Get initial status
    tailscale.checkVpnStatus().then((isActive) {
      if (mounted) {
        setState(() {
          _isVpnActive = isActive;
        });
      }
    });

    // Start internet connectivity monitoring
    final connectivity = ConnectivityService.instance;
    connectivity.startMonitoring(interval: const Duration(seconds: 15));

    // Listen for connectivity changes
    _connectivitySubscription = connectivity.statusStream.listen((isConnected) {
      if (mounted) {
        setState(() {
          _isInternetConnected = isConnected;
        });
      }
    });

    // Get initial connectivity status
    connectivity.checkConnectivity().then((isConnected) {
      if (mounted) {
        setState(() {
          _isInternetConnected = isConnected;
        });
      }
    });

    // Load recent charging sessions
    _loadRecentSessions();
  }

  Future<void> _loadRecentSessions() async {
    try {
      final manager = ref.read(dataSourceManagerProvider);
      final sessions = await manager.chargingSessionService.getRecentSessions(limit: 3);
      if (mounted) {
        setState(() {
          _recentSessions = sessions;
          _isLoadingSessions = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingSessions = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _vpnStatusSubscription?.cancel();
    _connectivitySubscription?.cancel();
    TailscaleService.instance.stopStatusMonitoring();
    ConnectivityService.instance.stopMonitoring();
    super.dispose();
  }

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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isTablet = constraints.maxWidth >= DashboardBreakpoints.phone;
          final padding = isTablet ? 24.0 : 16.0;

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(vehicleDataStreamProvider);
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(padding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Status bar with data source and service indicators
                  _buildStatusBar(currentDataSource, vehicleDataAsync, isTablet),
                  SizedBox(height: isTablet ? 20 : 12),

                  // Vehicle data display
                  vehicleDataAsync.when(
                    data: (data) {
                      if (data == null) {
                        return const DashboardEmptyState(
                          title: 'No vehicle data available',
                          subtitle: 'Waiting for data source to initialize...',
                        );
                      }
                      return _buildDashboardContent(data, constraints.maxWidth);
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
                    error: (error, stack) => DashboardEmptyState(
                      title: 'Error loading data',
                      subtitle: error.toString(),
                      icon: Icons.error,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Build status bar with data source and service indicators
  Widget _buildStatusBar(
    AsyncValue<DataSource> currentDataSource,
    AsyncValue<VehicleData?> vehicleDataAsync,
    bool isTablet,
  ) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: EdgeInsets.all(isTablet ? 16 : 12),
        child: isTablet
            ? Row(
                children: [
                  // Data source badge
                  _buildDataSourceWidget(currentDataSource),
                  const SizedBox(width: 16),
                  // Timestamp
                  _buildTimestampWidget(vehicleDataAsync),
                  const Spacer(),
                  // Service status row
                  _buildServiceStatusRow(ref),
                ],
              )
            : Column(
                children: [
                  // Top row: Data source and timestamp
                  Row(
                    children: [
                      Expanded(child: _buildDataSourceWidget(currentDataSource)),
                      _buildTimestampWidget(vehicleDataAsync),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Bottom row: Service status icons
                  _buildServiceStatusRow(ref),
                ],
              ),
      ),
    );
  }

  Widget _buildDataSourceWidget(AsyncValue<DataSource> currentDataSource) {
    return currentDataSource.when(
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
          case DataSource.proxy:
            sourceName = 'OBD Proxy';
            icon = Icons.wifi;
            color = Colors.purple;
            break;
        }

        return DataSourceBadge(
          sourceName: sourceName,
          icon: icon,
          color: color,
        );
      },
      loading: () => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (_, __) => const Text('Unknown', style: TextStyle(fontSize: 13)),
    );
  }

  Widget _buildTimestampWidget(AsyncValue<VehicleData?> vehicleDataAsync) {
    return vehicleDataAsync.when(
      data: (data) {
        if (data == null) return const SizedBox.shrink();
        return Text(
          _formatTimestamp(data.timestamp),
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  /// Build main dashboard content with responsive layout
  Widget _buildDashboardContent(VehicleData data, double screenWidth) {
    final isTablet = screenWidth >= DashboardBreakpoints.phone;
    final isLargeTablet = screenWidth >= DashboardBreakpoints.tablet;
    final isCompact = !isTablet;

    // Get battery capacity from settings
    final batteryCapacityAsync = ref.watch(batteryCapacityProvider);
    final batteryCapacity = batteryCapacityAsync.valueOrNull ?? 87.5;

    // Calculate estimated range from SOC × battery capacity × efficiency
    // Assume ~5.5 km/kWh efficiency for XPENG G6 (adjust based on real-world data)
    const double efficiencyKmPerKwh = 5.5;
    double? estimatedRange;

    if (data.stateOfCharge != null && data.stateOfCharge! > 0) {
      // Calculate: SOC% × capacity × efficiency
      estimatedRange = (data.stateOfCharge! / 100) * batteryCapacity * efficiencyKmPerKwh;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Primary metrics: Battery SOC and Range
        _buildPrimaryMetrics(data, estimatedRange, isCompact, isLargeTablet),
        SizedBox(height: isTablet ? 20 : 12),

        // Battery section header
        if (isTablet)
          const DashboardSectionHeader(
            title: 'BATTERY STATUS',
            icon: Icons.battery_charging_full,
          ),

        // Core metrics grid
        _buildCoreMetricsGrid(data, screenWidth, isCompact, estimatedRange),

        // Recent charging sessions section
        _buildChargingHistorySection(isCompact, isTablet),

        // Fleet Statistics section (if enabled)
        _buildFleetStatsSection(isCompact, isTablet),

        // Location section (if location data is available)
        if (data.hasLocation)
          _buildLocationSection(data, isCompact, isTablet),

        // Additional PIDs section
        _buildAdditionalPidsSection(data, screenWidth, isCompact, isTablet),
      ],
    );
  }

  /// Build primary metrics (SOC and Speed - the two most important real-time metrics)
  Widget _buildPrimaryMetrics(
    VehicleData data,
    double? estimatedRange,
    bool isCompact,
    bool isLargeTablet,
  ) {
    final theme = Theme.of(context);

    return Row(
      children: [
        // Battery SOC
        Expanded(
          child: PrimaryMetricCard(
            title: 'Battery',
            value: data.stateOfCharge?.toStringAsFixed(1) ?? '--',
            unit: '%',
            backgroundColor: theme.colorScheme.primaryContainer,
            isCompact: isCompact,
          ),
        ),
        SizedBox(width: isCompact ? 8 : 12),
        // Speed (swapped with Range - Speed is more real-time important)
        Expanded(
          child: PrimaryMetricCard(
            title: 'Speed',
            value: data.speed?.toStringAsFixed(0) ?? '--',
            unit: 'km/h',
            backgroundColor: theme.colorScheme.secondaryContainer,
            isCompact: isCompact,
          ),
        ),
      ],
    );
  }

  /// Build core metrics grid with responsive columns
  Widget _buildCoreMetricsGrid(VehicleData data, double screenWidth, bool isCompact, double? estimatedRange) {
    final columns = DashboardBreakpoints.getMetricColumns(screenWidth);

    // Calculate appropriate aspect ratio based on screen size
    double aspectRatio;
    if (isCompact) {
      aspectRatio = 2.0;
    } else if (columns == 3) {
      aspectRatio = 1.5;
    } else {
      aspectRatio = 1.3;
    }

    // Calculate cell voltage delta from HV_C_V_MAX and HV_C_V_MIN
    String cellVoltageDelta = '--';
    final hvMaxV = data.additionalProperties?['HV_C_V_MAX'];
    final hvMinV = data.additionalProperties?['HV_C_V_MIN'];
    if (hvMaxV != null && hvMinV != null && hvMaxV is num && hvMinV is num) {
      final delta = (hvMaxV - hvMinV) * 1000; // Convert to mV
      cellVoltageDelta = delta.toStringAsFixed(0);
    }

    // Power card values
    final voltage = data.batteryVoltage?.toStringAsFixed(0) ?? '--';
    final current = data.batteryCurrent?.toStringAsFixed(1) ?? '--';
    final power = data.power?.toStringAsFixed(1) ?? '--';

    final metrics = [
      // Guestimated Range moved from primary display (swapped with Speed)
      _MetricData('Guestimated Range', estimatedRange?.toStringAsFixed(0) ?? '--', 'km', Icons.route, Colors.green),
      _MetricData('State of Health', data.stateOfHealth?.toStringAsFixed(1) ?? '--', '%', Icons.health_and_safety, Colors.teal),
      _MetricData('Battery Temp', data.batteryTemperature?.toStringAsFixed(1) ?? '--', '°C', Icons.thermostat, Colors.orange),
      _MetricData('Cell ΔV', cellVoltageDelta, 'mV', Icons.battery_std, Colors.cyan),
      _MetricData('Odometer', data.odometer?.toStringAsFixed(0) ?? '--', 'km', Icons.straighten, Colors.blueGrey),
    ];

    // Build list of widgets - regular MetricCards plus the special PowerMetricCard
    final List<Widget> gridChildren = [];
    for (int i = 0; i < metrics.length; i++) {
      final m = metrics[i];
      // Insert PowerMetricCard after Battery Temp (index 2 -> position 3)
      if (i == 3) {
        gridChildren.add(PowerMetricCard(
          voltage: voltage,
          current: current,
          power: power,
          isCompact: isCompact,
        ));
      }
      gridChildren.add(MetricCard(
        title: m.title,
        value: m.value,
        unit: m.unit,
        icon: m.icon,
        iconColor: m.color,
        isCompact: isCompact,
      ));
    }

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: columns,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: aspectRatio,
      children: gridChildren,
    );
  }

  /// Build compact charging history section for dashboard
  Widget _buildChargingHistorySection(bool isCompact, bool isTablet) {
    if (_isLoadingSessions) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: isTablet ? 16 : 8),
        // Section header with "View All" button
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  Icons.ev_station,
                  size: isTablet ? 20 : 16,
                  color: Colors.grey[600],
                ),
                const SizedBox(width: 8),
                Text(
                  'RECENT CHARGES',
                  style: TextStyle(
                    fontSize: isTablet ? 14 : 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[600],
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ChargingHistoryScreen(),
                  ),
                ).then((_) => _loadRecentSessions()); // Refresh on return
              },
              child: Text(
                'View All',
                style: TextStyle(fontSize: isCompact ? 12 : 14),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Sessions list or empty state
        if (_recentSessions.isEmpty)
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: EdgeInsets.all(isCompact ? 16 : 24),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.ev_station_outlined,
                      size: isCompact ? 32 : 40,
                      color: Colors.grey[400],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'No charging sessions yet',
                      style: TextStyle(
                        fontSize: isCompact ? 12 : 14,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          ...(_recentSessions.map((session) => _buildCompactSessionCard(session, isCompact))),
      ],
    );
  }

  /// Build Fleet Statistics section for dashboard
  Widget _buildFleetStatsSection(bool isCompact, bool isTablet) {
    final fleetService = FleetAnalyticsService.instance;

    // Only show if fleet analytics is enabled
    if (!fleetService.isEnabled) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: isTablet ? 16 : 8),
        // Section header with "View Fleet Data" button
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  Icons.analytics,
                  size: isTablet ? 20 : 16,
                  color: Colors.deepPurple,
                ),
                const SizedBox(width: 8),
                Text(
                  'FLEET STATISTICS',
                  style: TextStyle(
                    fontSize: isTablet ? 14 : 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[600],
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const FleetStatsScreen(),
                  ),
                );
              },
              icon: Icon(Icons.bar_chart, size: isCompact ? 16 : 18),
              label: Text(
                'View Fleet Data',
                style: TextStyle(fontSize: isCompact ? 12 : 14),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Quick stats card - fully tappable
        InkWell(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const FleetStatsScreen(),
              ),
            );
          },
          borderRadius: BorderRadius.circular(12),
          child: Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: EdgeInsets.all(isCompact ? 12 : 16),
              child: Row(
                children: [
                  Icon(
                    Icons.people,
                    size: isCompact ? 28 : 36,
                    color: Colors.deepPurple.withAlpha(180),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Contributing to Fleet Analytics',
                          style: TextStyle(
                            fontSize: isCompact ? 12 : 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Tap to view fleet-wide statistics and compare your vehicle',
                          style: TextStyle(
                            fontSize: isCompact ? 10 : 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: Colors.grey[400],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Build a compact session card for dashboard display
  Widget _buildCompactSessionCard(ChargingSession session, bool isCompact) {
    final isAC = session.chargingType == 'ac';
    final isDC = session.chargingType == 'dc';
    final typeIcon = isDC ? Icons.flash_on : (isAC ? Icons.power : Icons.ev_station);
    final typeColor = isDC ? Colors.orange : (isAC ? Colors.green : Colors.blue);

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: EdgeInsets.all(isCompact ? 10 : 12),
        child: Row(
          children: [
            // Charging type icon
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: typeColor.withAlpha(30),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(typeIcon, color: typeColor, size: isCompact ? 18 : 22),
            ),
            const SizedBox(width: 10),
            // Session info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatSessionDate(session.startTime),
                    style: TextStyle(
                      fontSize: isCompact ? 12 : 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${session.startSoc.toStringAsFixed(0)}% → ${session.endSoc?.toStringAsFixed(0) ?? "--"}%',
                    style: TextStyle(
                      fontSize: isCompact ? 11 : 12,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            // Energy added
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  session.energyAddedKwh != null
                      ? '${session.energyAddedKwh!.toStringAsFixed(1)} kWh'
                      : '${session.energyAddedAh?.toStringAsFixed(1) ?? "--"} Ah',
                  style: TextStyle(
                    fontSize: isCompact ? 12 : 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (session.maxPowerKw != null && session.maxPowerKw! > 0)
                  Text(
                    '${session.maxPowerKw!.toStringAsFixed(0)} kW peak',
                    style: TextStyle(
                      fontSize: isCompact ? 10 : 11,
                      color: Colors.grey[600],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Format session date for compact display
  String _formatSessionDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final sessionDate = DateTime(date.year, date.month, date.day);

    String dateStr;
    if (sessionDate == today) {
      dateStr = 'Today';
    } else if (sessionDate == today.subtract(const Duration(days: 1))) {
      dateStr = 'Yesterday';
    } else {
      dateStr = '${date.day}/${date.month}';
    }

    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$dateStr $hour:$minute';
  }

  /// Build location section
  Widget _buildLocationSection(VehicleData data, bool isCompact, bool isTablet) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: isTablet ? 16 : 8),
        if (isTablet)
          const DashboardSectionHeader(
            title: 'LOCATION',
            icon: Icons.location_on,
          ),
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: EdgeInsets.all(isCompact ? 12 : 16),
            child: Row(
              children: [
                Icon(
                  Icons.location_on,
                  color: Colors.teal,
                  size: isCompact ? 24 : 32,
                ),
                SizedBox(width: isCompact ? 12 : 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${data.latitude!.toStringAsFixed(5)}, ${data.longitude!.toStringAsFixed(5)}',
                        style: TextStyle(
                          fontSize: isCompact ? 14 : 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (data.altitude != null) ...[
                            Icon(Icons.terrain, size: 14, color: Colors.grey[600]),
                            const SizedBox(width: 4),
                            Text(
                              '${data.altitude!.toStringAsFixed(0)}m',
                              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            ),
                            const SizedBox(width: 12),
                          ],
                          if (data.gpsSpeed != null) ...[
                            Icon(Icons.speed, size: 14, color: Colors.grey[600]),
                            const SizedBox(width: 4),
                            Text(
                              '${data.gpsSpeed!.toStringAsFixed(0)} km/h',
                              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            ),
                            const SizedBox(width: 12),
                          ],
                          if (data.heading != null) ...[
                            Icon(Icons.explore, size: 14, color: Colors.grey[600]),
                            const SizedBox(width: 4),
                            Text(
                              '${data.heading!.toStringAsFixed(0)}°',
                              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Build additional PIDs section
  Widget _buildAdditionalPidsSection(
    VehicleData data,
    double screenWidth,
    bool isCompact,
    bool isTablet,
  ) {
    if (data.additionalProperties == null || data.additionalProperties!.isEmpty) {
      return const SizedBox.shrink();
    }

    // PIDs to exclude (shown elsewhere or unsupported)
    const excludedPids = {
      'COOLANT_T',
      'MOTOR_T',
      'DC_CHG_A',
      'DC_CHG_V',
      'CHARGING',
      'RANGE_EST',
    };

    final filteredEntries = data.additionalProperties!.entries
        .where((entry) => !excludedPids.contains(entry.key))
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

    // Get PID configurations for priority lookup
    final manager = ref.watch(dataSourceManagerProvider);
    final pidConfigs = manager.obdService.customPIDs;

    // Create a map of PID name to priority
    final pidPriorityMap = <String, PIDPriority>{};
    for (final pid in pidConfigs) {
      pidPriorityMap[pid.name] = pid.priority;
    }

    final columns = DashboardBreakpoints.getMetricColumns(screenWidth);
    double aspectRatio;
    if (isCompact) {
      aspectRatio = 2.0;
    } else if (columns == 3) {
      aspectRatio = 1.5;
    } else {
      aspectRatio = 1.3;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: isTablet ? 16 : 8),
        if (isTablet)
          const DashboardSectionHeader(
            title: 'ADDITIONAL DATA',
            icon: Icons.analytics,
          ),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: columns,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: aspectRatio,
          children: filteredEntries.map((entry) {
            final value = entry.value is double
                ? (entry.value as double).toStringAsFixed(1)
                : entry.value.toString();
            // Look up priority - default to high if not found
            final priority = pidPriorityMap[entry.key] ?? PIDPriority.high;
            final isLowPriority = priority == PIDPriority.low;
            return MetricCard(
              title: entry.key,
              value: value,
              unit: '',
              isCompact: isCompact,
              // Show priority indicator: small dot for low priority PIDs
              trailing: isLowPriority
                  ? Tooltip(
                      message: 'Low priority: updates every ~5 min',
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          shape: BoxShape.circle,
                        ),
                      ),
                    )
                  : null,
            );
          }).toList(),
        ),
      ],
    );
  }

  /// Format timestamp to human-readable format
  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inSeconds < 5) {
      return 'just now';
    } else if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24 && now.day == timestamp.day) {
      final hour = timestamp.hour.toString().padLeft(2, '0');
      final minute = timestamp.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } else {
      final day = timestamp.day.toString().padLeft(2, '0');
      final month = timestamp.month.toString().padLeft(2, '0');
      final hour = timestamp.hour.toString().padLeft(2, '0');
      final minute = timestamp.minute.toString().padLeft(2, '0');
      return '$day/$month $hour:$minute';
    }
  }

  /// Build service status indicator row
  Widget _buildServiceStatusRow(WidgetRef ref) {
    final mqttService = ref.watch(mqttServiceProvider);
    final manager = ref.watch(dataSourceManagerProvider);
    final proxyService = OBDProxyService.instance;
    final vehicleData = ref.watch(vehicleDataStreamProvider);

    // Determine charging status from vehicle data
    // ONLY use battery current (HV_A) as the indicator - NEGATIVE = charging into battery
    // XPENG convention: negative current = energy flowing into battery (charging)
    //
    // NOTE: CHARGING PID and BMS_CHG_STATUS are IGNORED because they remain active
    // when the charging cable is plugged in but charging has stopped. Only HV_A is reliable.
    bool isCharging = false;
    vehicleData.whenData((data) {
      if (data != null) {
        // ONLY method: check battery current from BMS (HV_A mapped to batteryCurrent)
        // NEGATIVE current = charging into battery (XPENG convention)
        // Use threshold < -0.5A to filter noise
        if (data.batteryCurrent != null && data.batteryCurrent! < -0.5) {
          isCharging = true;
        }
        // DO NOT check CHARGING PID or BMS_CHG_STATUS - they are unreliable
        // They remain active when cable is plugged in but charging has stopped
      }
    });

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        ServiceStatusIndicator(
          icon: Icons.wifi,
          label: 'Internet',
          isActive: _isInternetConnected,
          activeColor: Colors.green,
        ),
        ServiceStatusIndicator(
          icon: Icons.cloud,
          label: 'MQTT',
          isActive: mqttService.isConnected,
          activeColor: Colors.blue,
        ),
        ServiceStatusIndicator(
          icon: Icons.route,
          label: 'ABRP',
          isActive: manager.abrpService.isEnabled,
          activeColor: Colors.orange,
        ),
        ServiceStatusIndicator(
          icon: Icons.cast_connected,
          label: 'Proxy',
          isActive: proxyService.isRunning,
          activeColor: Colors.cyan,
        ),
        ServiceStatusIndicator(
          icon: Icons.vpn_key,
          label: 'VPN',
          isActive: _isVpnActive,
          activeColor: Colors.purple,
        ),
        ServiceStatusIndicator(
          icon: Icons.bolt,
          label: 'Charging',
          isActive: isCharging,
          activeColor: Colors.yellow.shade700,
        ),
        ServiceStatusIndicator(
          icon: Icons.location_on,
          label: 'GPS',
          isActive: manager.isLocationEnabled,
          activeColor: Colors.teal,
        ),
        ServiceStatusIndicator(
          icon: Icons.analytics,
          label: 'Fleet',
          isActive: FleetAnalyticsService.instance.isEnabled,
          activeColor: Colors.deepPurple,
        ),
      ],
    );
  }
}

/// Helper class for metric data
class _MetricData {
  final String title;
  final String value;
  final String unit;
  final IconData icon;
  final Color color;

  const _MetricData(this.title, this.value, this.unit, this.icon, this.color);
}
