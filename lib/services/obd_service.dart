import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/vehicle_data.dart';
import '../models/obd_pid_config.dart';
import '../models/local_vehicle_profiles.dart';
import 'debug_logger.dart';
import 'native_bluetooth_service.dart';

/// Current PID profile version - increment when formulas change
const int _pidProfileVersion = 3; // v3: Added priority-based polling

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
  String? _currentEcuHeader; // Track actual ELM327 header state across polls

  // Priority-based polling: Low priority PIDs are polled every N cycles
  int _pollCycleCount = 0;
  static const int _lowPriorityInterval = 12; // Poll low priority every 12 cycles (5 sec * 12 = 1 minute)
  final Map<String, double> _lastLowPriorityValues = {}; // Cache last values for low priority PIDs
  List<double>? _cachedCellVoltages; // Cache individual cell voltages for display between polls
  List<double>? _cachedCellTemperatures; // Cache individual cell temperatures for display between polls

  // Per-category timestamps for when data was actually polled (not cached)
  DateTime? _cellVoltagesLastUpdated;
  DateTime? _cellTempsLastUpdated;
  DateTime? _lowPriorityLastUpdated; // General low priority PIDs

  // ECU wake-up tracking: retry on first poll if we get all 7F errors
  bool _ecuWakeupAttempted = false;
  int _consecutive7FErrorCount = 0;
  static const int _max7FErrorsBeforeRetry = 5;

  Stream<VehicleData> get vehicleDataStream => _dataController.stream;
  bool get isConnected => _isConnected;
  String? get connectedDevice => _connectedDeviceAddress;

  /// Get current PID configurations for UI display (priority indicators, etc.)
  List<OBDPIDConfig> get customPIDs => List.unmodifiable(_customPIDs);

  /// Apply cached value for low priority PID that was skipped this cycle
  void _applyCachedValue(
    OBDPIDConfig pidConfig,
    double value,
    Map<String, dynamic> additionalData, {
    required void Function(double) soh,
    required void Function(double) odometer,
    required void Function(double) cumulativeCharge,
    required void Function(double) cumulativeDischarge,
  }) {
    final nameLower = pidConfig.name.toLowerCase();

    switch (pidConfig.type) {
      case OBDPIDType.odometer:
        odometer(value);
        break;
      case OBDPIDType.cumulativeCharge:
        cumulativeCharge(value);
        break;
      case OBDPIDType.cumulativeDischarge:
        cumulativeDischarge(value);
        break;
      case OBDPIDType.cellVoltages:
        additionalData['cellVoltageAvg'] = value;
        // Restore cached individual cell voltages for display
        if (_cachedCellVoltages != null && _cachedCellVoltages!.isNotEmpty) {
          additionalData['cellVoltages'] = _cachedCellVoltages;
        }
        break;
      case OBDPIDType.cellTemperatures:
        additionalData['cellTempAvg'] = value;
        // Restore cached individual cell temperatures for display
        if (_cachedCellTemperatures != null && _cachedCellTemperatures!.isNotEmpty) {
          additionalData['cellTemperatures'] = _cachedCellTemperatures;
        }
        break;
      case OBDPIDType.custom:
        if (nameLower.contains('soh') || nameLower.contains('health')) {
          soh(value);
        } else {
          additionalData[pidConfig.name] = value;
        }
        break;
      default:
        additionalData[pidConfig.name] = value;
        break;
    }
  }
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
    if (!_autoReconnectEnabled || _isReconnecting) {
      return;
    }

    // Save address before it gets cleared by failed connect attempts
    final addressToReconnect = _connectedDeviceAddress;
    if (addressToReconnect == null) {
      _logger.log('[OBDService] No device address for reconnect');
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
    _logger.log('[OBDService] Scheduling reconnect attempt $_reconnectAttempts/$_maxReconnectAttempts in ${delay.inSeconds}s to $addressToReconnect');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (!_isConnected) {
        _logger.log('[OBDService] Attempting auto-reconnect to $addressToReconnect');
        // Temporarily restore address so connect() can use it
        _connectedDeviceAddress = addressToReconnect;
        final success = await connect(addressToReconnect);
        if (success) {
          _logger.log('[OBDService] Auto-reconnect successful');
          _reconnectAttempts = 0;
        } else {
          _logger.log('[OBDService] Auto-reconnect failed');
          // Restore address for next retry (connect clears it on failure)
          _connectedDeviceAddress = addressToReconnect;
          _isReconnecting = false;
          _scheduleReconnect(); // Try again
          return;
        }
      }
      _isReconnecting = false;
    });
  }

  /// Auto-connect to last used device if available
  Future<bool> autoConnect() async {
    String? lastAddress;

    // Try dedicated OBD address file first (simplest, most reliable)
    const obdAddressFile = '/data/data/com.example.carsoc/files/last_obd_device.txt';
    try {
      final file = File(obdAddressFile);
      if (await file.exists()) {
        lastAddress = (await file.readAsString()).trim();
        if (lastAddress.isNotEmpty) {
          _logger.log('[OBDService] Loaded OBD address from dedicated file: $lastAddress');
        } else {
          lastAddress = null;
        }
      }
    } catch (e) {
      _logger.log('[OBDService] Dedicated OBD file read failed: $e');
    }

    // Try hardcoded JSON file path as backup
    if (lastAddress == null || lastAddress.isEmpty) {
      const hardcodedPath = '/data/data/com.example.carsoc/files/app_settings.json';
      try {
        final file = File(hardcodedPath);
        if (await file.exists()) {
          final content = await file.readAsString();
          final Map<String, dynamic> settings = jsonDecode(content);
          lastAddress = settings['last_obd_address'] as String?;
          _logger.log('[OBDService] JSON settings last_obd_address: $lastAddress');
        }
      } catch (e) {
        _logger.log('[OBDService] JSON settings read failed: $e');
      }
    }

    // Try SharedPreferences with retry if file methods failed
    if (lastAddress == null || lastAddress.isEmpty) {
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final prefs = await SharedPreferences.getInstance();
          lastAddress = prefs.getString('last_obd_address');
          if (lastAddress != null && lastAddress.isNotEmpty) {
            _logger.log('[OBDService] SharedPrefs last_obd_address: $lastAddress');
            break;
          }
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
            _logger.log('[OBDService] path_provider last_obd_address: $lastAddress');
          }
          break; // Success, exit retry loop
        } catch (e) {
          _logger.log('[OBDService] path_provider read failed (attempt $attempt): $e');
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

    // Check if we need to migrate to a newer PID profile version
    bool needsMigration = await _checkPidProfileMigration();
    if (needsMigration) {
      _logger.log('[OBDService] PID profile migration needed - refreshing from local profile');
      await _migrateToLatestProfile();
      return;
    }

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

  /// Check if PID profile needs migration to newer version
  Future<bool> _checkPidProfileMigration() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw TimeoutException('SharedPreferences timeout'),
      );
      final savedVersion = prefs.getInt('pid_profile_version') ?? 0;

      if (savedVersion < _pidProfileVersion) {
        _logger.log('[OBDService] PID profile version $savedVersion < $_pidProfileVersion, migration needed');
        return true;
      }
      return false;
    } catch (e) {
      _logger.log('[OBDService] Could not check profile version: $e');
      // Check file-based version
      return await _checkPidProfileMigrationFromFile();
    }
  }

  /// Check migration from file
  Future<bool> _checkPidProfileMigrationFromFile() async {
    try {
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/pid_profile_version.txt';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/pid_profile_version.txt';
      }

      final file = File(filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final savedVersion = int.tryParse(content.trim()) ?? 0;
        if (savedVersion < _pidProfileVersion) {
          return true;
        }
        return false;
      }
      // No version file = first run or old install, needs migration
      return true;
    } catch (e) {
      _logger.log('[OBDService] Could not check file profile version: $e');
      return true; // Assume migration needed if we can't check
    }
  }

  /// Migrate to latest PID profile (refresh XPENG G6 profile)
  Future<void> _migrateToLatestProfile() async {
    // Find XPENG G6 local profile
    final xpengProfile = LocalVehicleProfiles.findProfile('XPENG G6');
    if (xpengProfile != null) {
      _customPIDs = xpengProfile.pids;
      _logger.log('[OBDService] Migrated to XPENG G6 profile v$_pidProfileVersion with ${_customPIDs.length} PIDs');

      // Save the updated PIDs
      await _saveCustomPIDs(_customPIDs);

      // Save the new version
      await _savePidProfileVersion();
    } else {
      _logger.log('[OBDService] WARNING: Could not find XPENG G6 profile for migration');
    }
  }

  /// Save custom PIDs to storage
  Future<void> _saveCustomPIDs(List<OBDPIDConfig> pids) async {
    final pidsJson = jsonEncode(pids.map((p) => p.toJson()).toList());

    // Save to file first (most reliable)
    try {
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/obd_pids.json';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/obd_pids.json';
      }
      await File(filePath).writeAsString(pidsJson);
      _logger.log('[OBDService] Saved PIDs to file: $filePath');
    } catch (e) {
      _logger.log('[OBDService] Failed to save PIDs to file: $e');
    }

    // Also try SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('obd_pids', pidsJson);
      _logger.log('[OBDService] Saved PIDs to SharedPreferences');
    } catch (e) {
      _logger.log('[OBDService] Failed to save PIDs to SharedPreferences: $e');
    }
  }

  /// Save PID profile version
  Future<void> _savePidProfileVersion() async {
    // Save to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('pid_profile_version', _pidProfileVersion);
    } catch (e) {
      _logger.log('[OBDService] Failed to save profile version to SharedPreferences: $e');
    }

    // Also save to file
    try {
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/pid_profile_version.txt';
      } catch (e) {
        filePath = '/data/data/com.example.carsoc/files/pid_profile_version.txt';
      }
      await File(filePath).writeAsString('$_pidProfileVersion');
    } catch (e) {
      _logger.log('[OBDService] Failed to save profile version to file: $e');
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

  /// Save last connected address to multiple locations for reliability
  Future<void> _saveLastAddress(String address) async {
    // Save to simple dedicated text file FIRST (most reliable, no JSON parsing)
    const obdAddressFile = '/data/data/com.example.carsoc/files/last_obd_device.txt';
    try {
      final file = File(obdAddressFile);
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(address);
      _logger.log('[OBDService] Saved OBD address to dedicated file: $address');
    } catch (e) {
      _logger.log('[OBDService] Warning: Could not save to dedicated file: $e');
    }

    // Also save to JSON settings file
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
      _logger.log('[OBDService] Saved OBD address to JSON settings: $address');
    } catch (e) {
      _logger.log('[OBDService] Warning: Could not save to JSON settings: $e');
    }

    // Also save to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_obd_address', address);
      _logger.log('[OBDService] Saved OBD address to SharedPreferences: $address');
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

  /// Get the expected response address for a given request header
  /// XPENG uses: 704 -> 784 (BMS), 7E0 -> 7E8 (VCU)
  String _getResponseAddress(String header) {
    // CAN response address calculation:
    // - For 7xx (e.g., 704): response is 7xx + 0x80 = 784
    // - For 7Ex (e.g., 7E0): response is 7Ex + 0x08 = 7E8
    try {
      final requestId = int.parse(header, radix: 16);
      int responseId;

      // Check if this is a 7Ex style address (0x7E0-0x7EF)
      if ((requestId & 0x7F0) == 0x7E0) {
        // For 7Ex addresses, add 8 to get 7E8, 7E9, etc.
        responseId = requestId + 0x08;
      } else {
        // For other addresses (like 704), add 0x80 to get 784
        responseId = requestId + 0x80;
      }

      return responseId.toRadixString(16).toUpperCase();
    } catch (e) {
      // Fallback: return as-is if parsing fails
      return header;
    }
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
            // Track header state from init commands
            if (cmd.trim().startsWith('ATSH')) {
              _currentEcuHeader = cmd.trim().substring(4);
              _logger.log('[OBDService] Initial header set to: $_currentEcuHeader');
            }
          }
        }
      } else {
        // Use standard auto protocol detection
        _logger.log('[OBDService] Using standard init (auto protocol)');
        await _sendCommand('ATSP0');
        await Future.delayed(const Duration(milliseconds: 100));
        _currentEcuHeader = null; // Unknown header in auto mode
      }

      // Allow long messages (for multi-frame responses)
      await _sendCommand('ATAL');
      await Future.delayed(const Duration(milliseconds: 100));

      // Enable automatic flow control for multi-frame ISO-TP responses
      // This is critical for receiving cell voltages (221122) and temperatures (221123)
      // which return 227+ bytes across multiple frames
      final cfcResult = await _sendCommand('ATCFC1');
      await Future.delayed(const Duration(milliseconds: 100));

      // Set flow control data: 30=CTS (Clear To Send), 00=no block limit, 00=no delay
      final fcsdResult = await _sendCommand('ATFCSD300000');
      await Future.delayed(const Duration(milliseconds: 100));

      // Set flow control mode to use user-defined header (ATFCSH) with standard data format
      // Mode 1 = user-defined header, standard data format
      // This is required for the ELM327 to actually use the ATFCSH setting
      final fcsmResult = await _sendCommand('ATFCSM1');
      await Future.delayed(const Duration(milliseconds: 100));

      _logger.log('[OBDService] Flow control setup: CFC1=$cfcResult, FCSD=$fcsdResult, FCSM=$fcsmResult');

      // Get protocol
      final protocol = await _sendCommand('ATDPN');
      _logger.log('[OBDService] Protocol: $protocol');

      _logger.log('[OBDService] ELM327 initialized');

      // Reset ECU wake-up tracking for new connection
      _ecuWakeupAttempted = false;
      _consecutive7FErrorCount = 0;
    } catch (e) {
      _logger.log('[OBDService] ELM327 initialization error: $e');
      throw Exception('Failed to initialize ELM327: $e');
    }
  }

  /// Wake up ECUs by sending a few requests to trigger the vehicle's
  /// communication modules. Some vehicles (like XPENG G6) need this
  /// before they respond properly to data requests.
  Future<void> _wakeUpECUs() async {
    _logger.log('[OBDService] Waking up ECUs...');

    try {
      // Send a simple request to each ECU to wake them up
      // BMS ECU (704/784)
      await _sendCommand('ATSH704');
      await Future.delayed(const Duration(milliseconds: 100));
      await _sendCommand('221109'); // SOC request to wake BMS
      await Future.delayed(const Duration(milliseconds: 500));

      // VCU ECU (7E0/7E8)
      await _sendCommand('ATSH7E0');
      await Future.delayed(const Duration(milliseconds: 100));
      await _sendCommand('220104'); // Speed request to wake VCU
      await Future.delayed(const Duration(milliseconds: 500));

      _logger.log('[OBDService] ECU wake-up sequence complete');
      _ecuWakeupAttempted = true;
    } catch (e) {
      _logger.log('[OBDService] ECU wake-up error: $e');
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

    // Poll every 5 seconds to reduce load and prevent app hangs
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
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

      // Increment poll cycle counter
      _pollCycleCount++;
      final bool pollLowPriority = (_pollCycleCount % _lowPriorityInterval == 0) || _pollCycleCount == 1;

      if (pollLowPriority) {
        _logger.log('[OBDService] Poll cycle $_pollCycleCount: polling ALL PIDs (including low priority)');
        _lowPriorityLastUpdated = DateTime.now(); // Track when low priority PIDs were polled
      } else {
        _logger.log('[OBDService] Poll cycle $_pollCycleCount: polling HIGH priority PIDs only');
      }

      // Reset 7F error counter at start of each poll cycle
      _consecutive7FErrorCount = 0;

      // Use class field to track actual ELM327 header state across poll cycles
      // This persists across polls so we know the real adapter state

      // Query each configured PID based on priority
      for (final pidConfig in _customPIDs) {
        // Skip low priority PIDs unless it's time to poll them
        if (pidConfig.priority == PIDPriority.low && !pollLowPriority) {
          // Use cached value if available
          if (_lastLowPriorityValues.containsKey(pidConfig.pid)) {
            final cachedValue = _lastLowPriorityValues[pidConfig.pid]!;
            // Apply cached value to appropriate field
            _applyCachedValue(pidConfig, cachedValue, additionalData,
                soh: (v) => soh = v,
                odometer: (v) => odometer = v,
                cumulativeCharge: (v) => cumulativeCharge = v,
                cumulativeDischarge: (v) => cumulativeDischarge = v);
          }
          continue;
        }
        try {
          // Switch header if this PID requires a different one
          // Compare against actual adapter state, not assumed state
          if (pidConfig.header != null && pidConfig.header != _currentEcuHeader) {
            final responseAddr = _getResponseAddress(pidConfig.header!);
            _logger.log('[OBDService] Switching ECU header: ${_currentEcuHeader ?? "unknown"} -> ${pidConfig.header} (response: $responseAddr)');

            // Set CAN transmit header
            final headerResult = await _sendCommand('ATSH${pidConfig.header}');
            await Future.delayed(const Duration(milliseconds: 50));

            // Set CAN receive address filter
            final craResult = await _sendCommand('ATCRA$responseAddr');
            await Future.delayed(const Duration(milliseconds: 50));

            // Set flow control header for multi-frame responses
            final fcshResult = await _sendCommand('ATFCSH${pidConfig.header}');
            await Future.delayed(const Duration(milliseconds: 50));

            _currentEcuHeader = pidConfig.header;
            _logger.log('[OBDService] Header switch complete: ATSH=$headerResult, ATCRA=$craResult, ATFCSH=$fcshResult');
          }

          final response = await _sendCommand(pidConfig.pid);

          // Skip if empty response
          if (response.isEmpty) {
            continue;
          }

          final value = pidConfig.parser(response);

          // Skip if value is NaN (indicates error/unsupported PID)
          if (value.isNaN) {
            _logger.log('[OBDService] ${pidConfig.name}: skipped (error response)');
            _consecutive7FErrorCount++;
            continue;
          }

          // Cache low priority values for use in cycles when they're not polled
          if (pidConfig.priority == PIDPriority.low) {
            _lastLowPriorityValues[pidConfig.pid] = value;
          }

          // Map to appropriate field based on type and name
          switch (pidConfig.type) {
            case OBDPIDType.speed:
              speed = value;
              _logger.log('[OBDService] Speed: $value km/h');
              break;
            case OBDPIDType.stateOfCharge:
              if (value > 100.0) {
                _logger.log('[OBDService] BAD DATA: SOC $value% exceeds 100%, discarding');
              } else {
                soc = value;
                _logger.log('[OBDService] SOC: $value%');
              }
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
            case OBDPIDType.cellVoltages:
              // Average cell voltage - store in additional data
              additionalData['cellVoltageAvg'] = value;
              // Also parse and store all individual cell voltages
              final allCellVoltages = OBDPIDConfig.parseCellVoltages(response);
              if (allCellVoltages.isNotEmpty) {
                additionalData['cellVoltages'] = allCellVoltages;
                _cachedCellVoltages = allCellVoltages; // Cache for display between polls
                _cellVoltagesLastUpdated = DateTime.now(); // Track when actually polled
                final minV = allCellVoltages.reduce((a, b) => a < b ? a : b);
                final maxV = allCellVoltages.reduce((a, b) => a > b ? a : b);
                final deltaV = ((maxV - minV) * 1000).round(); // mV
                _logger.log('[OBDService] Cell Voltages: ${allCellVoltages.length} cells, '
                    'avg=${value.toStringAsFixed(3)}V, min=${minV.toStringAsFixed(3)}V, '
                    'max=${maxV.toStringAsFixed(3)}V, delta=${deltaV}mV');
              } else {
                _logger.log('[OBDService] Cell Voltage Avg: ${value.toStringAsFixed(3)} V');
              }
              break;
            case OBDPIDType.cellTemperatures:
              // Average cell temperature - store in additional data
              additionalData['cellTempAvg'] = value;
              // Also parse and store all individual cell temperatures
              final allCellTemps = OBDPIDConfig.parseCellTemperatures(response);
              if (allCellTemps.isNotEmpty) {
                additionalData['cellTemperatures'] = allCellTemps;
                _cachedCellTemperatures = allCellTemps; // Cache for display between polls
                _cellTempsLastUpdated = DateTime.now(); // Track when actually polled
                final minT = allCellTemps.reduce((a, b) => a < b ? a : b);
                final maxT = allCellTemps.reduce((a, b) => a > b ? a : b);
                _logger.log('[OBDService] Cell Temps: ${allCellTemps.length} sensors, '
                    'avg=${value.toStringAsFixed(1)}°C, min=${minT.toStringAsFixed(1)}°C, '
                    'max=${maxT.toStringAsFixed(1)}°C');
              } else {
                _logger.log('[OBDService] Cell Temp Avg: ${value.toStringAsFixed(1)} °C');
              }
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

      // Check if we got too many 7F errors on first few poll cycles (ECUs not awake)
      // If we haven't attempted wake-up yet and got mostly errors, trigger wake-up
      if (!_ecuWakeupAttempted &&
          _pollCycleCount <= 3 &&
          _consecutive7FErrorCount >= _max7FErrorsBeforeRetry) {
        _logger.log(
            '[OBDService] Too many 7F errors ($_consecutive7FErrorCount) on poll cycle $_pollCycleCount - ECUs may be asleep');
        _logger.log('[OBDService] Triggering ECU wake-up sequence...');
        await _wakeUpECUs();
        // Reset header state after wake-up so next poll re-initializes properly
        _currentEcuHeader = null;
      }

      // Add per-category timestamps for when data was actually polled
      if (_cellVoltagesLastUpdated != null) {
        additionalData['cellVoltagesLastUpdated'] = _cellVoltagesLastUpdated!.toIso8601String();
      }
      if (_cellTempsLastUpdated != null) {
        additionalData['cellTempsLastUpdated'] = _cellTempsLastUpdated!.toIso8601String();
      }
      if (_lowPriorityLastUpdated != null) {
        additionalData['lowPriorityLastUpdated'] = _lowPriorityLastUpdated!.toIso8601String();
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
      _currentEcuHeader = null; // Reset header state on disconnect

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
