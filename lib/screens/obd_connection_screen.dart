import 'package:flutter/material.dart';
import '../services/native_bluetooth_service.dart';
import '../services/obd_service.dart';
import '../services/debug_logger.dart';

class OBDConnectionScreen extends StatefulWidget {
  final OBDService obdService;

  const OBDConnectionScreen({super.key, required this.obdService});

  @override
  State<OBDConnectionScreen> createState() => _OBDConnectionScreenState();
}

class _OBDConnectionScreenState extends State<OBDConnectionScreen> {
  final _logger = DebugLogger.instance;
  final _bluetooth = NativeBluetoothService();

  List<NativeBluetoothDevice> _devices = [];
  bool _isScanning = false;
  bool _isConnecting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _logger.log('[OBDConnectionScreen] initState called - using native Bluetooth');
    _loadPairedDevices();
  }

  Future<void> _loadPairedDevices() async {
    try {
      _logger.log('[OBDConnectionScreen] Loading paired devices...');
      setState(() {
        _isScanning = true;
        _errorMessage = null;
      });

      // Check and request permissions
      _logger.log('[OBDConnectionScreen] Checking permissions...');
      bool hasPermissions = await _bluetooth.hasPermissions();
      _logger.log('[OBDConnectionScreen] Has permissions: $hasPermissions');

      if (!hasPermissions) {
        _logger.log('[OBDConnectionScreen] Requesting permissions...');
        hasPermissions = await _bluetooth.requestPermissions();
        // Wait a bit for permission dialog to complete
        await Future.delayed(const Duration(seconds: 1));
        hasPermissions = await _bluetooth.hasPermissions();
        _logger.log('[OBDConnectionScreen] Permissions granted: $hasPermissions');
      }

      if (!hasPermissions) {
        setState(() {
          _isScanning = false;
          _errorMessage = 'Bluetooth permissions are required';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please grant Bluetooth permissions in Settings'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // Check if Bluetooth is supported
      _logger.log('[OBDConnectionScreen] Checking Bluetooth support...');
      final isSupported = await _bluetooth.isBluetoothSupported();
      _logger.log('[OBDConnectionScreen] Bluetooth supported: $isSupported');

      if (!isSupported) {
        setState(() {
          _isScanning = false;
          _errorMessage = 'Bluetooth not supported on this device';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Bluetooth is not supported on this device'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // Check if Bluetooth is enabled
      final isEnabled = await _bluetooth.isBluetoothEnabled();
      _logger.log('[OBDConnectionScreen] Bluetooth enabled: $isEnabled');

      if (!isEnabled) {
        setState(() {
          _isScanning = false;
          _errorMessage = 'Please enable Bluetooth in device settings';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please enable Bluetooth in device settings'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // Get paired devices
      _logger.log('[OBDConnectionScreen] Getting paired devices...');
      final devices = await _bluetooth.getPairedDevices();
      _logger.log('[OBDConnectionScreen] Found ${devices.length} devices');

      setState(() {
        _devices = devices;
        _isScanning = false;
        _errorMessage = devices.isEmpty ? 'No paired devices found' : null;
      });

      if (devices.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No paired Bluetooth devices found. Please pair your OBD adapter in phone Settings first.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.log('[OBDConnectionScreen] Error loading devices: $e');
      _logger.log('[OBDConnectionScreen] Stack trace: $stackTrace');
      setState(() {
        _isScanning = false;
        _errorMessage = 'Error: $e';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading devices: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _connectToDevice(NativeBluetoothDevice device) async {
    if (!mounted) return;
    setState(() => _isConnecting = true);

    final success = await widget.obdService.connect(device.address);

    // Check if widget is still mounted before updating state
    if (!mounted) return;
    setState(() => _isConnecting = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connected to ${device.displayName}'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to connect to OBD adapter'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect to OBD-II'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isScanning ? null : _loadPairedDevices,
          ),
        ],
      ),
      body: Column(
        children: [
          // Error message
          if (_errorMessage != null && !_isScanning)
            Container(
              color: Colors.red.shade100,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.error, color: Colors.red),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                  TextButton(
                    onPressed: _loadPairedDevices,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),

          // Connection status
          if (widget.obdService.isConnected)
            Container(
              color: Colors.green.shade100,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.bluetooth_connected, color: Colors.green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Connected to ${widget.obdService.connectedDevice}',
                      style: const TextStyle(color: Colors.green),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await widget.obdService.disconnect();
                      setState(() {});
                    },
                    child: const Text('Disconnect'),
                  ),
                ],
              ),
            ),

          // Instructions
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Instructions:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8),
                    Text('1. Pair your ELM327 Bluetooth adapter in phone settings'),
                    Text('2. Plug the adapter into your car\'s OBD-II port'),
                    Text('3. Turn on your car\'s ignition'),
                    Text('4. Select your adapter from the list below'),
                    SizedBox(height: 8),
                    Text(
                      'ℹ️ Using native Bluetooth (works on Android 4.4-15+)',
                      style: TextStyle(fontSize: 12, color: Colors.blue),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Device list
          if (_isScanning)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Searching for paired devices...'),
                  ],
                ),
              ),
            )
          else if (_devices.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.bluetooth_disabled, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text(
                      'No paired Bluetooth devices found',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please pair your OBD adapter in phone Settings',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _loadPairedDevices,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: _devices.length,
                itemBuilder: (context, index) {
                  final device = _devices[index];
                  final isELM327 = device.name.toUpperCase().contains('OBD') ||
                      device.name.toUpperCase().contains('ELM') ||
                      device.name.toUpperCase().contains('327');

                  return ListTile(
                    leading: Icon(
                      isELM327 ? Icons.car_repair : Icons.bluetooth,
                      color: isELM327 ? Colors.blue : null,
                    ),
                    title: Text(device.displayName),
                    subtitle: Text(device.address),
                    trailing: _isConnecting
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: _isConnecting
                        ? null
                        : () => _connectToDevice(device),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
