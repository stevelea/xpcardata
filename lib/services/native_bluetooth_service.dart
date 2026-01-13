import 'dart:async';
import 'package:flutter/services.dart';

/// Model for Bluetooth device
class NativeBluetoothDevice {
  final String name;
  final String address;

  NativeBluetoothDevice({required this.name, required this.address});

  factory NativeBluetoothDevice.fromMap(Map<dynamic, dynamic> map) {
    return NativeBluetoothDevice(
      name: map['name'] as String? ?? 'Unknown',
      address: map['address'] as String,
    );
  }

  String get displayName => name.isNotEmpty ? name : address;
}

/// Native Bluetooth service using Method Channel
/// Works on Android 4.4+ (API 19+) including Android 15
class NativeBluetoothService {
  static const MethodChannel _channel = MethodChannel('com.example.carsoc/bluetooth');

  /// Check if app has Bluetooth permissions
  Future<bool> hasPermissions() async {
    try {
      final result = await _channel.invokeMethod<bool>('hasPermissions');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Request Bluetooth permissions
  Future<bool> requestPermissions() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermissions');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Check if Bluetooth is supported on this device
  Future<bool> isBluetoothSupported() async {
    try {
      final result = await _channel.invokeMethod<bool>('isBluetoothSupported');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Check if Bluetooth is currently enabled
  Future<bool> isBluetoothEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('isBluetoothEnabled');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Get list of paired Bluetooth devices
  Future<List<NativeBluetoothDevice>> getPairedDevices() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getPairedDevices');
      if (result == null) return [];

      return result.map((device) => NativeBluetoothDevice.fromMap(device as Map<dynamic, dynamic>)).toList();
    } catch (e) {
      rethrow;
    }
  }

  /// Connect to a Bluetooth device by address
  Future<bool> connect(String address) async {
    try {
      final result = await _channel.invokeMethod<bool>('connect', {'address': address});
      return result ?? false;
    } catch (e) {
      rethrow;
    }
  }

  /// Disconnect from current Bluetooth device
  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      // Ignore disconnect errors
    }
  }

  /// Check if currently connected to a device
  Future<bool> isConnected() async {
    try {
      final result = await _channel.invokeMethod<bool>('isConnected');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Send data to connected device
  Future<void> sendData(Uint8List data) async {
    try {
      await _channel.invokeMethod('sendData', {'data': data});
    } catch (e) {
      rethrow;
    }
  }

  /// Send text to connected device
  Future<void> sendText(String text) async {
    final data = Uint8List.fromList(text.codeUnits);
    await sendData(data);
  }

  /// Read data from connected device
  Future<Uint8List> readData({int bufferSize = 1024}) async {
    try {
      final result = await _channel.invokeMethod<Uint8List>('readData', {'bufferSize': bufferSize});
      return result ?? Uint8List(0);
    } catch (e) {
      rethrow;
    }
  }

  /// Check how many bytes are available to read
  Future<int> readAvailable() async {
    try {
      final result = await _channel.invokeMethod<int>('readAvailable');
      return result ?? 0;
    } catch (e) {
      return 0;
    }
  }
}
