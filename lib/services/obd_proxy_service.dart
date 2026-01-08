import 'dart:async';
import 'dart:io';
import 'debug_logger.dart';
import 'native_bluetooth_service.dart';

/// OBD WiFi Proxy Service
///
/// Acts as a WiFi-to-Bluetooth bridge for OBD-II communication.
/// Allows external OBD scanner apps to connect via WiFi and communicate
/// with the Bluetooth OBD adapter through this app.
///
/// Standard ELM327 WiFi adapters use port 35000.
class OBDProxyService {
  final _logger = DebugLogger.instance;
  final NativeBluetoothService _bluetooth;

  ServerSocket? _server;
  Socket? _client;
  bool _isRunning = false;
  int _port = 35000; // Standard ELM327 WiFi port

  final StringBuffer _receiveBuffer = StringBuffer();
  StreamSubscription? _clientSubscription;

  // Callbacks for status updates
  Function(bool isRunning, String? clientAddress)? onStatusChanged;

  bool get isRunning => _isRunning;
  int get port => _port;
  String? get clientAddress => _client?.remoteAddress.address;

  OBDProxyService(this._bluetooth);

  /// Start the WiFi proxy server
  Future<bool> start({int? port}) async {
    if (_isRunning) {
      _logger.log('[OBDProxy] Already running');
      return true;
    }

    if (port != null) {
      _port = port;
    }

    try {
      _logger.log('[OBDProxy] Starting server on port $_port...');

      // Get the device's WiFi IP address for display
      final addresses = await _getWiFiAddresses();
      _logger.log('[OBDProxy] Device IP addresses: $addresses');

      // Bind to all interfaces so clients on WiFi can connect
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        _port,
        shared: true,
      );

      _isRunning = true;
      _logger.log('[OBDProxy] Server STARTED successfully on port $_port');

      if (addresses.isNotEmpty) {
        for (final addr in addresses) {
          _logger.log('[OBDProxy] Connect your OBD app to: $addr:$_port');
        }
      } else {
        _logger.log('[OBDProxy] WARNING: No WiFi IP found - check WiFi connection');
      }

      // Listen for incoming connections
      _server!.listen(
        _handleConnection,
        onError: (error) {
          _logger.log('[OBDProxy] Server error: $error');
        },
        onDone: () {
          _logger.log('[OBDProxy] Server closed');
          _isRunning = false;
          onStatusChanged?.call(false, null);
        },
      );

      onStatusChanged?.call(true, null);
      return true;
    } catch (e) {
      _logger.log('[OBDProxy] Failed to start server: $e');
      _isRunning = false;
      return false;
    }
  }

  /// Stop the WiFi proxy server
  Future<void> stop() async {
    _logger.log('[OBDProxy] Stopping server...');

    await _disconnectClient();

    await _server?.close();
    _server = null;
    _isRunning = false;

    _logger.log('[OBDProxy] Server stopped');
    onStatusChanged?.call(false, null);
  }

  /// Handle incoming client connection
  void _handleConnection(Socket client) {
    final clientAddr = '${client.remoteAddress.address}:${client.remotePort}';
    _logger.log('[OBDProxy] === INCOMING CONNECTION from $clientAddr ===');

    // Only allow one client at a time
    if (_client != null) {
      _logger.log('[OBDProxy] Rejecting connection - already have a client connected');
      client.write('BUSY\r\n');
      client.close();
      return;
    }

    _client = client;
    _logger.log('[OBDProxy] Client ACCEPTED: $clientAddr');

    onStatusChanged?.call(true, client.remoteAddress.address);

    // Handle data from client
    _clientSubscription = client.listen(
      (data) => _handleClientData(data),
      onError: (error) {
        _logger.log('[OBDProxy] Client error: $error');
        _disconnectClient();
      },
      onDone: () {
        _logger.log('[OBDProxy] Client disconnected: $clientAddr');
        _disconnectClient();
      },
    );
  }

  /// Disconnect current client
  Future<void> _disconnectClient() async {
    await _clientSubscription?.cancel();
    _clientSubscription = null;

    try {
      await _client?.close();
    } catch (e) {
      // Ignore close errors
    }
    _client = null;
    _receiveBuffer.clear();

    if (_isRunning) {
      onStatusChanged?.call(true, null);
    }
  }

  /// Handle data received from WiFi client
  Future<void> _handleClientData(List<int> data) async {
    final text = String.fromCharCodes(data);
    _logger.log('[OBDProxy] WiFi RX (${data.length} bytes): ${text.trim().replaceAll('\r', '<CR>').replaceAll('\n', '<LF>')}');

    // Accumulate data until we get a complete command (ends with \r or \n)
    _receiveBuffer.write(text);

    final buffer = _receiveBuffer.toString();

    // Check for complete command (ends with CR or LF)
    if (buffer.contains('\r') || buffer.contains('\n')) {
      // Extract the command
      final command = buffer.replaceAll('\r', '').replaceAll('\n', '').trim();
      _receiveBuffer.clear();

      if (command.isNotEmpty) {
        await _forwardCommand(command);
      }
    }
  }

  /// Forward command to Bluetooth OBD adapter and return response
  Future<void> _forwardCommand(String command) async {
    try {
      _logger.log('[OBDProxy] Processing command: "$command"');

      // Check if Bluetooth is connected
      final connected = await _bluetooth.isConnected();
      if (!connected) {
        _logger.log('[OBDProxy] ERROR: Bluetooth not connected!');
        _sendToClient('NO BLUETOOTH CONNECTION\r\n>');
        return;
      }

      _logger.log('[OBDProxy] BT TX: $command');

      // Send command to Bluetooth OBD adapter
      await _bluetooth.sendText('$command\r');

      // Wait for and collect response
      final response = await _readBluetoothResponse();

      _logger.log('[OBDProxy] BT RX: ${response.trim().replaceAll('\r', '<CR>').replaceAll('\n', '<LF>')}');

      // Forward response to WiFi client
      _sendToClient(response);
      _logger.log('[OBDProxy] Response forwarded to WiFi client');

    } catch (e) {
      _logger.log('[OBDProxy] ERROR forwarding command: $e');
      _sendToClient('ERROR\r\n>');
    }
  }

  /// Read response from Bluetooth OBD adapter
  Future<String> _readBluetoothResponse() async {
    final responseBuffer = StringBuffer();
    final stopwatch = Stopwatch()..start();

    while (stopwatch.elapsedMilliseconds < 5000) {
      final available = await _bluetooth.readAvailable();

      if (available > 0) {
        final data = await _bluetooth.readData(bufferSize: available);
        final text = String.fromCharCodes(data);
        responseBuffer.write(text);

        // Check for prompt character indicating end of response
        if (responseBuffer.toString().contains('>')) {
          // Wait a bit more for any trailing data
          await Future.delayed(const Duration(milliseconds: 50));

          final moreAvailable = await _bluetooth.readAvailable();
          if (moreAvailable > 0) {
            final moreData = await _bluetooth.readData(bufferSize: moreAvailable);
            responseBuffer.write(String.fromCharCodes(moreData));
          }

          return responseBuffer.toString();
        }
      }

      await Future.delayed(const Duration(milliseconds: 20));
    }

    // Timeout - return what we have with prompt
    final response = responseBuffer.toString();
    if (!response.contains('>')) {
      return '$response\r\n>';
    }
    return response;
  }

  /// Send data to WiFi client
  void _sendToClient(String data) {
    if (_client == null) return;

    try {
      _client!.write(data);
      _logger.log('[OBDProxy] TX to client: ${data.trim()}');
    } catch (e) {
      _logger.log('[OBDProxy] Error sending to client: $e');
    }
  }

  /// Get the device's WiFi IP addresses
  Future<List<String>> _getWiFiAddresses() async {
    final addresses = <String>[];

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        // Look for WiFi interfaces (typically wlan0 on Android)
        final name = interface.name.toLowerCase();
        if (name.contains('wlan') || name.contains('wifi') || name.contains('en')) {
          for (final addr in interface.addresses) {
            if (!addr.isLoopback) {
              addresses.add(addr.address);
            }
          }
        }
      }

      // If no WiFi interface found, include all non-loopback addresses
      if (addresses.isEmpty) {
        for (final interface in interfaces) {
          for (final addr in interface.addresses) {
            if (!addr.isLoopback) {
              addresses.add(addr.address);
            }
          }
        }
      }
    } catch (e) {
      _logger.log('[OBDProxy] Error getting IP addresses: $e');
    }

    return addresses;
  }

  /// Get connection info for display
  Future<String> getConnectionInfo() async {
    if (!_isRunning) {
      return 'Proxy not running';
    }

    final addresses = await _getWiFiAddresses();
    if (addresses.isEmpty) {
      return 'No WiFi connection\nPort: $_port';
    }

    final buffer = StringBuffer();
    buffer.writeln('OBD WiFi Proxy Active');
    buffer.writeln('Port: $_port');
    buffer.writeln('');
    buffer.writeln('Connect your OBD app to:');
    for (final addr in addresses) {
      buffer.writeln('  $addr:$_port');
    }

    if (_client != null) {
      buffer.writeln('');
      buffer.writeln('Client connected: ${_client!.remoteAddress.address}');
    }

    return buffer.toString();
  }

  void dispose() {
    stop();
  }
}
