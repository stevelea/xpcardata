import 'package:shared_preferences/shared_preferences.dart';

import 'hive_storage_service.dart';

/// Reads app settings the same way the settings screens do.
///
/// The screens (`connections_settings_screen.dart`, `app_settings_screen.dart`)
/// read **Hive first and SharedPreferences second**, because AI boxes cannot open
/// the SharedPreferences channel at all (`PlatformException channel-error`).
/// The web server originally read SharedPreferences only, so on those devices
/// `/api/settings` showed empty brokers/ports while the app showed the real
/// values. This reader exists so both views come from one ordering.
///
/// Both sources are injectable for tests; production uses [defaultPrefsLoader]
/// and [defaultHiveLoader].
class SettingsReader {
  SettingsReader({
    Future<Map<String, Object?>?> Function()? prefsLoader,
    Object? Function(String key)? hiveLoader,
    bool? hiveAvailable,
  })  : _prefsLoader = prefsLoader ?? defaultPrefsLoader,
        _hiveLoader = hiveLoader ?? defaultHiveLoader,
        _hiveAvailable = hiveAvailable ?? HiveStorageService.instance.isAvailable;

  final Future<Map<String, Object?>?> Function() _prefsLoader;
  final Object? Function(String key) _hiveLoader;
  final bool _hiveAvailable;

  Map<String, Object?>? _prefs;
  bool _prefsLoaded = false;

  /// Snapshot every key SharedPreferences holds, or null when the channel is
  /// unavailable (AI boxes). Reading the whole store once is cheaper than one
  /// platform call per key and keeps a single consistent view.
  static Future<Map<String, Object?>?> defaultPrefsLoader() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final values = <String, Object?>{};
      for (final key in prefs.getKeys()) {
        values[key] = prefs.get(key);
      }
      return values;
    } catch (_) {
      return null;
    }
  }

  static Object? defaultHiveLoader(String key) {
    final hive = HiveStorageService.instance;
    if (!hive.isAvailable) return null;
    try {
      return hive.getSetting<Object?>(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureLoaded() async {
    if (_prefsLoaded) return;
    _prefs = await _prefsLoader();
    _prefsLoaded = true;
  }

  Object? _raw(String key) {
    final hiveValue = _hiveLoader(key);
    if (hiveValue != null) return hiveValue;
    return _prefs?[key];
  }

  Future<String?> string(String key) async {
    await _ensureLoaded();
    final value = _raw(key);
    if (value == null) return null;
    return value.toString();
  }

  Future<int?> integer(String key) async {
    await _ensureLoaded();
    final value = _raw(key);
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Future<bool?> boolean(String key) async {
    await _ensureLoaded();
    final value = _raw(key);
    if (value is bool) return value;
    if (value is String) {
      final lower = value.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    return null;
  }

  Future<double?> real(String key) async {
    await _ensureLoaded();
    final value = _raw(key);
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  /// True when at least one settings store answered. Used for the API's
  /// `settingsAvailable` flag so the UI can explain an empty page.
  Future<bool> get hasStore async {
    await _ensureLoaded();
    return _prefs != null || _hiveAvailable;
  }

  bool get hiveAvailable => _hiveAvailable;
}
