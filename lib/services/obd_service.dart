import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/vehicle_data.dart';
import '../models/obd_pid_config.dart';
import 'debug_logger.dart';
import 'native_bluetooth_service.dart';

/// Service for accessing vehicle data via OBD-II Bluetooth adapter
/// Works with ELM327-compatible adapters
/// Uses native Bluetooth (Android 4.4-15+)
class OBDService {
  final _logger = DebugLogger.instance;
  final _bluetooth = NativeBluetoothService();

  final StreamController<VehicleData> _dataController =
      StreamController<VehicleData>.broadcast();

  Timer? _pollingTimer;
  Timer? _reconnectTimer;
  bool _isConnected = false;
  bool _isPolling = false; // Mutex to prevent overlapping polls
  bool _isReconnecting = false;
  bool _autoReconnectEnabled = true;
  bool _pollingPaused = false; // Pause polling when proxy client connected
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  String? _connectedDeviceAddress;
  List<OBDPIDConfig> _customPIDs = [];
  final StringBuffer _receiveBuffer = StringBuffer();
  final bool _enableTrafficLogging = true; // Enable OBD traffic logging

  Stream<VehicleData> get vehicleDataStream => _dataController.stream;
  bool get isConnected => _isConnected;
  String? get connectedDevice => _connectedDeviceAddress;
  bool get isPollingPaused => _pollingPaused;

  /// Pause OBD polling (e.g., when proxy client is connected)
  void pausePolling() {
    if (!_pollingPaused) {
      _pollingPaused = true;
      _logger.log('[OBDService] Polling PAUSED (proxy client connected)');
    }
  }

  /// Resume OBD polling
  void resumePolling() {
    if (_pollingPaused) {
      _pollingPaused = false;
      _logger.log('[OBDService] Polling RESUMED');
    }
  }

  /// Schedule auto-reconnect after connection loss
  void _scheduleReconnect() {
    if (!_autoReconnectEnabled || _isReconnecting || _connectedDeviceAddress == null) {
      return;
    }

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _logger.log('[OBDService] Max reconnect attempts reached, giving up');
      _reconnectAttempts = 0;
      return;
    }

    _isReconnecting = true;
    _reconnectAttempts++;

