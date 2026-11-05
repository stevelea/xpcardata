import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vehicle_data.dart';
import 'data_source_manager.dart';
import 'debug_logger.dart';
import 'bm300_battery_service.dart';
import 'fleet_analytics_service.dart';
import 'github_update_service.dart';
import 'obd_proxy_service.dart';
import 'tailscale_service.dart';
import 'hive_storage_service.dart';
import 'settings_reader.dart';
import 'simple_json_store.dart';

typedef WebAssetLoader = Future<String> Function(String assetPath);
typedef WebSnapshotProvider = Future<Map<String, dynamic>> Function();
typedef WebSessionsProvider = Future<List<Map<String, dynamic>>> Function(int limit);
typedef WebLogsProvider = List<String> Function();
typedef WebSettingsProvider = Future<Map<String, dynamic>> Function();
typedef WebFleetProvider = Future<Map<String, dynamic>> Function();

/// Embedded HTTP server that exposes the app's dashboard, live PID values,
/// charging history and debug log to a browser on the LAN or Tailscale.
///
/// The JSON served by `/api/state` is exactly [VehicleData.toJson], i.e. the
/// same payload the app publishes to MQTT, so every field shown in the phone UI
/// (and every value Home Assistant sees) is available to the web UI without a
/// second, drifting mapping.
///
/// Routes:
///   GET /                 web UI (assets/web/index.html)
///   GET /app.css /app.js  static UI assets
///   GET /api/state        server info + latest VehicleData payload
///   GET /api/sessions     recent charging sessions (?limit=, default 20)
///   GET /api/logs         debug log tail (?limit=, default 200)
///   GET /api/health       liveness probe
///
/// Authentication: when a non-empty token is configured, every `/api/*` request
/// must supply it as the `x-token` header or the `token` query parameter.
/// Static UI files stay public so the browser can load the app before the user
/// enters a token.
class WebServerService {
  WebServerService._();

  static final WebServerService instance = WebServerService._();

  static const String _prefEnabled = 'webServerEnabled';
  static const String _prefPort = 'webServerPort';
  static const String _prefToken = 'webServerToken';
  static const int defaultPort = 8080;

  final _logger = DebugLogger.instance;

  HttpServer? _server;
  bool _enabled = false;
  int _port = defaultPort;
  String _token = '';
  String? _lastError;
  DateTime? _startedAt;

  DataSourceManager? _manager;
  StreamSubscription<VehicleData>? _dataSubscription;
  VehicleData? _latest;
  DateTime? _latestAt;

  // Injection points used by tests (unset in production).
  WebAssetLoader? assetLoaderOverride;
  WebSnapshotProvider? snapshotOverride;
  WebSessionsProvider? sessionsOverride;
  WebLogsProvider? logsOverride;
  WebSettingsProvider? settingsOverride;
  WebFleetProvider? fleetOverride;
  SettingsReader? settingsReaderOverride;
  SimpleJsonStore? fileStoreOverride;

  bool get isRunning => _server != null;
  bool get isEnabled => _enabled;
  int get port => _port;
  String get token => _token;
  String? get lastError => _lastError;
  DateTime? get startedAt => _startedAt;
  VehicleData? get latestData => _latest;
  DateTime? get latestDataAt => _latestAt;

  /// Load persisted settings and attach to [manager] (if given). Starts the
  /// server when it was enabled in a previous session.
  Future<void> initialize({DataSourceManager? manager}) async {
    await _loadSettings();
    if (manager != null) {
      attach(manager);
    }
    if (_enabled) {
      await start();
    }
  }

  /// Subscribe to the live data stream. Safe to call repeatedly; the provider
  /// that owns [DataSourceManager] may recreate it.
  void attach(DataSourceManager manager) {
    _manager = manager;
    _dataSubscription?.cancel();
    _dataSubscription = manager.vehicleDataStream.listen(
      (data) {
        _latest = data;
        _latestAt = DateTime.now();
      },
      onError: (Object error) => _logger.log('[WebServer] Data stream error: $error'),
    );
  }

