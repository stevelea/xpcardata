import 'dart:async';
import 'dart:io';

/// Simple service to check internet connectivity by pinging a reliable host
class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  static ConnectivityService get instance => _instance;
  ConnectivityService._internal();

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  Timer? _checkTimer;
  final _statusController = StreamController<bool>.broadcast();
  Stream<bool> get statusStream => _statusController.stream;

  /// Start periodic connectivity checks
  void startMonitoring({Duration interval = const Duration(seconds: 15)}) {
    stopMonitoring();
    // Check immediately
    checkConnectivity();
    // Then check periodically
    _checkTimer = Timer.periodic(interval, (_) => checkConnectivity());
  }

  /// Stop monitoring
  void stopMonitoring() {
    _checkTimer?.cancel();
    _checkTimer = null;
  }

  /// Check connectivity by making a simple HTTP HEAD request
  Future<bool> checkConnectivity() async {
    try {
      // Try to reach Google DNS (very reliable)
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));

      final connected = result.isNotEmpty && result[0].rawAddress.isNotEmpty;

      if (connected != _isConnected) {
        _isConnected = connected;
        _statusController.add(_isConnected);
      }

      return _isConnected;
    } catch (e) {
      if (_isConnected) {
        _isConnected = false;
        _statusController.add(_isConnected);
      }
      return false;
    }
  }

  void dispose() {
    stopMonitoring();
    _statusController.close();
  }
}
