import 'dart:async';
import 'package:flutter/services.dart';
import 'debug_logger.dart';
import 'hive_storage_service.dart';

/// Data class for BM300 Pro battery readings
class BM300BatteryData {
  final double voltage;
  final int soc; // State of Charge percentage
  final int temperature; // Celsius
  final DateTime timestamp;

  BM300BatteryData({
    required this.voltage,
    required this.soc,
    required this.temperature,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'BM300: ${voltage.toStringAsFixed(2)}V, $soc%, $temperature°C';
}

/// Service for connecting to Ancel BM300 Pro Bluetooth battery monitor
/// to monitor the 12V auxiliary battery concurrently with OBD-II data
class BM300BatteryService {
  static final BM300BatteryService _instance = BM300BatteryService._internal();
  static BM300BatteryService get instance => _instance;
  BM300BatteryService._internal();

  static const _channel = MethodChannel('com.example.carsoc/bm300');
  final _logger = DebugLogger.instance;

  // State
  bool _isEnabled = false;
  bool _isConnected = false;
  bool _isScanning = false;
  String? _connectedDeviceAddress;
  String? _savedDeviceAddress;
  BM300BatteryData? _lastData;

  // Stream controller for battery data
  final _dataController = StreamController<BM300BatteryData>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _deviceFoundController =
      StreamController<Map<String, String>>.broadcast();

  // Getters
  bool get isEnabled => _isEnabled;
  bool get isConnected => _isConnected;
  bool get isScanning => _isScanning;
  String? get connectedDeviceAddress => _connectedDeviceAddress;
  String? get savedDeviceAddress => _savedDeviceAddress;
  BM300BatteryData? get lastData => _lastData;

  /// Stream of battery data updates
  Stream<BM300BatteryData> get dataStream => _dataController.stream;

  /// Stream of connection state changes
  Stream<bool> get connectionStream => _connectionController.stream;

  /// Stream of discovered devices during scan
  Stream<Map<String, String>> get deviceFoundStream =>
      _deviceFoundController.stream;

  /// Initialize the service
  Future<void> initialize() async {
    _logger.log('[BM300] Initializing...');

    try {
      // Load saved settings
      final hive = HiveStorageService.instance;
      if (hive.isAvailable) {
        _isEnabled = hive.getSetting<bool>('bm300_enabled') ?? false;
        _savedDeviceAddress = hive.getSetting<String>('bm300_device_address');
      }

      // Set up method channel handler for callbacks from native
      _channel.setMethodCallHandler(_handleMethodCall);

      _logger.log(
          '[BM300] Initialized: enabled=$_isEnabled, savedDevice=$_savedDeviceAddress');

      // Auto-connect if enabled and device was previously connected
      // Do this in a non-blocking way to prevent startup crashes
      if (_isEnabled && _savedDeviceAddress != null) {
        _logger.log('[BM300] Scheduling auto-connect to saved device...');
        // Use a longer delay and wrap in try-catch to ensure app doesn't crash
        Future.delayed(const Duration(seconds: 5), () async {
          try {
            if (_isEnabled && _savedDeviceAddress != null && !_isConnected) {
              _logger.log('[BM300] Auto-connecting to $_savedDeviceAddress...');
              await connect(_savedDeviceAddress!);
            }
          } catch (e) {
            _logger.log('[BM300] Auto-connect failed: $e');
          }
        });
      }
    } catch (e) {
      _logger.log('[BM300] Initialization error: $e');
    }
  }

  /// Handle method calls from native code (callbacks)
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onDeviceFound':
        final args = call.arguments as Map<dynamic, dynamic>;
        final device = {
          'name': args['name'] as String,
          'address': args['address'] as String,
        };
        _logger.log('[BM300] Device found: ${device['name']} (${device['address']})');
        _deviceFoundController.add(device);
        break;

      case 'onConnected':
        _isConnected = true;
        _isScanning = false;
        _connectedDeviceAddress = _savedDeviceAddress;
        _connectionController.add(true);
        _logger.log('[BM300] Connected');
        break;

      case 'onDisconnected':
        _isConnected = false;
        _connectedDeviceAddress = null;
        _connectionController.add(false);
        _logger.log('[BM300] Disconnected');

        // Auto-reconnect if enabled
        if (_isEnabled && _savedDeviceAddress != null) {
          _logger.log('[BM300] Scheduling reconnect in 5 seconds...');
          Future.delayed(const Duration(seconds: 5), () {
            if (_isEnabled && !_isConnected && _savedDeviceAddress != null) {
              connect(_savedDeviceAddress!);
            }
          });
        }
        break;

      case 'onDataReceived':
        final args = call.arguments as Map<dynamic, dynamic>;
        final data = BM300BatteryData(
          voltage: (args['voltage'] as num).toDouble(),
          soc: args['soc'] as int,
          temperature: args['temperature'] as int,
        );
        _lastData = data;
        _dataController.add(data);
        _logger.log('[BM300] Data: $data');
        break;

      case 'onError':
        final args = call.arguments as Map<dynamic, dynamic>;
        final message = args['message'] as String;
        _logger.log('[BM300] Error: $message');
        break;
    }
  }