  /// Load persisted remote-access settings.
  ///
  /// Order of truth: the JSON file (written on every change, works everywhere),
  /// then SharedPreferences, then Hive, then defaults. On AI boxes the prefs and
  /// Hive channels fail outright, which is why the file is authoritative.
  Future<void> _loadSettings() async {
    final file = await _settingsFile();
    if (file != null) {
      final values = await file.load();
      if (values.containsKey(_prefEnabled) ||
          values.containsKey(_prefPort) ||
          values.containsKey(_prefToken)) {
        _enabled = values[_prefEnabled] as bool? ?? false;
        _port = (values[_prefPort] as num?)?.toInt() ?? defaultPort;
        _token = values[_prefToken] as String? ?? '';
        _logger.log('[WebServer] Settings loaded from $fileName (port=$_port, enabled=$_enabled)');
        return;
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefEnabled) ?? false;
      _port = prefs.getInt(_prefPort) ?? defaultPort;
      _token = prefs.getString(_prefToken) ?? '';
      return;
    } catch (e) {
      _logger.log('[WebServer] SharedPreferences unavailable, trying Hive: $e');
    }

    try {
      final hive = HiveStorageService.instance;
      if (hive.isAvailable) {
        _enabled = hive.getSetting<bool>(_prefEnabled) ?? false;
        _port = hive.getSetting<int>(_prefPort) ?? defaultPort;
        _token = hive.getSetting<String>(_prefToken) ?? '';
        _logger.log('[WebServer] Settings restored from Hive (port=$_port, enabled=$_enabled)');
        return;
      }
    } catch (e) {
      _logger.log('[WebServer] Hive settings unavailable too: $e');
    }

    _logger.log('[WebServer] No settings store available, using defaults');
    _enabled = false;
    _port = defaultPort;
    _token = '';
  }

  static const String fileName = 'app_settings.json';

  Future<SimpleJsonStore?> _settingsFile() async {
    final override = fileStoreOverride;
    if (override != null) return override;
    try {
      return SimpleJsonStore(fileName: fileName);
    } catch (e) {
      _logger.log('[WebServer] Settings file store unavailable: $e');
      return null;
    }
  }

