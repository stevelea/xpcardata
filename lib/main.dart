import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/database_service.dart';
import 'services/hive_storage_service.dart';
import 'services/data_usage_service.dart';
import 'services/background_service.dart';
import 'services/tailscale_service.dart';
import 'services/fleet_analytics_service.dart';
import 'services/debug_logger.dart';
import 'services/theme_service.dart';
import 'services/open_charge_map_service.dart';
import 'services/mock_data_service.dart';
import 'providers/vehicle_data_provider.dart';
import 'providers/mqtt_provider.dart';
import 'screens/home_screen.dart';
import 'theme/app_themes.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase (non-blocking - let it fail gracefully)
  try {
    final firebaseApp = await Firebase.initializeApp();
    print('Firebase initialized: ${firebaseApp.name}, project: ${firebaseApp.options.projectId}');
  } catch (e, stackTrace) {
    print('Firebase initialization failed: $e');
    print('Stack trace: $stackTrace');
    print('App will continue without fleet analytics');
  }

  // Initialize debug logger settings
  try {
    await DebugLogger.instance.initialize();
  } catch (e) {
    print('DebugLogger initialization failed: $e');
  }

  // Initialize FleetAnalyticsService (separate from Firebase so prefs still load)
  try {
    await FleetAnalyticsService.instance.initialize();
    print('FleetAnalyticsService initialized: enabled=${FleetAnalyticsService.instance.isEnabled}');
  } catch (e) {
    print('FleetAnalyticsService initialization failed: $e');
  }

  // Initialize Hive storage (lightweight NoSQL - best for AI boxes)
  try {
    final hiveInitialized = await HiveStorageService.instance.initialize();
    print('Hive storage initialized: $hiveInitialized');
  } catch (e) {
    print('Hive initialization failed: $e');
    print('App will continue without Hive persistence');
  }

  // Initialize theme service (uses Hive for persistence)
  try {
    await ThemeService.instance.initialize();
    print('ThemeService initialized: ${ThemeService.instance.currentTheme}');
  } catch (e) {
    print('ThemeService initialization failed: $e');
  }

  // Initialize SQLite database (non-blocking - let it fail gracefully)
  try {
    await DatabaseService.instance.database;
    print('SQLite database initialized');
  } catch (e) {
    print('SQLite initialization failed: $e');
    print('App will continue without SQLite persistence');
  }

  // Initialize data usage tracking
  await DataUsageService.instance.initialize();

  // Initialize Open Charge Map service (for station lookups and home location)
  try {
    await OpenChargeMapService.instance.initialize();
    print('OpenChargeMapService initialized');
  } catch (e) {
    print('OpenChargeMapService initialization failed: $e');
  }

  // Initialize Mock Data service (for testing without car connection)
  try {
    await MockDataService.instance.initialize();
    print('MockDataService initialized: enabled=${MockDataService.instance.isEnabled}');
  } catch (e) {
    print('MockDataService initialization failed: $e');
  }

  // Initialize background service (non-blocking - let it fail gracefully)
  try {
    await BackgroundServiceManager.instance.initialize();
  } catch (e) {
    print('Background service initialization failed: $e');
    print('App will continue without background service');
  }

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  static const _lifecycleChannel = MethodChannel('com.example.carsoc/app_lifecycle');
  Timer? _obdReconnectTimer;
  String? _lastObdAddress;
  bool _hasCheckedStartMinimised = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Schedule initialization after the first frame to ensure plugins are ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeDataSource();
      _checkStartMinimised();
    });
  }

  /// Check if "Start Minimised" setting is enabled and minimize the app if so.
  /// Only runs once per app launch to avoid minimizing on resume.
  Future<void> _checkStartMinimised() async {
    if (_hasCheckedStartMinimised) return;
    _hasCheckedStartMinimised = true;

    // First check if we were already started minimised via BootReceiver
    // (in which case MainActivity already handled it)
    try {
      final wasStartedMinimised = await _lifecycleChannel.invokeMethod<bool>('wasStartedMinimised');
      if (wasStartedMinimised == true) {
        print('App was started minimised via BootReceiver, skipping');
        return;
      }
    } catch (e) {
      print('Failed to check wasStartedMinimised: $e');
    }

    // Check if start_minimised setting is enabled
    bool startMinimised = false;

    // Try file-based settings first (more reliable on AI boxes)
    final settings = await _loadSettingsFromFile();
    if (settings != null) {
      startMinimised = settings['start_minimised'] ?? false;
    } else {
      // Fall back to SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        startMinimised = prefs.getBool('start_minimised') ?? false;
      } catch (e) {
        print('Failed to load start_minimised from SharedPreferences: $e');
      }
    }

    if (startMinimised) {
      print('Start Minimised enabled, moving app to background');
      // Small delay to ensure UI is fully rendered before minimizing
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        await _lifecycleChannel.invokeMethod('moveToBackground');
      } catch (e) {
        print('Failed to move app to background: $e');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _obdReconnectTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final manager = ref.read(dataSourceManagerProvider);

    if (state == AppLifecycleState.resumed) {
      // Re-verify OBD connection when app comes to foreground
      if (manager.obdService.isConnected) {
        // Refresh data source to ensure data collection continues
        manager.initialize();
      }
    }
  }

  Future<void> _initializeDataSource() async {
    final manager = ref.read(dataSourceManagerProvider);
    await manager.initialize();

    // Restore location tracking if it was enabled
    await manager.restoreLocationSetting();

    // Restore drive layout setting (LHD/RHD)
    await manager.restoreDriveLayoutSetting();

    // Auto-connect Tailscale VPN if enabled (before MQTT)
    await _initializeTailscale();

    // Auto-connect MQTT if enabled in settings
    await _initializeMqtt();

    // Initialize ABRP if enabled in settings
    await _initializeAbrp();

    // Auto-connect OBD Bluetooth if previously connected
    await _initializeObd();
  }

  Future<void> _initializeTailscale() async {
    Map<String, dynamic>? settings;

    // Try to load settings from file first (more reliable)
    settings = await _loadSettingsFromFile();

    // If file failed, try SharedPreferences
    bool tailscaleAutoConnect = false;
    if (settings != null) {
      tailscaleAutoConnect = settings['tailscale_auto_connect'] ?? false;
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        tailscaleAutoConnect = prefs.getBool('tailscale_auto_connect') ?? false;
      } catch (e) {
        print('SharedPreferences failed for Tailscale: $e');
        return;
      }
    }

    if (tailscaleAutoConnect) {
      try {
        final installed = await TailscaleService.instance.isInstalled();
        if (installed) {
          // Use connectWithRetry for more reliable auto-connect
          // This wakes Tailscale first, then sends connect intent, and verifies VPN came up
          final success = await TailscaleService.instance.connectWithRetry(maxAttempts: 3);
          if (success) {
            print('Tailscale VPN connected successfully on startup');
          } else {
            print('Tailscale auto-connect failed after retries - VPN may not be active');
          }
        } else {
          print('Tailscale not installed, skipping auto-connect');
        }
      } catch (e) {
        print('Tailscale auto-connect error: $e');
      }
    }
  }

  Future<void> _initializeObd() async {
    Map<String, dynamic>? settings;

    // Try to load settings from file first (more reliable)
    settings = await _loadSettingsFromFile();

    // Check if OBD auto-connect is enabled (default: true)
    bool obdAutoConnect = true;
    if (settings != null) {
      obdAutoConnect = settings['obd_auto_connect'] ?? true;
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        obdAutoConnect = prefs.getBool('obd_auto_connect') ?? true;
      } catch (e) {
        print('SharedPreferences failed for OBD: $e');
      }
    }

    if (obdAutoConnect) {
      // Get saved device address for retry logic - try SharedPreferences first, then file
      try {
        final prefs = await SharedPreferences.getInstance();
        _lastObdAddress = prefs.getString('last_obd_address');
        print('OBD: SharedPrefs last_obd_address: $_lastObdAddress');
      } catch (e) {
        print('OBD: SharedPreferences failed: $e');
      }

      // Try file-based settings as fallback
      if (_lastObdAddress == null || _lastObdAddress!.isEmpty) {
        if (settings != null && settings['last_obd_address'] != null) {
          _lastObdAddress = settings['last_obd_address'] as String?;
          print('OBD: File settings last_obd_address: $_lastObdAddress');
        }
      }

      // Give plugins extra time to initialize before OBD auto-connect
      await Future.delayed(const Duration(seconds: 2));
      print('OBD: Starting auto-connect after delay');

      try {
        final manager = ref.read(dataSourceManagerProvider);
        final connected = await manager.obdService.autoConnect();
        if (connected) {
          print('OBD auto-connected on startup');
          // Re-initialize to pick up OBD as data source
          await manager.initialize();
          // Stop retry timer if running
          _obdReconnectTimer?.cancel();
          _obdReconnectTimer = null;
        } else {
          print('OBD auto-connect: no previous device or connection failed');
          // Start periodic retry if we have a saved device
          _startObdReconnectTimer();
        }
      } catch (e) {
        print('OBD auto-connect failed: $e');
        // Start periodic retry if we have a saved device
        _startObdReconnectTimer();
      }
    }
  }

  /// Start a periodic timer to retry OBD connection every 60 seconds
  void _startObdReconnectTimer() {
    // Only start if we have a saved device and timer isn't already running
    if (_lastObdAddress == null || _lastObdAddress!.isEmpty) {
      print('OBD reconnect: no saved device address');
      return;
    }

    if (_obdReconnectTimer != null) {
      return; // Timer already running
    }

    print('OBD reconnect: starting 60-second retry timer for $_lastObdAddress');

    _obdReconnectTimer = Timer.periodic(const Duration(seconds: 60), (timer) async {
      try {
        final manager = ref.read(dataSourceManagerProvider);

        // Check if already connected
        if (manager.obdService.isConnected) {
          print('OBD reconnect: already connected, stopping timer');
          timer.cancel();
          _obdReconnectTimer = null;
          return;
        }

        print('OBD reconnect: attempting connection to $_lastObdAddress');
        final connected = await manager.obdService.autoConnect();

        if (connected) {
          print('OBD reconnect: connection successful!');
          // Re-initialize to pick up OBD as data source
          await manager.initialize();
          timer.cancel();
          _obdReconnectTimer = null;
        } else {
          print('OBD reconnect: connection failed, will retry in 60 seconds');
        }
      } catch (e) {
        print('OBD reconnect error: $e');
      }
    });
  }

  Future<void> _initializeAbrp() async {
    bool abrpEnabled = false;
    String abrpToken = '';
    String abrpCarModel = 'xpeng:g6:23:87:other';
    int abrpInterval = 60;

    // Try Hive first (works on AI boxes)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      abrpEnabled = hive.getSetting<bool>('abrp_enabled') ?? false;
      abrpToken = hive.getSetting<String>('abrp_token') ?? '';
      abrpCarModel = hive.getSetting<String>('abrp_car_model') ?? 'xpeng:g6:23:87:other';
      abrpInterval = hive.getSetting<int>('abrp_interval_seconds') ?? 60;
      if (abrpToken.isNotEmpty) {
        print('ABRP settings loaded from Hive');
      }
    }

    // Fall back to file storage if Hive didn't have settings
    if (abrpToken.isEmpty) {
      final settings = await _loadSettingsFromFile();
      if (settings != null) {
        abrpEnabled = settings['abrp_enabled'] ?? false;
        abrpToken = settings['abrp_token'] ?? '';
        abrpCarModel = settings['abrp_car_model'] ?? 'xpeng:g6:23:87:other';
        abrpInterval = settings['abrp_interval_seconds'] ?? 60;
        if (abrpToken.isNotEmpty) {
          print('ABRP settings loaded from file');
        }
      }
    }

    // Fall back to SharedPreferences as last resort
    if (abrpToken.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        abrpEnabled = prefs.getBool('abrp_enabled') ?? false;
        abrpToken = prefs.getString('abrp_token') ?? '';
        abrpCarModel = prefs.getString('abrp_car_model') ?? 'xpeng:g6:23:87:other';
        abrpInterval = prefs.getInt('abrp_interval_seconds') ?? 60;
        if (abrpToken.isNotEmpty) {
          print('ABRP settings loaded from SharedPreferences');
        }
      } catch (e) {
        print('SharedPreferences failed for ABRP: $e');
      }
    }

    if (abrpEnabled && abrpToken.isNotEmpty) {
      try {
        final manager = ref.read(dataSourceManagerProvider);
        manager.abrpService.configure(
          token: abrpToken,
          carModel: abrpCarModel,
          enabled: true,
        );
        // Apply ABRP update interval
        manager.abrpService.setUpdateInterval(abrpInterval);
        print('ABRP configured on startup with ${abrpInterval}s interval');
      } catch (e) {
        print('ABRP configuration failed: $e');
      }
    }
  }

  Future<void> _initializeMqtt() async {
    Map<String, dynamic>? settings;

    // Try Hive first (most reliable on AAOS devices)
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      final mqttEnabled = hive.getSetting<bool>('mqtt_enabled');
      if (mqttEnabled != null) {
        settings = {
          'mqtt_enabled': mqttEnabled,
          'mqtt_broker': hive.getSetting<String>('mqtt_broker') ?? 'mqtt.eclipseprojects.io',
          'mqtt_port': hive.getSetting<int>('mqtt_port') ?? 1883,
          'mqtt_vehicle_id': hive.getSetting<String>('mqtt_vehicle_id') ?? 'vehicle_001',
          'mqtt_username': hive.getSetting<String>('mqtt_username'),
          'mqtt_password': hive.getSetting<String>('mqtt_password'),
          'mqtt_use_tls': hive.getSetting<bool>('mqtt_use_tls') ?? false,
          'ha_discovery_enabled': hive.getSetting<bool>('ha_discovery_enabled') ?? false,
        };
        print('MQTT settings loaded from Hive');
      }
    }

    // Fall back to file storage
    if (settings == null) {
      settings = await _loadSettingsFromFile();
      if (settings != null && settings['mqtt_enabled'] == true) {
        print('MQTT settings loaded from file');
      }
    }

    // Fall back to SharedPreferences as last resort
    if (settings == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        settings = {
          'mqtt_enabled': prefs.getBool('mqtt_enabled') ?? false,
          'mqtt_broker': prefs.getString('mqtt_broker') ?? 'mqtt.eclipseprojects.io',
          'mqtt_port': prefs.getInt('mqtt_port') ?? 1883,
          'mqtt_vehicle_id': prefs.getString('mqtt_vehicle_id') ?? 'vehicle_001',
          'mqtt_username': prefs.getString('mqtt_username'),
          'mqtt_password': prefs.getString('mqtt_password'),
          'mqtt_use_tls': prefs.getBool('mqtt_use_tls') ?? false,
          'ha_discovery_enabled': prefs.getBool('ha_discovery_enabled') ?? false,
        };
        if (settings['mqtt_enabled'] == true) {
          print('MQTT settings loaded from SharedPreferences');
        }
      } catch (e) {
        print('SharedPreferences failed: $e');
        return;
      }
    }

    final mqttEnabled = settings['mqtt_enabled'] ?? false;
    if (mqttEnabled) {
      try {
        final mqttService = ref.read(mqttServiceProvider);
        final broker = settings['mqtt_broker'] ?? 'mqtt.eclipseprojects.io';
        final port = settings['mqtt_port'] ?? 1883;
        final vehicleId = settings['mqtt_vehicle_id'] ?? 'vehicle_001';
        final username = settings['mqtt_username'];
        final password = settings['mqtt_password'];
        final useTLS = settings['mqtt_use_tls'] ?? false;
        final haDiscoveryEnabled = settings['ha_discovery_enabled'] ?? false;

        // Set HA discovery before connecting so it publishes on connect
        mqttService.haDiscoveryEnabled = haDiscoveryEnabled;

        await mqttService.connect(
          broker: broker,
          port: port,
          vehicleId: vehicleId,
          username: username?.toString().isNotEmpty == true ? username : null,
          password: password?.toString().isNotEmpty == true ? password : null,
          useTLS: useTLS,
        );
        print('MQTT auto-connected on startup (HA Discovery: $haDiscoveryEnabled)');
      } catch (e) {
        print('MQTT auto-connect failed: $e');
      }
    }
  }

  Future<Map<String, dynamic>?> _loadSettingsFromFile() async {
    try {
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/app_settings.json';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/app_settings.json';
      }

      final file = File(filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (e) {
      print('Failed to load settings from file: $e');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Use ListenableBuilder to rebuild when theme changes
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, child) {
        final themeService = ThemeService.instance;
        final currentTheme = themeService.currentTheme;

        // For XPENG theme, use custom theme data
        // For others, use standard light/dark themes
        final ThemeData lightTheme;
        final ThemeData darkTheme;
        final ThemeMode themeMode;

        if (currentTheme == AppThemeMode.xpeng) {
          // XPENG theme uses custom light theme
          lightTheme = AppThemes.xpengLight;
          darkTheme = AppThemes.xpengDark;
          themeMode = ThemeMode.light; // XPENG always uses light
        } else {
          // Standard themes
          lightTheme = AppThemes.light;
          darkTheme = AppThemes.dark;
          themeMode = themeService.getThemeMode();
        }

        return MaterialApp(
          title: 'XPCarData - Vehicle Battery Monitor',
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          home: const HomeScreen(),
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: .center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
