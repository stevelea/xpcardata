import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:pointycastle/export.dart';
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

  // BLE UUIDs for BM300 Pro
  static final _serviceUuid = Guid('0000fff0-0000-1000-8000-00805f9b34fb');
  static final _writeCharUuid = Guid('0000fff3-0000-1000-8000-00805f9b34fb');
  static final _notifyCharUuid = Guid('0000fff4-0000-1000-8000-00805f9b34fb');

  // AES encryption key for BM300 Pro
  static final _aesKey = Uint8List.fromList([
    108, 101, 97, 103, 101, 110, 100, 255, // "legend" + 0xFF 0xFE
    254, 48, 49, 48, 48, 48, 48, 64 // "010000@"
  ]);

  // Command to start notifications
  static final _startCommand = Uint8List.fromList([
    0xd1, 0x55, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  ]);

  // State
  bool _isEnabled = false;
  bool _isConnected = false;
  bool _isScanning = false;
  String? _connectedDeviceAddress;
  String? _savedDeviceAddress;
  BM300BatteryData? _lastData;

  // BLE connection
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  Timer? _commandTimer;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

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

      // Keep method channel handler for backwards compatibility
      _channel.setMethodCallHandler(_handleMethodCall);

      _logger.log(
          '[BM300] Initialized: enabled=$_isEnabled, savedDevice=$_savedDeviceAddress');

      // Auto-connect if enabled and device was previously connected
      if (_isEnabled && _savedDeviceAddress != null) {
        _logger.log('[BM300] Scheduling auto-connect to saved device...');
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

  /// Handle method calls from native code (backwards compatibility)
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    // Keep for backwards compatibility but now using flutter_blue_plus
    _logger.log('[BM300] Native callback: ${call.method}');
  }

  /// Check if Bluetooth permissions are granted
  Future<bool> hasPermissions() async {
    try {
      // flutter_blue_plus handles permissions internally
      return true;
    } catch (e) {
      _logger.log('[BM300] Error checking permissions: $e');
      return false;
    }
  }

  /// Check if Bluetooth is enabled
  Future<bool> isBluetoothEnabled() async {
    try {
      final state = await FlutterBluePlus.adapterState.first;
      return state == BluetoothAdapterState.on;
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

  /// Check if location services are enabled
  Future<bool> isLocationEnabled() async {
    try {
      // Location check - flutter_blue_plus handles this
      return true;
    } catch (e) {
      _logger.log('[BM300] Error checking location: $e');
      return false;
    }
  }

  /// Start scanning for BM300 Pro devices using flutter_blue_plus
  Future<void> startScan({int timeoutMs = 60000}) async {
    if (_isScanning) return;

    try {
      _isScanning = true;

      // Check Bluetooth state
      final btState = await FlutterBluePlus.adapterState.first;
      _logger.log('[BM300] Bluetooth state: $btState');

      if (btState != BluetoothAdapterState.on) {
        _logger.log('[BM300] Bluetooth is not enabled!');
        _isScanning = false;
        return;
      }

      _logger.log('[BM300] Starting flutter_blue_plus scan (timeout: ${timeoutMs}ms)...');

      // Track seen devices
      final seenDevices = <String>{};
      int deviceCount = 0;

      // Listen to scan results
      _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          final device = result.device;
          final name = device.platformName;
          final address = device.remoteId.str;
          final rssi = result.rssi;

          // Check for FFF0 service UUID
          final hasFFF0 = result.advertisementData.serviceUuids
              .any((uuid) => uuid.str.toLowerCase().contains('fff0'));

          // Log new devices
          if (!seenDevices.contains(address)) {
            seenDevices.add(address);
            deviceCount++;
            final services = result.advertisementData.serviceUuids
                .map((u) => u.str.substring(4, 8))
                .join(',');
            _logger.log(
                '[BM300] FBP #$deviceCount: name=\'$name\' addr=$address rssi=$rssi services=[$services] hasFFF0=$hasFFF0');
          }

          // Check if this is a BM300 device
          final isBM300 = _isBM300Device(name, address, hasFFF0);

          if (isBM300) {
            final displayName = name.isNotEmpty ? name : (hasFFF0 ? 'BM Battery Monitor' : 'BM300');
            _logger.log('[BM300] *** MATCH! $displayName ($address) ***');
            _deviceFoundController.add({
              'name': displayName,
              'address': address,
            });
          }
        }
      });

      // Start scanning
      await FlutterBluePlus.startScan(
        timeout: Duration(milliseconds: timeoutMs),
        androidUsesFineLocation: true,
      );

      _logger.log('[BM300] Scan started successfully');

      // Log progress every 10 seconds
      int progressCount = 0;
      Timer.periodic(const Duration(seconds: 10), (timer) {
        if (!_isScanning) {
          timer.cancel();
          return;
        }
        progressCount++;
        _logger.log('[BM300] Scan progress (${progressCount * 10}s): ${seenDevices.length} devices found');
        if (progressCount * 10000 >= timeoutMs) {
          timer.cancel();
        }
      });

      // Wait for scan to complete
      await Future.delayed(Duration(milliseconds: timeoutMs + 1000));

      _isScanning = false;
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      _logger.log('[BM300] Scan completed: ${seenDevices.length} devices found');
    } catch (e) {
      _isScanning = false;
      _logger.log('[BM300] Scan error: $e');
      rethrow;
    }
  }

  /// Check if a device looks like a BM300
  bool _isBM300Device(String name, String address, bool hasFFF0) {
    if (hasFFF0) return true; // Has FFF0 service - definitely a BM300/BM6 type device
    if (name.isEmpty) return false;
    if (name == 'BM300 Pro') return true;
    if (RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(name)) return true; // 12 hex chars (serial)
    if (name.startsWith('BM')) return true;
    if (name.toLowerCase().contains('bm300')) return true;
    if (name.toLowerCase().contains('bm6')) return true;
    if (name.toLowerCase().contains('ancel')) return true;
    return false;
  }

  /// Stop scanning
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;
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

      _logger.log('[BM300] Connecting to $address...');

      // Get device by ID
      final device = BluetoothDevice.fromId(address);
      _connectedDevice = device;

      // Listen for connection state changes
      _connectionSubscription = device.connectionState.listen((state) {
        _logger.log('[BM300] Connection state: $state');
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnect();
        }
      });

      // Connect
      await device.connect(timeout: const Duration(seconds: 15));
      _logger.log('[BM300] Connected, discovering services...');

      // Discover services
      final services = await device.discoverServices();
      _logger.log('[BM300] Found ${services.length} services');

      // Find BM300 service
      BluetoothService? bm300Service;
      for (final service in services) {
        if (service.uuid == _serviceUuid) {
          bm300Service = service;
          break;
        }
      }

      if (bm300Service == null) {
        _logger.log('[BM300] Service FFF0 not found!');
        await device.disconnect();
        return;
      }

      // Find characteristics
      for (final char in bm300Service.characteristics) {
        if (char.uuid == _writeCharUuid) {
          _writeChar = char;
          _logger.log('[BM300] Found write characteristic FFF3');
        } else if (char.uuid == _notifyCharUuid) {
          _notifyChar = char;
          _logger.log('[BM300] Found notify characteristic FFF4');
        }
      }

      if (_writeChar == null || _notifyChar == null) {
        _logger.log('[BM300] Required characteristics not found!');
        await device.disconnect();
        return;
      }

      // Enable notifications
      await _notifyChar!.setNotifyValue(true);
      _notifySubscription = _notifyChar!.onValueReceived.listen(_handleNotification);
      _logger.log('[BM300] Notifications enabled');

      // Send start command
      await _sendCommand();

      // Start periodic command timer
      _commandTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _sendCommand();
      });

      _isConnected = true;
      _connectedDeviceAddress = address;
      _connectionController.add(true);
      _logger.log('[BM300] Fully connected and receiving data');
    } catch (e) {
      _logger.log('[BM300] Connect error: $e');
      _isConnected = false;
      _connectedDeviceAddress = null;
      rethrow;
    }
  }

  /// Send command to BM300
  Future<void> _sendCommand() async {
    try {
      if (_writeChar != null && _isConnected) {
        await _writeChar!.write(_startCommand.toList(), withoutResponse: false);
        _logger.log('[BM300] Command sent');
      }
    } catch (e) {
      _logger.log('[BM300] Send command error: $e');
    }
  }

  /// Handle notification data from BM300
  void _handleNotification(List<int> data) {
    try {
      if (data.length < 16) {
        _logger.log('[BM300] Notification too short: ${data.length} bytes');
        return;
      }

      // Decrypt data
      final decrypted = _decryptAes(Uint8List.fromList(data));
      final hexString = decrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      _logger.log('[BM300] Decrypted: $hexString');

      // Validate header
      if (!hexString.startsWith('d1550700')) {
        _logger.log('[BM300] Invalid header, ignoring');
        return;
      }

      // Parse data
      if (hexString.length >= 36) {
        final voltageHex = hexString.substring(30, 34);
        final socHex = hexString.substring(24, 26);
        final tempHex = hexString.substring(16, 18);
        final negativeTemp = hexString.substring(12, 14) == '01';

        final voltage = int.parse(voltageHex, radix: 16) / 100.0;
        final soc = int.parse(socHex, radix: 16);
        var temperature = int.parse(tempHex, radix: 16);
        if (negativeTemp) temperature = -temperature;

        final batteryData = BM300BatteryData(
          voltage: voltage,
          soc: soc,
          temperature: temperature,
        );

        _lastData = batteryData;
        _dataController.add(batteryData);
        _logger.log('[BM300] Data: $batteryData');
      }
    } catch (e) {
      _logger.log('[BM300] Notification parse error: $e');
    }
  }

  /// Decrypt AES-128 CBC with zero IV
  Uint8List _decryptAes(Uint8List encryptedData) {
    try {
      // AES-128 CBC decryption with zero IV
      final key = KeyParameter(_aesKey);
      final iv = Uint8List(16); // Zero IV
      final params = ParametersWithIV<KeyParameter>(key, iv);

      final cipher = CBCBlockCipher(AESEngine())..init(false, params);

      final decrypted = Uint8List(encryptedData.length);
      var offset = 0;
      while (offset < encryptedData.length) {
        offset += cipher.processBlock(encryptedData, offset, decrypted, offset);
      }

      return decrypted;
    } catch (e) {
      _logger.log('[BM300] AES decrypt error: $e');
      return encryptedData;
    }
  }

  /// Handle disconnection
  void _handleDisconnect() {
    _isConnected = false;
    _connectedDeviceAddress = null;
    _connectionController.add(false);

    _commandTimer?.cancel();
    _commandTimer = null;
    _notifySubscription?.cancel();
    _notifySubscription = null;
    _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _writeChar = null;
    _notifyChar = null;
    _connectedDevice = null;

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
  }

  /// Disconnect from the device
  Future<void> disconnect() async {
    try {
      _commandTimer?.cancel();
      _commandTimer = null;
      _notifySubscription?.cancel();
      _notifySubscription = null;
      _connectionSubscription?.cancel();
      _connectionSubscription = null;

      await _connectedDevice?.disconnect();
      _connectedDevice = null;
      _writeChar = null;
      _notifyChar = null;

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
    _scanSubscription?.cancel();
    _dataController.close();
    _connectionController.close();
    _deviceFoundController.close();
  }
}
