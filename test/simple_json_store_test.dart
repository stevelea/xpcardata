import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:carsoc/services/simple_json_store.dart';

/// The remote-access settings must survive a restart even when both plugin-based
/// stores are unavailable (AI boxes: `PlatformException channel-error`).
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('xpcd_settings_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  SimpleJsonStore store() => SimpleJsonStore(
        directoryResolver: () async => tempDir.path,
      );

  group('round trip', () {
    test('saves and loads values', () async {
      final s = store();
      expect(await s.save({'webServerEnabled': true, 'webServerPort': 8080}), isTrue);

      final loaded = await s.load();
      expect(loaded['webServerEnabled'], isTrue);
      expect(loaded['webServerPort'], 8080);
    });

    test('merges with existing keys instead of replacing the file', () async {
      final s = store();
      await s.save({'webServerPort': 8080});
      await s.save({'webServerToken': 'abc'});

      final loaded = await s.load();
      expect(loaded['webServerPort'], 8080);
      expect(loaded['webServerToken'], 'abc');
    });

    test('writes readable JSON on disk', () async {
      final s = store();
      await s.save({'webServerEnabled': true});

      final file = File('${tempDir.path}/app_settings.json');
      expect(await file.exists(), isTrue);
      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(decoded['webServerEnabled'], isTrue);
    });
  });

  group('failure handling', () {
    test('missing file loads as empty map', () async {
      expect(await store().load(), isEmpty);
    });

    test('corrupt file loads as empty map instead of throwing', () async {
      final file = File('${tempDir.path}/app_settings.json');
      await file.writeAsString('{not json');
      expect(await store().load(), isEmpty);
    });

    test('empty file loads as empty map', () async {
      final file = File('${tempDir.path}/app_settings.json');
      await file.writeAsString('');
      expect(await store().load(), isEmpty);
    });

    test('save returns false when no directory can be resolved', () async {
      final s = SimpleJsonStore(directoryResolver: () async => null);
      // The resolver returning null falls through to the plugin path attempt,
      // which is unavailable in tests, so the save cannot succeed.
      expect(await s.save({'a': 1}), isFalse);
    });
  });
}