  /// Persist to every store that answers. The JSON file is written last and is
  /// what survives on devices where the plugin channels are broken.
  Future<void> _persistSettings() async {
    final values = <String, Object?>{
      _prefEnabled: _enabled,
      _prefPort: _port,
      _prefToken: _token,
    };

    var persisted = false;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefEnabled, _enabled);
      await prefs.setInt(_prefPort, _port);
      await prefs.setString(_prefToken, _token);
      persisted = true;
    } catch (e) {
      _logger.log('[WebServer] Could not persist to SharedPreferences: $e');
    }

    try {
      final hive = HiveStorageService.instance;
      if (hive.isAvailable) {
        await hive.saveSetting(_prefEnabled, _enabled);
        await hive.saveSetting(_prefPort, _port);
        await hive.saveSetting(_prefToken, _token);
        persisted = true;
      }
    } catch (e) {
      _logger.log('[WebServer] Could not persist to Hive: $e');
    }

    final file = await _settingsFile();
    if (file != null) {
      final ok = await file.save(values);
      if (ok) {
        persisted = true;
        _logger.log('[WebServer] Settings saved to $fileName');
      }
    }

    if (!persisted) {
      _logger.log('[WebServer] No persistent store available; web server settings are session-only');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await _persistSettings();
    if (enabled) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> setPort(int port) async {
    if (port < 0 || port > 65535) return;
    _port = port;
    await _persistSettings();
    if (isRunning) {
      await stop();
      await start();
    }
  }

  Future<void> setToken(String token) async {
    _token = token.trim();
    await _persistSettings();
  }

  /// Bind the HTTP server. Returns true when listening.
  ///
  /// [portOverride] and [address] exist for tests (ephemeral port / loopback).
  Future<bool> start({int? portOverride, InternetAddress? address}) async {
    if (isRunning) return true;

    final listenPort = portOverride ?? _port;
    try {
      _server = await HttpServer.bind(
        address ?? InternetAddress.anyIPv4,
        listenPort == 0 ? 0 : listenPort,
        shared: true,
      );
      _port = _server!.port;
      _startedAt = DateTime.now();
      _lastError = null;

      _server!.listen(
        (request) => unawaited(_handleRequest(request)),
        onError: (Object error) => _logger.log('[WebServer] Socket error: $error'),
        cancelOnError: false,
      );

      _logger.log('[WebServer] Listening on port $_port');
      for (final url in await getUrls()) {
        _logger.log('[WebServer] Available at $url');
      }
      return true;
    } catch (e) {
      _server = null;
      _lastError = '$e';
      _logger.log('[WebServer] Failed to start on port $listenPort: $e');
      return false;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _startedAt = null;
    try {
      await server?.close(force: true);
      if (server != null) {
        _logger.log('[WebServer] Stopped');
      }
    } catch (e) {
      _logger.log('[WebServer] Error stopping: $e');
    }
  }

  /// Base URLs reachable from other devices (all non-loopback IPv4 addresses).
  Future<List<String>> getUrls() async {
    final urls = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          urls.add('http://${address.address}:$_port');
        }
      }
    } catch (e) {
      _logger.log('[WebServer] Could not enumerate interfaces: $e');
    }
    urls.sort();
    return urls;
  }

  /// Snapshot served by `/api/state`.
  Future<Map<String, dynamic>> snapshot() async {
    final override = snapshotOverride;
    if (override != null) return override();

    final data = _latest;
    final now = DateTime.now();
    return {
      'server': {
        'version': appVersion,
        'running': isRunning,
        'port': _port,
        'startedAt': _startedAt?.toIso8601String(),
        'uptimeSeconds': _startedAt == null ? 0 : now.difference(_startedAt!).inSeconds,
        'source': _manager?.currentSource?.name,
        'authRequired': _token.isNotEmpty,
        'serverTime': now.toIso8601String(),
      },
      'data': data?.toJson(),
      'dataAgeSeconds': _latestAt == null ? null : now.difference(_latestAt!).inSeconds,
    };
  }

  Future<List<Map<String, dynamic>>> _sessions(int limit) async {
    final override = sessionsOverride;
    if (override != null) return override(limit);

    final manager = _manager;
    if (manager == null) return const [];
    try {
      final sessions = await manager.chargingSessionService.getRecentSessions(limit: limit);
      return sessions.map((s) => s.toJson()).toList();
    } catch (e) {
      _logger.log('[WebServer] Could not read sessions: $e');
      return const [];
    }
  }

  List<String> _logs(int limit) {
    final override = logsOverride;
    if (override != null) return override().take(limit).toList();

    final logs = _logger.getLogs();
    final start = logs.length > limit ? logs.length - limit : 0;
    return logs.sublist(start);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;

    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Referrer-Policy', 'no-referrer');

    try {
      if (path.startsWith('/api/')) {
        // Same-origin UI, but allow other tools (curl from a laptop) too.
        response.headers.set('Access-Control-Allow-Origin', '*');
        response.headers.set('Access-Control-Allow-Headers', 'x-token');
        if (request.method == 'OPTIONS') {
          response.statusCode = HttpStatus.noContent;
          await response.close();
          return;
        }
        if (!_isAuthorized(request)) {
          response.statusCode = HttpStatus.unauthorized;
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({'error': 'unauthorized', 'authRequired': true}));
          await response.close();
          return;
        }
        await _handleApi(request, path, response);
        return;
      }

      await _serveStatic(path, response);
    } catch (e, stack) {
      _logger.log('[WebServer] $path failed: $e\n$stack');
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'error': 'server_error', 'message': '$e'}));
        await response.close();
      } catch (_) {
        // Response already closed.
      }
    }
  }

  bool _isAuthorized(HttpRequest request) {
    if (_token.isEmpty) return true;
    final supplied = request.headers.value('x-token') ?? request.uri.queryParameters['token'];
    return supplied == _token;
  }

  Future<void> _handleApi(HttpRequest request, String path, HttpResponse response) async {
    response.headers.contentType = ContentType.json;
    response.headers.set('Cache-Control', 'no-store');

    switch (path) {
      case '/api/state':
        response.write(jsonEncode(await snapshot()));
        break;
      case '/api/sessions':
        final limit = _intParam(request, 'limit', 20, 1, 200);
        final sessions = await _sessions(limit);
        response.write(jsonEncode({'sessions': sessions}));
        break;
      case '/api/logs':
        final limit = _intParam(request, 'limit', 200, 1, 2000);
        response.write(jsonEncode({'logs': _logs(limit)}));
        break;
      case '/api/settings':
        response.write(jsonEncode(await settingsSnapshot()));
        break;
      case '/api/manual':
        response.write(jsonEncode({'manual': await _manualMarkdown()}));
        break;
      case '/api/fleet':
        response.write(jsonEncode(await fleetSnapshot()));
        break;
      case '/api/health':
        response.write(jsonEncode({
          'ok': true,
          'running': isRunning,
          'port': _port,
          'version': appVersion,
          'authRequired': _token.isNotEmpty,
        }));
        break;
      default:
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({'error': 'not_found', 'path': path}));
    }

    await response.close();
  }

  /// Read-only, redacted view of the app's settings.
  ///
  /// Values come through [SettingsReader], which uses the *same* lookup order
  /// as the app's settings screens (Hive, then SharedPreferences). Reading only
  /// SharedPreferences here used to show an empty broker/port on devices where
  /// that channel is unavailable, even though the app showed the real values.
  ///
  /// Credentials (MQTT password, ABRP token, backup keys, web token) are never
  /// serialized — only booleans such as `passwordSet`/`tokenRequired`.
  Future<Map<String, dynamic>> settingsSnapshot() async {
    final override = settingsOverride;
    if (override != null) return override();

    final reader = settingsReaderOverride ?? SettingsReader();

    final model = await reader.string('vehicle_model') ?? 'G6';
    final customCapacity = await reader.real('custom_battery_capacity_kwh');

    final mqttEnabled = await reader.boolean('mqtt_enabled') ?? false;
    final broker = await reader.string('mqtt_broker');
    final port = await reader.integer('mqtt_port') ?? 8883;
    final username = await reader.string('mqtt_username');
    final password = await reader.string('mqtt_password');
    final vehicleId = await reader.string('mqtt_vehicle_id');
    final tls = await reader.boolean('mqtt_use_tls') ?? true;
    final haDiscovery = await reader.boolean('ha_discovery_enabled') ?? false;
    final reconnectSeconds = await reader.integer('mqtt_reconnect_interval') ?? 0;

    bool tailscaleInstalled = false;
    try {
      tailscaleInstalled = await TailscaleService.instance
          .isInstalled()
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      _logger.log('[WebServer] Tailscale install check unavailable: $e');
    }

    final proxy = OBDProxyService.instance;
    final bm300 = BM300BatteryService.instance;

    return {
      'settingsAvailable': await reader.hasStore,
      'vehicle': {
        'model': model,
        'customCapacityKwh': customCapacity,
      },
      'behavior': {
        'updateFrequencySeconds': await reader.integer('update_frequency_seconds') ?? 2,
        'startMinimised': await reader.boolean('start_minimised') ?? false,
        'stayInBackground': await reader.boolean('stay_in_background') ?? false,
        'keepAliveEnabled': await reader.boolean('keep_alive_enabled') ?? false,
        'backgroundServiceEnabled': await reader.boolean('background_service_enabled') ?? false,
        'autoUpdateCheck': await reader.boolean('auto_update_check') ?? false,
        'locationEnabled': await reader.boolean('location_enabled') ?? false,
      },
      'alerts': {
        'lowBatteryPercent': await reader.real('alert_low_battery') ?? 20.0,
        'criticalBatteryPercent': await reader.real('alert_critical_battery') ?? 10.0,
        'highTemperatureCelsius': await reader.real('alert_high_temp') ?? 45.0,
        'auxBatteryProtection': await reader.boolean('aux_battery_protection_enabled') ?? true,
        'auxBatteryThresholdVolts': await reader.real('aux_battery_protection_threshold') ?? 12.0,
      },
      'mqtt': {
        'enabled': mqttEnabled,
        'broker': broker == null || broker.isEmpty ? null : broker,
        'port': port,
        'username': username == null || username.isEmpty ? null : username,
        'passwordSet': (password ?? '').isNotEmpty,
        'tls': tls,
        'vehicleId': vehicleId == null || vehicleId.isEmpty ? null : vehicleId,
        'homeAssistantDiscovery': haDiscovery,
        'reconnectIntervalSeconds': reconnectSeconds,
      },
      'tailscale': {
        'installed': tailscaleInstalled,
        'vpnActive': TailscaleService.instance.isVpnActive,
        'autoConnect': await reader.boolean('tailscale_auto_connect') ?? false,
        'autoReconnect': await reader.boolean('tailscale_auto_reconnect') ?? false,
      },
      'obdProxy': {
        'enabled': proxy.isRunning,
        'port': proxy.port,
        'clientConnected': proxy.clientAddress != null,
      },
      'bm300': {
        'enabled': bm300.isEnabled,
        'connected': bm300.isConnected,
      },
      'abrp': {
        'enabled': await reader.boolean('abrp_enabled') ?? false,
        'tokenConfigured': ((await reader.string('abrp_token')) ?? '').isNotEmpty,
      },
      'remoteAccess': {
        'enabled': isEnabled,
        'running': isRunning,
        'port': _port,
        'tokenRequired': _token.isNotEmpty,
      },
      'app': {'version': appVersion},
    };
  }

  /// Anonymous fleet aggregates (the app's Fleet Stats page). Returns
  /// `enabled: false` when the user has not opted in; never blocks long because
  /// the Firestore query is bounded by a timeout.
  Future<Map<String, dynamic>> fleetSnapshot() async {
    final override = fleetOverride;
    if (override != null) return override();

    final service = FleetAnalyticsService.instance;
    if (!service.isEnabled) {
      return {'enabled': false, 'stats': null};
    }

    try {
      final stats = await service.getFleetStats().timeout(const Duration(seconds: 8));
      if (stats == null) {
        return {'enabled': true, 'stats': null};
      }
      return {
        'enabled': true,
        'stats': {
          'totalContributors': stats.totalContributors,
          'totalContributions': stats.totalContributions,
          'avgSoh': stats.avgSoh,
          'avgChargingPowerAc': stats.avgChargingPowerAc,
          'avgChargingPowerDc': stats.avgChargingPowerDc,
          'sohDistribution': stats.sohDistribution,
          'chargingTypeDistribution': stats.chargingTypeDistribution,
          'countryDistribution': stats.countryDistribution,
          'lastUpdated': stats.lastUpdated.toIso8601String(),
        },
      };
    } catch (e) {
      _logger.log('[WebServer] Fleet stats unavailable: $e');
      return {'enabled': true, 'stats': null, 'error': 'unavailable'};
    }
  }

  /// The in-app manual (docs/MANUAL.md), rendered as plain markdown by the UI.
  String? _manualCache;
  Future<String> _manualMarkdown() async {
    if (_manualCache != null) return _manualCache!;
    final loader = assetLoaderOverride ?? rootBundle.loadString;
    try {
      _manualCache = await loader('docs/MANUAL.md');
    } catch (e) {
      _logger.log('[WebServer] Manual asset unavailable: $e');
      _manualCache = '';
    }
    return _manualCache!;
  }

  int _intParam(HttpRequest request, String name, int fallback, int min, int max) {
    final raw = request.uri.queryParameters[name];
    final value = int.tryParse(raw ?? '') ?? fallback;
    return value.clamp(min, max);
  }

  static const Map<String, String> _staticAssets = {
    '/': 'assets/web/index.html',
    '/index.html': 'assets/web/index.html',
    '/app.css': 'assets/web/app.css',
    '/app.js': 'assets/web/app.js',
    '/favicon.svg': 'assets/web/favicon.svg',
  };

  Future<void> _serveStatic(String path, HttpResponse response) async {
    final assetPath = _staticAssets[path];
    if (assetPath == null) {
      response.statusCode = HttpStatus.notFound;
      response.headers.contentType = ContentType.html;
      response.write('<h1>404</h1><p><a href="/">XPCarData remote view</a></p>');
      await response.close();
      return;
    }

    final loader = assetLoaderOverride ?? rootBundle.loadString;
    final String content;
    try {
      content = await loader(assetPath);
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.headers.contentType = ContentType.text;
      response.write('Missing asset $assetPath: $e');
      await response.close();
      return;
    }

    response.headers.contentType = _contentTypeFor(assetPath);
    response.headers.set('Cache-Control', 'no-cache');
    response.write(content);
    await response.close();
  }

  ContentType _contentTypeFor(String assetPath) {
    if (assetPath.endsWith('.html')) return ContentType.html;
    if (assetPath.endsWith('.css')) return ContentType('text', 'css', charset: 'utf-8');
    if (assetPath.endsWith('.js')) return ContentType('application', 'javascript', charset: 'utf-8');
    if (assetPath.endsWith('.svg')) return ContentType('image', 'svg+xml', charset: 'utf-8');
    return ContentType.text;
  }
}
