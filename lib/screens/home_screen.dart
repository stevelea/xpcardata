import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vehicle_data_provider.dart';
import '../providers/mqtt_provider.dart';
import '../services/data_source_manager.dart';
import '../services/background_service.dart';
import '../services/obd_proxy_service.dart';
import '../services/tailscale_service.dart';
import '../services/connectivity_service.dart';
import '../services/fleet_analytics_service.dart';
import '../services/mock_data_service.dart';
import '../widgets/dashboard_widgets.dart';
import '../models/vehicle_data.dart';
import '../models/charging_session.dart';
import '../models/obd_pid_config.dart';
import 'settings_hub_screen.dart';
import 'charging_history_screen.dart';
import 'fleet_stats_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  static const _lifecycleChannel = MethodChannel('com.example.carsoc/app_lifecycle');

  bool _isVpnActive = false;
  bool _isInternetConnected = false;
  bool _mqttHeartbeatFailed = false;
  StreamSubscription<bool>? _vpnStatusSubscription;
  StreamSubscription<bool>? _connectivitySubscription;
  StreamSubscription<bool>? _mqttHeartbeatSubscription;
  StreamSubscription<ChargingSession>? _sessionSubscription;
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

    // Listen for MQTT heartbeat status changes
    final mqttService = ref.read(mqttServiceProvider);
    _mqttHeartbeatSubscription = mqttService.heartbeatStatusStream.listen((success) {
      if (mounted) {
        setState(() {
          _mqttHeartbeatFailed = !success;
        });
      }
    });

    // Load recent charging sessions
    _loadRecentSessions();

    // Listen for charging session updates to refresh the list
    final manager = ref.read(dataSourceManagerProvider);
    _sessionSubscription = manager.chargingSessionService.sessionStream.listen((session) {
      // Refresh sessions when a session is updated (started, ended, etc.)
      _loadRecentSessions();
    });

    // Register to listen for app lifecycle changes (refresh when app comes to foreground)
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh sessions when app comes back to foreground
    if (state == AppLifecycleState.resumed) {
      _loadRecentSessions();
    }
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
    WidgetsBinding.instance.removeObserver(this);
    _vpnStatusSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _mqttHeartbeatSubscription?.cancel();
    _sessionSubscription?.cancel();
    TailscaleService.instance.stopStatusMonitoring();
    ConnectivityService.instance.stopMonitoring();
    super.dispose();
  }

  /// Minimize the app to background (keeps services running)
  Future<void> _minimizeApp() async {
    try {
      await _lifecycleChannel.invokeMethod('moveToBackground');
    } catch (e) {
      debugPrint('Failed to minimize app: $e');
    }
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
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('XPCarData'),
            if (MockDataService.instance.isEnabled) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'MOCK',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingsHubScreen(),
                ),
              );
            },
            tooltip: 'Settings',
          ),
          IconButton(
            icon: const Icon(Icons.minimize),
            onPressed: _minimizeApp,
            tooltip: 'Minimize',
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

                  // 12V Battery Protection Warning Banner
                  _build12VProtectionWarning(),

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

  /// Build 12V battery protection warning banner (flashing red)
  Widget _build12VProtectionWarning() {
    final manager = ref.watch(dataSourceManagerProvider);

    if (!manager.isAuxBatteryProtectionActive) {
      return const SizedBox.shrink();
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 500),
      builder: (context, value, child) {
        // Create a pulsing effect
        final opacity = 0.7 + 0.3 * (0.5 + 0.5 * (value < 0.5 ? value * 2 : (1 - value) * 2));
        return Opacity(
          opacity: opacity,
          child: child,
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.red.shade700,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.red.withOpacity(0.4),
              blurRadius: 8,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          children: [
            const _FlashingIcon(
              icon: Icons.battery_alert,
              color: Colors.white,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '12V BATTERY PROTECTION ACTIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'OBD polling paused to protect 12V battery',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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
          case DataSource.mock:
            sourceName = 'Mock Data';
            icon = Icons.science;
            color = Colors.orange;
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

        // Charging details section (when charging)
        _buildChargingDetailsSection(data, isCompact, isTablet),

        // Additional PIDs section
        _buildAdditionalPidsSection(data, screenWidth, isCompact, isTablet),
      ],
    );
  }

  /// Build primary metrics (SOC and Speed - the two most important real-time metrics)
  /// Layout is reversed for LHD countries (driver on left, so important info on left)
  Widget _buildPrimaryMetrics(
    VehicleData data,
    double? estimatedRange,
    bool isCompact,
    bool isLargeTablet,
  ) {
    final theme = Theme.of(context);
    final manager = ref.watch(dataSourceManagerProvider);
    final isLhd = manager.isLeftHandDrive;

    // Battery SOC card
    final batteryCard = Expanded(
      child: PrimaryMetricCard(
        title: 'Battery',
        value: data.stateOfCharge?.toStringAsFixed(1) ?? '--',
        unit: '%',
        backgroundColor: theme.colorScheme.primaryContainer,
        isCompact: isCompact,
      ),
    );

    // Speed card
    final speedCard = Expanded(
      child: PrimaryMetricCard(
        title: 'Speed',
        value: data.speed?.toStringAsFixed(0) ?? '--',
        unit: 'km/h',
        backgroundColor: theme.colorScheme.secondaryContainer,
        isCompact: isCompact,
      ),
    );

    final spacer = SizedBox(width: isCompact ? 8 : 12);

    // LHD: Speed on left (closer to driver), Battery on right
    // RHD: Battery on left, Speed on right (closer to driver)
    return Row(
      children: isLhd
          ? [speedCard, spacer, batteryCard]
          : [batteryCard, spacer, speedCard],
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

    // 12V auxiliary battery voltage
    final auxVoltage = data.additionalProperties?['AUX_V'] as double?;
    final auxVoltageStr = auxVoltage?.toStringAsFixed(1) ?? '--';
    // Color based on 12V voltage level
    final auxVoltageColor = auxVoltage == null
        ? Colors.grey
        : auxVoltage < 12.0
            ? Colors.red
            : auxVoltage < 12.5
                ? Colors.orange
                : Colors.green;

    final metrics = [
      // Guestimated Range moved from primary display (swapped with Speed)
      _MetricData('Guestimated Range', estimatedRange?.toStringAsFixed(0) ?? '--', 'km', Icons.route, Colors.green),
      _MetricData('State of Health', data.stateOfHealth?.toStringAsFixed(1) ?? '--', '%', Icons.health_and_safety, Colors.teal),
      _MetricData('Battery Temp', data.batteryTemperature?.toStringAsFixed(1) ?? '--', '°C', Icons.thermostat, Colors.orange),
      _MetricData('12V Battery', auxVoltageStr, 'V', Icons.battery_full, auxVoltageColor),
      _MetricData('Cell ΔV', cellVoltageDelta, 'mV', Icons.battery_std, Colors.cyan),
      _MetricData('Odometer', data.odometer?.toStringAsFixed(0) ?? '--', 'km', Icons.straighten, Colors.blueGrey),
    ];

    // Build list of widgets - regular MetricCards plus the special PowerMetricCard
    final List<Widget> gridChildren = [];
    for (int i = 0; i < metrics.length; i++) {
      final m = metrics[i];
      // Insert PowerMetricCard after Battery Temp (index 2), before 12V Battery (index 3)
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

  /// Build charging details section (shows DC/AC charging PIDs when charging)
  Widget _buildChargingDetailsSection(VehicleData data, bool isCompact, bool isTablet) {
    // Get charging-related PIDs from additionalProperties
    final dcChgA = data.additionalProperties?['DC_CHG_A'];
    final dcChgV = data.additionalProperties?['DC_CHG_V'];
    final acChgA = data.additionalProperties?['AC_CHG_A'];
    final acChgV = data.additionalProperties?['AC_CHG_V'];

    // Check if we're charging (stationary with negative current or charging PIDs active)
    final isStationary = data.speed == null || data.speed! < 1.0;
    final hasNegativeCurrent = data.batteryCurrent != null && data.batteryCurrent! < -0.5;
    final hasDcCharging = dcChgA != null && dcChgA is num && dcChgA > 10;
    final hasAcCharging = acChgA != null && acChgA is num && acChgA > 1;

    // Only show if charging is detected
    if (!isStationary || (!hasNegativeCurrent && !hasDcCharging && !hasAcCharging)) {
      return const SizedBox.shrink();
    }

    // Calculate charging power
    double? dcPowerKw;
    double? acPowerKw;

    if (hasDcCharging && dcChgV != null && dcChgV is num) {
      dcPowerKw = (dcChgA * dcChgV) / 1000.0;
    }
    if (hasAcCharging && acChgV != null && acChgV is num) {
      acPowerKw = (acChgA * acChgV) / 1000.0;
    }

    // Determine charging type
    final bool isDcCharging = hasDcCharging && (dcPowerKw ?? 0) > 11.0;
    final bool isAcCharging = hasAcCharging && !isDcCharging;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: isTablet ? 16 : 8),
        if (isTablet)
          DashboardSectionHeader(
            title: isDcCharging ? 'DC CHARGING' : (isAcCharging ? 'AC CHARGING' : 'CHARGING'),
            icon: Icons.ev_station,
          ),
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: EdgeInsets.all(isCompact ? 12 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.ev_station,
                      color: isDcCharging ? Colors.orange : Colors.green,
                      size: isCompact ? 24 : 28,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isDcCharging ? 'DC Fast Charging' : (isAcCharging ? 'AC Charging' : 'Charging'),
                      style: TextStyle(
                        fontSize: isCompact ? 16 : 18,
                        fontWeight: FontWeight.bold,
                        color: isDcCharging ? Colors.orange : Colors.green,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Show DC charging details
                if (hasDcCharging) ...[
                  _buildChargingRow(
                    'DC Current',
                    '${(dcChgA as num).toStringAsFixed(1)} A',
                    isCompact,
                  ),
                  if (dcChgV != null)
                    _buildChargingRow(
                      'DC Voltage',
                      '${(dcChgV as num).toStringAsFixed(0)} V',
                      isCompact,
                    ),
                  if (dcPowerKw != null)
                    _buildChargingRow(
                      'DC Power',
                      '${dcPowerKw.toStringAsFixed(1)} kW',
                      isCompact,
                      highlight: true,
                    ),
                ],
                // Show AC charging details
                if (hasAcCharging) ...[
                  if (hasDcCharging) const Divider(),
                  _buildChargingRow(
                    'AC Current',
                    '${(acChgA as num).toStringAsFixed(1)} A',
                    isCompact,
                  ),
                  if (acChgV != null)
                    _buildChargingRow(
                      'AC Voltage',
                      '${(acChgV as num).toStringAsFixed(0)} V',
                      isCompact,
                    ),
                  if (acPowerKw != null)
                    _buildChargingRow(
                      'AC Power',
                      '${acPowerKw.toStringAsFixed(1)} kW',
                      isCompact,
                      highlight: true,
                    ),
                ],
                // Show battery current if no specific charger current
                if (!hasDcCharging && !hasAcCharging && hasNegativeCurrent) ...[
                  _buildChargingRow(
                    'Battery Current',
                    '${data.batteryCurrent!.toStringAsFixed(1)} A',
                    isCompact,
                  ),
                  if (data.power != null)
                    _buildChargingRow(
                      'Power',
                      '${data.power!.abs().toStringAsFixed(1)} kW',
                      isCompact,
                      highlight: true,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Helper to build a row in the charging section
  Widget _buildChargingRow(String label, String value, bool isCompact, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: isCompact ? 14 : 15,
              color: Colors.grey[600],
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: isCompact ? 14 : 15,
              fontWeight: highlight ? FontWeight.bold : FontWeight.w500,
              color: highlight ? Colors.green[700] : null,
            ),
          ),
        ],
      ),
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
  /// For LHD: status icons are reversed so settings/status are on left (driver side)
  Widget _buildServiceStatusRow(WidgetRef ref) {
    final mqttService = ref.watch(mqttServiceProvider);
    final manager = ref.watch(dataSourceManagerProvider);
    final proxyService = OBDProxyService.instance;
    final vehicleData = ref.watch(vehicleDataStreamProvider);
    final isLhd = manager.isLeftHandDrive;

    // Determine charging status from vehicle data
    // ONLY use battery current (HV_A) as the indicator - NEGATIVE = charging into battery
    // XPENG convention: negative current = energy flowing into battery (charging)
    //
    // NOTE: CHARGING PID and BMS_CHG_STATUS are IGNORED because they remain active
    // when the charging cable is plugged in but charging has stopped. Only HV_A is reliable.
    //
    // IMPORTANT: Also require vehicle to be stationary (speed < 1.0 km/h) to distinguish
    // actual charging from regenerative braking which also produces negative current.
    bool isCharging = false;
    vehicleData.whenData((data) {
      if (data != null) {
        // Check battery current from BMS (HV_A mapped to batteryCurrent)
        // NEGATIVE current = charging into battery (XPENG convention)
        // Use threshold < -0.5A to filter noise
        // ALSO require vehicle to be stationary to filter out regenerative braking
        final isStationary = data.speed == null || data.speed! < 1.0;
        if (isStationary && data.batteryCurrent != null && data.batteryCurrent! < -0.5) {
          isCharging = true;
        }
        // DO NOT check CHARGING PID or BMS_CHG_STATUS - they are unreliable
        // They remain active when cable is plugged in but charging has stopped
      }
    });

    // Build list of status indicators
    final indicators = <Widget>[
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
        hasError: _mqttHeartbeatFailed,
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
    ];

    // LHD: reverse order so status/settings icons are on left (driver side)
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: isLhd ? indicators.reversed.toList() : indicators,
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

/// Flashing icon widget for alerts
class _FlashingIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _FlashingIcon({
    required this.icon,
    required this.color,
    this.size = 24,
  });

  @override
  State<_FlashingIcon> createState() => _FlashingIconState();
}

class _FlashingIconState extends State<_FlashingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.3, end: 1.0).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Opacity(
          opacity: _animation.value,
          child: Icon(
            widget.icon,
            color: widget.color,
            size: widget.size,
          ),
        );
      },
    );
  }
}