    // Exponential backoff: 2s, 4s, 8s, 16s, 32s
    final delay = Duration(seconds: 2 << (_reconnectAttempts - 1));
    _logger.log('[OBDService] Scheduling reconnect attempt $_reconnectAttempts/$_maxReconnectAttempts in ${delay.inSeconds}s');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (_connectedDeviceAddress != null && !_isConnected) {
        _logger.log('[OBDService] Attempting auto-reconnect to $_connectedDeviceAddress');
        final success = await connect(_connectedDeviceAddress!);
        if (success) {
          _logger.log('[OBDService] Auto-reconnect successful');
          _reconnectAttempts = 0;
        } else {
          _logger.log('[OBDService] Auto-reconnect failed');
          _scheduleReconnect(); // Try again
        }
      }
      _isReconnecting = false;
    });
  }

  /// Auto-connect to last used device if available
  Future<bool> autoConnect() async {
    String? lastAddress;

    // Try hardcoded file path first (most reliable - doesn't need path_provider)
    const hardcodedPath = '/data/data/com.example.carsoc/files/app_settings.json';
    try {
      final file = File(hardcodedPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> settings = jsonDecode(content);
        lastAddress = settings['last_obd_address'] as String?;
        _logger.log('[OBDService] Hardcoded path last_obd_address: $lastAddress');
      }
    } catch (e) {
      _logger.log('[OBDService] Hardcoded path read failed: $e');
    }

    // Try SharedPreferences with retry if hardcoded path failed
    if (lastAddress == null || lastAddress.isEmpty) {
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final prefs = await SharedPreferences.getInstance();
          lastAddress = prefs.getString('last_obd_address');
          _logger.log('[OBDService] SharedPrefs last_obd_address: $lastAddress');
          break; // Success, exit retry loop
        } catch (e) {
          _logger.log('[OBDService] SharedPreferences read failed (attempt $attempt): $e');
          if (attempt < 3) {
            await Future.delayed(Duration(milliseconds: 500 * attempt));
          }
        }
      }
    }

    // Try path_provider-based file as last resort
    if (lastAddress == null || lastAddress.isEmpty) {
      for (int attempt = 1; attempt <= 2; attempt++) {
        try {
          final directory = await getApplicationDocumentsDirectory();
          final filePath = '${directory.path}/app_settings.json';
          final file = File(filePath);

          if (await file.exists()) {
            final content = await file.readAsString();
            final Map<String, dynamic> settings = jsonDecode(content);
            lastAddress = settings['last_obd_address'] as String?;
            _logger.log('[OBDService] File settings last_obd_address: $lastAddress');
          }
          break; // Success, exit retry loop
        } catch (e) {
          _logger.log('[OBDService] File settings read failed (attempt $attempt): $e');
          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 500 * attempt));
          }
        }
      }
    }

    if (lastAddress != null && lastAddress.isNotEmpty) {
      _logger.log('[OBDService] Auto-connecting to last device: $lastAddress');
      return await connect(lastAddress);
    }

    _logger.log('[OBDService] No last device found for auto-connect');
    return false;
  }

  /// Load custom PIDs from preferences (with timeout)
  Future<void> _loadCustomPIDs() async {
    // Start with empty list
    _customPIDs = [];

    try {
      // Try to load custom PIDs with 1 second timeout
      await Future.any([
        SharedPreferences.getInstance().then((prefs) {
          final pidsJson = prefs.getString('obd_pids');
          if (pidsJson != null) {
            try {
              final List<dynamic> pidsList = jsonDecode(pidsJson);
              _customPIDs = pidsList.map((p) => OBDPIDConfig.fromJson(p)).toList();
              _logger.log('[OBDService] Loaded ${_customPIDs.length} custom PIDs from SharedPreferences');
            } catch (e) {
              _logger.log('[OBDService] Error parsing custom PIDs: $e');
            }
          } else {
            _logger.log('[OBDService] No custom PIDs in SharedPreferences');
          }
        }),
        Future.delayed(const Duration(seconds: 1)),
      ]);
    } catch (e) {
      _logger.log('[OBDService] SharedPreferences failed: $e');
    }

    // If SharedPreferences failed or empty, try file fallback
    if (_customPIDs.isEmpty) {
      _logger.log('[OBDService] Trying file-based PID storage...');
      await _loadCustomPIDsFromFile();
    }

    // If still empty after all attempts, log warning
    if (_customPIDs.isEmpty) {
      _logger.log('[OBDService] WARNING: No PIDs configured! Please load a vehicle profile.');
    }
  }

  /// Load custom PIDs from file (fallback for broken SharedPreferences)
  Future<void> _loadCustomPIDsFromFile() async {
    try {
      // Try path_provider first, fallback to hardcoded path
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/obd_pids.json';
      } catch (e) {
        // path_provider failed, use hardcoded Android path
        filePath = '/data/data/com.example.carsoc/files/obd_pids.json';
        _logger.log('[OBDService] path_provider failed, using hardcoded path');
      }

      final file = File(filePath);

      if (await file.exists()) {
        final pidsJson = await file.readAsString();
        final List<dynamic> pidsList = jsonDecode(pidsJson);
        _customPIDs = pidsList.map((p) => OBDPIDConfig.fromJson(p)).toList();
        _logger.log('[OBDService] Loaded ${_customPIDs.length} custom PIDs from file: $filePath');
      } else {
        _logger.log('[OBDService] No PID file found at $filePath');
      }
    } catch (e) {
      _logger.log('[OBDService] File-based PID loading failed: $e');
    }
  }

  /// Connect to OBD-II adapter
  Future<bool> connect(String address) async {
    try {
      _logger.log('[OBDService] Connecting to OBD adapter at $address...');

      // Close existing connection if any
      await disconnect();

      // Give Bluetooth stack time to release the socket
      await Future.delayed(const Duration(milliseconds: 500));
      _logger.log('[OBDService] Starting Bluetooth connection...');

      // Load custom PIDs (with timeout to avoid blocking connection)
      await _loadCustomPIDs();

      // Connect to the Bluetooth device
      final connected = await _bluetooth.connect(address);

      if (!connected) {
        _logger.log('[OBDService] Failed to connect to device');
        return false;
      }

      _isConnected = true;
      _connectedDeviceAddress = address;

      // Save last connected device for auto-connect
      await _saveLastAddress(address);

      _logger.log('[OBDService] Connected to OBD adapter');

      // Initialize ELM327
      await _initializeELM327();

      // Start data collection
      _startDataCollection();

      return true;
    } catch (e) {
      _logger.log('[OBDService] Connection failed: $e');
      _isConnected = false;
      _connectedDeviceAddress = null;
      return false;
    }
  }

  /// Save last connected address to hardcoded path, SharedPreferences, and path_provider file
  Future<void> _saveLastAddress(String address) async {
    // Save to hardcoded path first (most reliable - doesn't need path_provider)
    const hardcodedPath = '/data/data/com.example.carsoc/files/app_settings.json';
    try {
      final file = File(hardcodedPath);

      // Ensure directory exists
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      Map<String, dynamic> settings = {};
      if (await file.exists()) {
        final content = await file.readAsString();
        settings = jsonDecode(content) as Map<String, dynamic>;
      }

      settings['last_obd_address'] = address;
      await file.writeAsString(jsonEncode(settings));
      _logger.log('[OBDService] Saved last OBD address to hardcoded path: $address');
    } catch (e) {
      _logger.log('[OBDService] Warning: Could not save to hardcoded path: $e');
    }

    // Also save to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_obd_address', address);
      _logger.log('[OBDService] Saved last OBD address to prefs: $address');
    } catch (e) {
      _logger.log('[OBDService] Warning: Could not save to SharedPreferences: $e');
    }

    // Also save to path_provider-based file as backup
    try {
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/app_settings.json';
      final file = File(filePath);

      Map<String, dynamic> settings = {};
      if (await file.exists()) {
        final content = await file.readAsString();
        settings = jsonDecode(content) as Map<String, dynamic>;
      }

      settings['last_obd_address'] = address;
      await file.writeAsString(jsonEncode(settings));
      _logger.log('[OBDService] Saved last OBD address to path_provider file: $address');
    } catch (e) {
      _logger.log('[OBDService] Warning: Could not save to path_provider file: $e');
    }
  }

  /// Detect vehicle-specific init commands based on loaded PIDs
  String? _detectVehicleInit() {
    if (_customPIDs.isEmpty) {
      return null;
    }

    // XPENG G6 - Check for characteristic PIDs (verified profile format without trailing 1)
    // Verified PIDs: 221109 (SOC), 220104 (Speed), 22110A (SOH), 221101 (HV Voltage)
    if (_customPIDs.any((pid) => pid.pid == '221109') ||
        _customPIDs.any((pid) => pid.pid == '220104') ||
        _customPIDs.any((pid) => pid.pid == '22110A') ||
        _customPIDs.any((pid) => pid.pid == '221101')) {
      _logger.log('[OBDService] Detected XPENG G6 vehicle (verified profile)');
      return 'ATH1;ATSP6;ATS0;ATM0;ATAT1;ATSH704;ATCRA784;ATFCSH704;ATFCSM1';
    }

    // XPENG G6 - Also check for WiCAN community profile format (PIDs with trailing 1)
    // This is a fallback for users who loaded the WiCAN profile before
    if (_customPIDs.any((pid) => pid.pid == '2211091') ||
        _customPIDs.any((pid) => pid.pid == '2201011')) {
      _logger.log('[OBDService] Detected XPENG G6 vehicle (WiCAN profile - consider switching to verified profile)');
      return 'ATH1;ATSP6;ATS0;ATM0;ATAT1;ATSH704;ATCRA784;ATFCSH704;ATFCSM1';
    }

    // Hyundai/Kia EV - Check for 220105 (SOC) or similar
    if (_customPIDs.any((pid) => pid.pid == '220105') ||
        _customPIDs.any((pid) => pid.pid == '220101')) {
      _logger.log('[OBDService] Detected Hyundai/Kia EV');
      return 'ATSP6;ATSH7E4;ATFCSH7E4;ATFCSD300000;ATFCSM1';
    }

    // Tesla - Check for 3902 or 39FF
    if (_customPIDs.any((pid) => pid.pid == '3902') ||
        _customPIDs.any((pid) => pid.pid == '39FF')) {
      _logger.log('[OBDService] Detected Tesla');
      return 'ATSP6;ATSH7DF;ATFCSH7DF;ATFCSM1';
    }

    // Nissan Leaf - Check for 21014B (SOC) or 21014C
    if (_customPIDs.any((pid) => pid.pid == '21014B') ||
        _customPIDs.any((pid) => pid.pid == '21014C')) {
      _logger.log('[OBDService] Detected Nissan Leaf');
      return 'ATSP6;ATSH79B;ATFCSH79B;ATFCSD300000;ATFCSM1';
    }

    // BMW i3 - Check for 2203DD or 2204D9
    if (_customPIDs.any((pid) => pid.pid == '2203DD') ||
        _customPIDs.any((pid) => pid.pid == '2204D9')) {
      _logger.log('[OBDService] Detected BMW i3');
      return 'ATSP6;ATSH762;ATFCSH762;ATFCSD300000;ATFCSM1';
    }

    // Generic fallback: If all PIDs start with '22' and are long (6+ chars),
    // likely needs CAN protocol 6 instead of auto
    final hasOnlyLongPIDs = _customPIDs.every((pid) => pid.pid.length >= 6);
    if (hasOnlyLongPIDs) {
      _logger.log('[OBDService] Detected extended PIDs, using CAN protocol 6');
      return 'ATSP6;ATFCSM1';
    }

    return null; // Use standard auto protocol (ATSP0)
  }

  /// Initialize ELM327 adapter
  Future<void> _initializeELM327() async {
    try {
      _logger.log('[OBDService] Initializing ELM327...');

      // Reset adapter
      await _sendCommand('ATZ');
      await Future.delayed(const Duration(milliseconds: 2000));

      // Turn off echo
      await _sendCommand('ATE0');
      await Future.delayed(const Duration(milliseconds: 100));

      // Turn off spaces (makes parsing easier)
      await _sendCommand('ATS0');
      await Future.delayed(const Duration(milliseconds: 100));

      // Detect vehicle-specific init based on PIDs
      String? customInit = _detectVehicleInit();

      if (customInit != null && customInit.isNotEmpty) {
        // Use vehicle-specific init commands
        _logger.log('[OBDService] Using vehicle-specific init: $customInit');
        // Send each AT command separately
        for (final cmd in customInit.split(';')) {
          if (cmd.isNotEmpty) {
            await _sendCommand(cmd.trim());
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }
      } else {
        // Use standard auto protocol detection
        _logger.log('[OBDService] Using standard init (auto protocol)');
        await _sendCommand('ATSP0');
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Allow long messages (for multi-frame responses)
      await _sendCommand('ATAL');
      await Future.delayed(const Duration(milliseconds: 100));

      // Get protocol
      final protocol = await _sendCommand('ATDPN');
      _logger.log('[OBDService] Protocol: $protocol');

      _logger.log('[OBDService] ELM327 initialized');
    } catch (e) {
      _logger.log('[OBDService] ELM327 initialization error: $e');
      throw Exception('Failed to initialize ELM327: $e');
    }
  }

  /// Send command to OBD adapter and get response
  Future<String> _sendCommand(String command) async {
    if (!_isConnected) {
      throw Exception('Not connected to OBD adapter');
    }

    try {
      // Clear receive buffer
      _receiveBuffer.clear();

      // Log outgoing command
      if (_enableTrafficLogging) {
        _logger.log('[OBD Traffic] TX: $command');
      }

      // Send command
      await _bluetooth.sendText('$command\r');

      // Wait for response with improved ISO-TP multi-frame handling
      final stopwatch = Stopwatch()..start();
      int noDataCount = 0;

      while (stopwatch.elapsedMilliseconds < 3000) {
        // Check if data is available
        final available = await _bluetooth.readAvailable();
        if (available > 0) {
          noDataCount = 0; // Reset counter when data arrives
          final data = await _bluetooth.readData(bufferSize: available);
          final text = String.fromCharCodes(data);
          _receiveBuffer.write(text);

          final response = _receiveBuffer.toString();

          // Check for prompt character indicating end of response
          if (response.contains('>')) {
            // Wait a bit more to ensure we got all data (ISO-TP multi-frame)
            // Give extra time to receive any remaining bytes
            await Future.delayed(const Duration(milliseconds: 100));

            // Check if more data arrived during the wait
            final moreAvailable = await _bluetooth.readAvailable();
            if (moreAvailable > 0) {
              final moreData = await _bluetooth.readData(bufferSize: moreAvailable);
              final moreText = String.fromCharCodes(moreData);
              _receiveBuffer.write(moreText);
            }

            // Log received response
            if (_enableTrafficLogging) {
              _logger.log('[OBD Traffic] RX: ${_receiveBuffer.toString().trim()}');
            }
            return _receiveBuffer.toString().trim();
          }
        } else {
          noDataCount++;
          // If no data for too long, check connection state
          if (noDataCount > 40) { // 40 * 50ms = 2 seconds of no data
            final stillConnected = await _bluetooth.isConnected();
            if (!stillConnected) {
              _logger.log('[OBDService] Connection lost during command: $command');
              _isConnected = false;
              _scheduleReconnect();
              return '';
            }
          }
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Timeout - return what we have
      final finalResponse = _receiveBuffer.toString().trim();
      if (_enableTrafficLogging) {
        _logger.log('[OBD Traffic] RX: $finalResponse (timeout)');
      }
      return finalResponse;
    } catch (e) {
      _logger.log('[OBDService] Command error ($command): $e');
      return '';
    }
  }

  /// Start collecting vehicle data
  void _startDataCollection() {
    _logger.log('[OBDService] Starting data collection with ${_customPIDs.length} PIDs');

    if (_customPIDs.isEmpty) {
      _logger.log('[OBDService] WARNING: No PIDs to query! Data collection will not produce results.');
    }

    // Poll every 2 seconds to reduce load and prevent app hangs
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      // Skip if polling is paused (proxy client connected)
      if (_pollingPaused) {
        return;
      }

      // Skip if already polling (previous poll still in progress)
      if (_isPolling) {
        _logger.log('[OBDService] Skipping poll - previous poll still in progress');
        return;
      }

      if (_isConnected && !_dataController.isClosed) {
        _isPolling = true;
        try {
          final data = await _getCurrentVehicleData();
          // Re-check connection state after async operation
          if (_isConnected && !_dataController.isClosed) {
            _dataController.add(data);
          }
        } catch (e) {
          _logger.log('[OBDService] Error in data polling: $e');
          // Don't crash - add error to stream so consumers can handle it
          if (!_dataController.isClosed) {
            _dataController.addError(e);
          }
        } finally {
          _isPolling = false;
        }
      }
    });
  }

  /// Get current vehicle data from OBD-II using custom PIDs
  Future<VehicleData> _getCurrentVehicleData() async {
    try {
      double? speed;
      double? soc;
      double? soh;
      double? batteryVoltage;
      double? batteryCurrent;
      double? batteryTemp;
      double? odometer;
      double? power;
      double? cumulativeCharge;
      double? cumulativeDischarge;
      final Map<String, dynamic> additionalData = {};

      if (_customPIDs.isEmpty) {
        // No PIDs configured, return empty data
        return VehicleData(timestamp: DateTime.now());
      }

      // Query each configured PID
      for (final pidConfig in _customPIDs) {
        try {
          final response = await _sendCommand(pidConfig.pid);

          // Skip if empty response
          if (response.isEmpty) {
            continue;
          }

          final value = pidConfig.parser(response);

          // Skip if value is NaN (indicates error/unsupported PID)
          if (value.isNaN) {
            _logger.log('[OBDService] ${pidConfig.name}: skipped (error response)');
            continue;
          }

          // Map to appropriate field based on type and name
          switch (pidConfig.type) {
            case OBDPIDType.speed:
              speed = value;
              _logger.log('[OBDService] Speed: $value km/h');
              break;
            case OBDPIDType.stateOfCharge:
              soc = value;
              _logger.log('[OBDService] SOC: $value%');
              break;
            case OBDPIDType.batteryVoltage:
              batteryVoltage = value;
              _logger.log('[OBDService] Voltage: $value V');
              break;
            case OBDPIDType.odometer:
              odometer = value;
              _logger.log('[OBDService] Odometer: $value km');
              break;
            case OBDPIDType.cumulativeCharge:
              cumulativeCharge = value;
              _logger.log('[OBDService] Cumulative Charge: $value Ah');
              break;
            case OBDPIDType.cumulativeDischarge:
              cumulativeDischarge = value;
              _logger.log('[OBDService] Cumulative Discharge: $value Ah');
              break;
            case OBDPIDType.custom:
              _logger.log('[OBDService] ${pidConfig.name}: $value');
              // Map custom PIDs to VehicleData fields based on name
              final nameLower = pidConfig.name.toLowerCase();
              final nameUpper = pidConfig.name.toUpperCase();

              // SOH mapping - handle both naming conventions
              if (nameLower.contains('soh') || nameLower.contains('health')) {
                soh = value;
              }
              // Current mapping - handle HV_A and similar names
              else if (nameLower.contains('current') || nameUpper == 'HV_A' || nameLower == 'hv_a') {
                batteryCurrent = value;
                _logger.log('[OBDService] Battery Current mapped: ${value.toStringAsFixed(2)} A (from ${pidConfig.name})');
              }
              // Battery temperature mapping - use HV_T_MAX for battery temp
              else if (nameUpper == 'HV_T_MAX' || (nameLower.contains('temp') && (nameLower.contains('batt') || nameLower.contains('max')))) {
                batteryTemp = value;
              }
              // Other values go to additional properties (skip error values)
              else {
                additionalData[pidConfig.name] = value;
              }
              break;
          }
        } catch (e) {
          _logger.log('[OBDService] Error reading PID ${pidConfig.pid}: $e');
        }

        // Longer delay between commands to prevent response mixing
        await Future.delayed(const Duration(milliseconds: 200));
      }

      // Calculate power if we have voltage and current
      if (batteryVoltage != null && batteryCurrent != null) {
        power = (batteryVoltage * batteryCurrent) / 1000; // kW
        _logger.log('[OBDService] Calculated Power: $power kW');
      }

      return VehicleData(
        timestamp: DateTime.now(),
        speed: speed,
        stateOfCharge: soc,
        stateOfHealth: soh,
        batteryVoltage: batteryVoltage,
        batteryCurrent: batteryCurrent,
        batteryTemperature: batteryTemp,
        odometer: odometer,
        power: power,
        cumulativeCharge: cumulativeCharge,
        cumulativeDischarge: cumulativeDischarge,
        additionalProperties: additionalData.isNotEmpty ? additionalData : null,
      );
    } catch (e) {
      _logger.log('[OBDService] Error getting vehicle data: $e');
      return VehicleData(timestamp: DateTime.now());
    }
  }

  /// Disconnect from OBD adapter
  Future<void> disconnect() async {
    try {
      _pollingTimer?.cancel();
      _pollingTimer = null;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _isPolling = false;
      _isReconnecting = false;
      _reconnectAttempts = 0;

      // Always try to disconnect, even if not marked as connected
      // This ensures we clean up any lingering Bluetooth sockets
      try {
        await _bluetooth.disconnect();
        _logger.log('[OBDService] Bluetooth disconnected');
      } catch (e) {
        _logger.log('[OBDService] Bluetooth disconnect warning: $e');
      }

      _isConnected = false;
      _connectedDeviceAddress = null;
      _receiveBuffer.clear();

      _logger.log('[OBDService] Disconnected from OBD adapter');
    } catch (e) {
      _logger.log('[OBDService] Disconnect error: $e');
    }
  }

  void dispose() {
    disconnect();
    _dataController.close();
  }
}