  /// Check if Bluetooth permissions are granted
  Future<bool> hasPermissions() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermissions') ?? false;
    } catch (e) {
      _logger.log('[BM300] Error checking permissions: $e');
      return false;
    }
  }

  /// Check if Bluetooth is enabled
  Future<bool> isBluetoothEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isBluetoothEnabled') ?? false;
    } catch (e) {
      _logger.log('[BM300] Error checking Bluetooth: $e');
      return false;
    }
  }

  /// Enable the BM300 service
  Future<void> enable() async {
    _isEnabled = true;
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting('bm300_enabled', true);
    }
    _logger.log('[BM300] Enabled');
  }

  /// Disable the BM300 service
  Future<void> disable() async {
    _isEnabled = false;
    await disconnect();
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.saveSetting('bm300_enabled', false);
    }
    _logger.log('[BM300] Disabled');
  }

  /// Start scanning for BM300 Pro devices
  Future<void> startScan({int timeoutMs = 10000}) async {
    if (_isScanning) return;

    try {
      _isScanning = true;
      await _channel.invokeMethod('startScan', {'timeout': timeoutMs});
      _logger.log('[BM300] Scan started');
    } catch (e) {
      _isScanning = false;
      _logger.log('[BM300] Scan error: $e');
      rethrow;
    }
  }

  /// Stop scanning
  Future<void> stopScan() async {
    try {
      await _channel.invokeMethod('stopScan');
      _isScanning = false;
      _logger.log('[BM300] Scan stopped');
    } catch (e) {
      _logger.log('[BM300] Stop scan error: $e');
    }
  }

  /// Connect to a BM300 Pro device by address
  Future<void> connect(String address) async {
    if (_isConnected) {
      _logger.log('[BM300] Already connected');
      return;
    }

    try {
      _savedDeviceAddress = address;

      // Save the device address
      final hive = HiveStorageService.instance;
      if (hive.isAvailable) {
        await hive.saveSetting('bm300_device_address', address);
      }

      await _channel.invokeMethod('connect', {'address': address});
      _logger.log('[BM300] Connecting to $address...');
    } catch (e) {
      _logger.log('[BM300] Connect error: $e');
      rethrow;
    }
  }

  /// Disconnect from the device
  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
      _isConnected = false;
      _connectedDeviceAddress = null;
      _logger.log('[BM300] Disconnected');
    } catch (e) {
      _logger.log('[BM300] Disconnect error: $e');
    }
  }

  /// Clear saved device
  Future<void> forgetDevice() async {
    await disconnect();
    _savedDeviceAddress = null;
    final hive = HiveStorageService.instance;
    if (hive.isAvailable) {
      await hive.deleteSetting('bm300_device_address');
    }
    _logger.log('[BM300] Device forgotten');
  }

  /// Dispose of resources
  void dispose() {
    disconnect();
    _dataController.close();
    _connectionController.close();
    _deviceFoundController.close();
  }
}
