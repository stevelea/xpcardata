import 'package:flutter_test/flutter_test.dart';

import 'package:carsoc/services/settings_reader.dart';

/// The app's settings screens read **Hive first, SharedPreferences second**
/// (`connections_settings_screen.dart`). The web view must use the same order or
/// it shows an empty MQTT broker on devices where SharedPreferences cannot be
/// opened — the mismatch reported against v1.4.25.
void main() {
  SettingsReader reader({
    Map<String, Object?>? prefs,
    Map<String, Object?>? hive,
  }) {
    return SettingsReader(
      prefsLoader: () async => prefs,
      hiveLoader: (key) => hive?[key],
      hiveAvailable: hive != null,
    );
  }

  group('source precedence', () {
    test('Hive wins over SharedPreferences', () async {
      final r = reader(
        prefs: {'mqtt_broker': 'from-prefs.local'},
        hive: {'mqtt_broker': 'from-hive.local'},
      );
      expect(await r.string('mqtt_broker'), 'from-hive.local');
    });

    test('falls back to SharedPreferences when Hive has no value', () async {
      final r = reader(
        prefs: {'mqtt_broker': 'from-prefs.local'},
        hive: {'unrelated': true},
      );
      expect(await r.string('mqtt_broker'), 'from-prefs.local');
    });

    test('falls back to SharedPreferences when Hive is unavailable', () async {
      // AI box: SharedPreferences works, Hive box not opened yet.
      final r = reader(prefs: {'mqtt_port': 1883}, hive: null);
      expect(await r.integer('mqtt_port'), 1883);
    });

    test('returns null when neither store has the key', () async {
      final r = reader(prefs: {}, hive: {});
      expect(await r.string('mqtt_broker'), isNull);
      expect(await r.integer('mqtt_port'), isNull);
    });
  });

  group('type coercion', () {
    test('numeric strings are parsed for int and double settings', () async {
      final r = reader(hive: {'mqtt_port': '8883', 'aux_threshold': '12.4'});
      expect(await r.integer('mqtt_port'), 8883);
      expect(await r.real('aux_threshold'), 12.4);
    });

    test('num is accepted for int settings', () async {
      final r = reader(hive: {'update_frequency_seconds': 2.0});
      expect(await r.integer('update_frequency_seconds'), 2);
    });

    test('boolean strings are parsed', () async {
      final r = reader(hive: {'mqtt_enabled': 'true', 'ha_discovery_enabled': 'false'});
      expect(await r.boolean('mqtt_enabled'), isTrue);
      expect(await r.boolean('ha_discovery_enabled'), isFalse);
    });

    test('double settings accept ints', () async {
      final r = reader(hive: {'alert_low_battery': 15});
      expect(await r.real('alert_low_battery'), 15.0);
    });
  });

  group('availability', () {
    test('hasStore is true when SharedPreferences answered', () async {
      final r = reader(prefs: {}, hive: null);
      expect(await r.hasStore, isTrue);
    });

    test('hasStore is true when only Hive is available', () async {
      final r = reader(prefs: null, hive: {});
      expect(await r.hasStore, isTrue);
    });

    test('hasStore is false when neither store answered', () async {
      final r = reader(prefs: null, hive: null);
      expect(await r.hasStore, isFalse);
    });
  });
}
