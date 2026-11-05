import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    test('static UI files stay public so the browser can load the page', () async {
      final (status, _, _) = await get('/');
      expect(status, 200);
    });
  });
}
