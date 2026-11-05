import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'debug_logger.dart';

/// Tiny JSON-file key/value store used when both SharedPreferences and Hive are
/// unavailable.
///
/// AI boxes (Carlinkit, Ottocast) fail every pigeon plugin channel — seen in the
/// field log as `PlatformException(channel-error … SharedPreferencesApi.getAll)`
/// — and Hive needs a path_provider directory, which fails on the same devices.
/// The app data directory itself is always writable, so this store keeps
/// settings that must survive a restart (the web server's enabled state, port
/// and token) in `app_settings.json` next to the charging-session file.
class SimpleJsonStore {
  SimpleJsonStore({
    this.fileName = 'app_settings.json',
    Future<String?> Function()? directoryResolver,
  }) : _directoryResolver = directoryResolver;

  final String fileName;
  final Future<String?> Function()? _directoryResolver;
  final _logger = DebugLogger.instance;

  String? _cachedDirectory;
  bool _directoryResolved = false;

  /// Resolve a writable directory, mirroring the fallback chain already used by
  /// the charging-session persistence (external → documents → temp → hardcoded
  /// app data path).
  Future<String?> _directory() async {
    if (_directoryResolved) return _cachedDirectory;
    _directoryResolved = true;

    final custom = _directoryResolver;
    if (custom != null) {
      _cachedDirectory = await custom();
      return _cachedDirectory;
    }

    try {
      final dir = await getExternalStorageDirectory();
      if (dir != null) {
        _cachedDirectory = dir.path;
        return _cachedDirectory;
      }
    } catch (e) {
      _logger.log('[SettingsFile] getExternalStorageDirectory failed: $e');
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      _cachedDirectory = dir.path;
      return _cachedDirectory;
    } catch (e) {
      _logger.log('[SettingsFile] getApplicationDocumentsDirectory failed: $e');
    }

    try {
      final dir = await getTemporaryDirectory();
      _cachedDirectory = dir.path;
      return _cachedDirectory;
    } catch (e) {
      _logger.log('[SettingsFile] getTemporaryDirectory failed: $e');
    }

    // Last resort on Android 10+: the app's own files directory.
    _cachedDirectory = '/data/data/com.example.carsoc/files';
    return _cachedDirectory;
  }

  Future<File?> _file() async {
    final dir = await _directory();
    if (dir == null) return null;
    return File('$dir/$fileName');
  }

  /// Read the stored map. Returns an empty map when the file is missing,
  /// unreadable or corrupt — settings callers must never crash on this.
  Future<Map<String, dynamic>> load() async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return {};
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      return decoded;
    } catch (e) {
      _logger.log('[SettingsFile] Could not read settings file: $e');
      return {};
    }
  }

  /// Merge [values] into the file and write it back. Returns true on success.
  Future<bool> save(Map<String, Object?> values) async {
    try {
      final file = await _file();
      if (file == null) return false;

      final current = await load();
      current.addAll(values.map((key, value) => MapEntry(key, value)));

      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      await file.writeAsString(jsonEncode(current), flush: true);
      return true;
    } catch (e) {
      _logger.log('[SettingsFile] Could not write settings file: $e');
      return false;
    }
  }
}
