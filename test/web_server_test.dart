import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:carsoc/services/settings_reader.dart';
import 'package:carsoc/services/web_server_service.dart';

/// Integration tests for the embedded remote-view HTTP server: static UI
/// assets, JSON API, token auth and 404 handling, over a real loopback socket.
void main() {
  final service = WebServerService.instance;
  late int port;

  Future<(int, String, String)> get(
    String path, {
    String? token,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
      if (token != null) {
        request.headers.set('x-token', token);
      }
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final contentType = response.headers.contentType?.mimeType ?? '';
      return (response.statusCode, contentType, body);
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    service.assetLoaderOverride = (path) async => switch (path) {
          'assets/web/index.html' => '<html>INDEX</html>',
          'assets/web/app.css' => 'body{}',
          'assets/web/app.js' => '// js',
          'assets/web/favicon.svg' => '<svg/>',
          'docs/MANUAL.md' => '# Manual\n\nBody text.',
          _ => throw Exception('unknown asset $path'),
        };
    service.snapshotOverride = () async => {
          'server': {'version': '1.4.24', 'port': port},
          'data': null,
          'dataAgeSeconds': null,
        };
    service.sessionsOverride = (limit) async => [
          {'id': 's1', 'energyAddedKwh': 12.5, 'isActive': false},
        ];
    service.logsOverride = () => List.generate(5, (i) => 'log line $i');
    service.settingsOverride = () async => {
          'vehicle': {'model': 'G6_24LR', 'customCapacityKwh': null},
          'mqtt': {'enabled': true, 'broker': 'homeassistant.local', 'port': 1883, 'passwordSet': true},
          'remoteAccess': {'enabled': true, 'running': true, 'port': port, 'tokenRequired': false},
        };
    service.fleetOverride = () async => {'enabled': false, 'stats': null};

    final started = await service.start(
      portOverride: 0,
      address: InternetAddress.loopbackIPv4,
    );
    expect(started, isTrue, reason: 'server should bind an ephemeral port');
    port = service.port;
  });

  tearDown(() async {
    await service.stop();
    await service.setToken('');
    service.assetLoaderOverride = null;
    service.snapshotOverride = null;
    service.sessionsOverride = null;
    service.logsOverride = null;
    service.settingsOverride = null;
    service.fleetOverride = null;
    service.settingsReaderOverride = null;
  });

  test('serves the web UI at / with an html content type', () async {
    final (status, type, body) = await get('/');
    expect(status, 200);
    expect(type, 'text/html');
    expect(body, contains('INDEX'));
  });

  test('serves CSS and JS assets', () async {
    final css = await get('/app.css');
    expect(css.$1, 200);
    expect(css.$2, 'text/css');

    final js = await get('/app.js');
    expect(js.$1, 200);
    expect(js.$2, 'application/javascript');
  });

  test('unknown paths return 404 with a link back to the UI', () async {
    final (status, type, body) = await get('/nope');
    expect(status, 404);
    expect(type, 'text/html');
    expect(body, contains('href="/"'));
  });

  test('/api/health reports liveness and version', () async {
    final (status, _, body) = await get('/api/health');
    expect(status, 200);
    final json = jsonDecode(body) as Map<String, dynamic>;
    expect(json['ok'], isTrue);
    expect(json['running'], isTrue);
    expect(json['port'], port);
    expect(json['version'], isNotEmpty);
  });

  test('/api/state returns the snapshot payload', () async {
    final (status, type, body) = await get('/api/state');
    expect(status, 200);
    expect(type, 'application/json');
    final json = jsonDecode(body) as Map<String, dynamic>;
    expect(json['server'], isA<Map<String, dynamic>>());
    expect(json.containsKey('data'), isTrue);
  });

  test('/api/sessions returns session JSON', () async {
    final (status, _, body) = await get('/api/sessions?limit=5');
    expect(status, 200);
    final json = jsonDecode(body) as Map<String, dynamic>;
    expect(json['sessions'], hasLength(1));
    expect(json['sessions'][0]['id'], 's1');
  });

  test('/api/logs honours the limit parameter and clamps it', () async {
    final limited = await get('/api/logs?limit=2');
    expect(jsonDecode(limited.$3)['logs'], hasLength(2));

    final clamped = await get('/api/logs?limit=99999');
    expect(jsonDecode(clamped.$3)['logs'], hasLength(5));
  });

  group('settings, manual and fleet endpoints', () {
    test('/api/settings returns the redacted snapshot', () async {
      final (status, type, body) = await get('/api/settings');
      expect(status, 200);
      expect(type, 'application/json');
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['vehicle']['model'], 'G6_24LR');
      expect(json['mqtt']['passwordSet'], isTrue);
      // Credentials must never be serialized.
      expect(body, isNot(contains('mqtt_password')));
      expect(body, isNot(contains('abrp_token')));
    });

    test('/api/settings never leaks the web access token value', () async {
      await service.setToken('secret-token');
      final (status, _, body) = await get('/api/settings', token: 'secret-token');
      expect(status, 200);
      expect(body, isNot(contains('secret-token')));
      await service.setToken('');
    });

    test('/api/manual serves the bundled markdown', () async {
      final (status, _, body) = await get('/api/manual');
      expect(status, 200);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['manual'], contains('# Manual'));
    });

    test('/api/fleet reports the opt-in state', () async {
      final (status, _, body) = await get('/api/fleet');
      expect(status, 200);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['enabled'], isFalse);
    });
  });

  group('settings snapshot follows the app lookup order', () {
    test('Hive values win over SharedPreferences (AI-box case)', () async {
      service.settingsOverride = null;
      service.settingsReaderOverride = SettingsReader(
        prefsLoader: () async => {'mqtt_broker': 'from-prefs.local', 'mqtt_port': 1883},
        hiveLoader: (key) => {
              'mqtt_broker': 'homeassistant.local',
              'mqtt_port': 8883,
              'mqtt_enabled': true,
              'mqtt_use_tls': true,
              'ha_discovery_enabled': true,
              'mqtt_reconnect_interval': 30,
              'vehicle_model': 'G9_LR_AWD',
            }[key],
        hiveAvailable: true,
      );

      final json = jsonDecode((await get('/api/settings')).$3) as Map<String, dynamic>;
      expect(json['settingsAvailable'], isTrue);
      expect(json['mqtt']['broker'], 'homeassistant.local');
      expect(json['mqtt']['port'], 8883);
      expect(json['mqtt']['reconnectIntervalSeconds'], 30);
      expect(json['mqtt']['enabled'], isTrue);
      expect(json['vehicle']['model'], 'G9_LR_AWD');
      expect(json['tailscale'], isA<Map<String, dynamic>>());
      expect(json['obdProxy'], isA<Map<String, dynamic>>());
      expect(json['bm300'], isA<Map<String, dynamic>>());
      service.settingsReaderOverride = null;
    });

    test('settingsAvailable is false when no store answers', () async {
      service.settingsOverride = null;
      service.settingsReaderOverride = SettingsReader(
        prefsLoader: () async => null,
        hiveLoader: (key) => null,
        hiveAvailable: false,
      );

      final json = jsonDecode((await get('/api/settings')).$3) as Map<String, dynamic>;
      expect(json['settingsAvailable'], isFalse);
      expect(json['mqtt']['port'], 8883, reason: 'app default port');
      service.settingsReaderOverride = null;
    });
  });

  group('default providers', () {
    test('settingsSnapshot works without injected overrides', () async {
      service.settingsOverride = null;
      final snapshot = await service.settingsSnapshot();
      expect(snapshot['vehicle'], isA<Map>());
      expect(snapshot['mqtt'], isA<Map>());
      expect(snapshot['remoteAccess']['running'], isTrue);
      expect(snapshot['app']['version'], isNotEmpty);
    });

    test('fleetSnapshot never throws when analytics is unavailable', () async {
      service.fleetOverride = null;
    service.settingsReaderOverride = null;
      final snapshot = await service.fleetSnapshot();
      expect(snapshot.containsKey('enabled'), isTrue);
      expect(snapshot.containsKey('stats'), isTrue);
    });
  });

  group('token authentication', () {
    setUp(() async => service.setToken('secret-token'));

    test('rejects API calls without a token', () async {
      final (status, _, body) = await get('/api/state');
      expect(status, 401);
      expect(jsonDecode(body)['error'], 'unauthorized');
    });

    test('accepts the token as a header', () async {
      final (status, _, _) = await get('/api/state', token: 'secret-token');
      expect(status, 200);
    });

    test('accepts the token as a query parameter', () async {
      final (status, _, _) = await get('/api/health?token=secret-token');
      expect(status, 200);
    });

    test('covers the settings and manual endpoints too', () async {
      expect((await get('/api/settings')).$1, 401);
      expect((await get('/api/manual')).$1, 401);
      expect((await get('/api/fleet')).$1, 401);
      expect((await get('/api/settings', token: 'secret-token')).$1, 200);
    });

    test('static UI files stay public so the browser can load the page', () async {
      final (status, _, _) = await get('/');
      expect(status, 200);
    });
  });
}
