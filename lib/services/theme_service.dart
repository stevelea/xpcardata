import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_themes.dart';
import 'debug_logger.dart';
import 'hive_storage_service.dart';

/// Service for managing app theme preferences
/// Uses Hive for persistence (works on AI boxes)
class ThemeService extends ChangeNotifier {
  static final ThemeService _instance = ThemeService._internal();
  static ThemeService get instance => _instance;
  ThemeService._internal();

  static final _logger = DebugLogger.instance;
  static const String _themeKey = 'app_theme_mode';

  AppThemeMode _currentTheme = AppThemeMode.system;
  bool _initialized = false;

  /// Current theme mode
  AppThemeMode get currentTheme => _currentTheme;

  /// Whether the service has been initialized
  bool get isInitialized => _initialized;

  /// Initialize the theme service and load saved preference
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _logger.log('[ThemeService] Initializing...');

      // Try to load from Hive first
      final hive = HiveStorageService.instance;
      if (hive.isAvailable) {
        final savedTheme = hive.getSetting<String>(_themeKey);
        if (savedTheme != null) {
          _currentTheme = _parseThemeMode(savedTheme);
          _logger.log('[ThemeService] Loaded theme from Hive: $_currentTheme');
        }
      } else {
        // Fallback to file-based storage
        final theme = await _loadFromFile();
        if (theme != null) {
          _currentTheme = theme;
          _logger.log('[ThemeService] Loaded theme from file: $_currentTheme');
        }
      }

      _initialized = true;
      _logger.log('[ThemeService] Initialized with theme: $_currentTheme');
    } catch (e) {
      _logger.log('[ThemeService] Initialization error: $e');
      _initialized = true; // Mark as initialized even on error
    }
  }

  /// Set the theme mode and persist it
  Future<void> setTheme(AppThemeMode theme) async {
    if (_currentTheme == theme) return;

    _logger.log('[ThemeService] Changing theme from $_currentTheme to $theme');
    _currentTheme = theme;
    notifyListeners();

    // Persist to Hive
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting(_themeKey, theme.name);
      _logger.log('[ThemeService] Saved theme to Hive');
    }

    // Also save to file as backup
    await _saveToFile(theme);
  }

  /// Get the appropriate ThemeData based on current mode
  ThemeData getThemeData(Brightness systemBrightness) {
    return AppThemes.getTheme(_currentTheme, systemBrightness);
  }

  /// Get the ThemeMode for MaterialApp
  ThemeMode getThemeMode() {
    return AppThemes.getThemeMode(_currentTheme);
  }

  /// Parse theme mode from string
  AppThemeMode _parseThemeMode(String value) {
    switch (value.toLowerCase()) {
      case 'light':
        return AppThemeMode.light;
      case 'dark':
        return AppThemeMode.dark;
      case 'xpeng':
        return AppThemeMode.xpeng;
      case 'system':
      default:
        return AppThemeMode.system;
    }
  }

  /// Load theme from file (fallback for when Hive isn't available)
  Future<AppThemeMode?> _loadFromFile() async {
    try {
      final paths = [
        '/data/data/com.example.carsoc/files/theme_preference.txt',
        '/data/data/com.stevelea.carsoc/files/theme_preference.txt',
        '/data/user/0/com.example.carsoc/files/theme_preference.txt',
        '/data/user/0/com.stevelea.carsoc/files/theme_preference.txt',
      ];

      for (final path in paths) {
        try {
          final file = File(path);
          if (await file.exists()) {
            final content = await file.readAsString();
            return _parseThemeMode(content.trim());
          }
        } catch (_) {
          // Continue to next path
        }
      }
    } catch (e) {
      _logger.log('[ThemeService] Error loading from file: $e');
    }
    return null;
  }

  /// Save theme to file (backup storage)
  Future<void> _saveToFile(AppThemeMode theme) async {
    try {
      final paths = [
        '/data/data/com.example.carsoc/files/theme_preference.txt',
        '/data/data/com.stevelea.carsoc/files/theme_preference.txt',
        '/data/user/0/com.example.carsoc/files/theme_preference.txt',
        '/data/user/0/com.stevelea.carsoc/files/theme_preference.txt',
      ];

      for (final path in paths) {
        try {
          final file = File(path);
          final parent = file.parent;
          if (await parent.exists()) {
            await file.writeAsString(theme.name);
            _logger.log('[ThemeService] Saved theme to file: $path');
            return;
          }
        } catch (_) {
          // Continue to next path
        }
      }
    } catch (e) {
      _logger.log('[ThemeService] Error saving to file: $e');
    }
  }
}
