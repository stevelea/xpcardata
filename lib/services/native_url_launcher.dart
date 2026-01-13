import 'package:flutter/services.dart';
import 'debug_logger.dart';

/// Native URL launcher for AAOS where url_launcher package doesn't work
/// Uses Android Intent directly via method channel
class NativeUrlLauncher {
  static const _channel = MethodChannel('com.example.carsoc/url_launcher');
  static final _logger = DebugLogger.instance;

  /// Open a URL using native Android Intent
  static Future<bool> openUrl(String url) async {
    try {
      final result = await _channel.invokeMethod<bool>('openUrl', {'url': url});
      _logger.log('[NativeUrlLauncher] openUrl($url): $result');
      return result ?? false;
    } catch (e) {
      _logger.log('[NativeUrlLauncher] openUrl error: $e');
      return false;
    }
  }

  /// Open maps app at a specific location
  /// If label is provided (and not "Home"), searches by name near coordinates
  /// for better results with photos, reviews, etc.
  static Future<bool> openMaps({
    required double latitude,
    required double longitude,
    String? label,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('openMaps', {
        'latitude': latitude,
        'longitude': longitude,
        'label': label,
      });
      _logger.log('[NativeUrlLauncher] openMaps($latitude, $longitude, $label): $result');
      return result ?? false;
    } catch (e) {
      _logger.log('[NativeUrlLauncher] openMaps error: $e');
      return false;
    }
  }
}
