import 'package:flutter/services.dart';
import '../models/vehicle_data.dart';

/// Method channel bridge for Flutter ↔ Android Auto communication
class CarAppBridge {
  static const MethodChannel _channel = MethodChannel('com.example.carsoc/car_app');

  /// Update vehicle data in Android Auto
  /// Sends the current vehicle data to the native Android side
  /// which updates the VehicleDataStore and triggers UI refresh
  static Future<bool> updateVehicleData(VehicleData data) async {
    try {
      final result = await _channel.invokeMethod('updateVehicleData', data.toMap());
      return result as bool? ?? false;
    } on PlatformException {
      // Handle error silently
      return false;
    }
  }

  /// Request refresh of Android Auto display
  /// Forces the Android Auto UI to update
  static Future<bool> requestRefresh() async {
    try {
      final result = await _channel.invokeMethod('requestRefresh');
      return result as bool? ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Check if Android Auto is currently connected
  /// Returns true if the car display is active
  static Future<bool> isCarConnected() async {
    try {
      final result = await _channel.invokeMethod('isCarConnected');
      return result as bool? ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Get current vehicle data from Android side
  /// Useful for syncing data from native storage
  static Future<VehicleData?> getCurrentData() async {
    try {
      final result = await _channel.invokeMethod('getCurrentData');
      if (result != null && result is Map) {
        return VehicleData.fromMap(Map<String, dynamic>.from(result));
      }
      return null;
    } on PlatformException {
      return null;
    }
  }
}
