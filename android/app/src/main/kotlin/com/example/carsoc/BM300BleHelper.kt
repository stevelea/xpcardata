package com.example.carsoc

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.core.content.ContextCompat
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * BLE helper for Ancel BM300 Pro battery monitor.
 *
 * Protocol:
 * - Service: FFF0
 * - Write characteristic: FFF3
 * - Notify characteristic: FFF4
 * - Data is AES-128 CBC encrypted
 */
class BM300BleHelper(private val context: Context) {

    companion object {
        private const val TAG = "BM300BleHelper"

        // BLE UUIDs for BM300 Pro
        private val SERVICE_UUID = UUID.fromString("0000fff0-0000-1000-8000-00805f9b34fb")
        private val WRITE_CHAR_UUID = UUID.fromString("0000fff3-0000-1000-8000-00805f9b34fb")
        private val NOTIFY_CHAR_UUID = UUID.fromString("0000fff4-0000-1000-8000-00805f9b34fb")
        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        // AES encryption key for BM300 Pro / BM7 (different from BM6!)
        // Key = "leagend" + 0xFF + 0xFE + "010000@"
        // Source: https://github.com/slydiman/bm7-battery-monitor
        private val AES_KEY = byteArrayOf(
            108, 101, 97, 103, 101, 110, 100, -1,  // "leagend" + 0xFF
            -2, 48, 49, 48, 48, 48, 48, 64         // 0xFE + "010000@"
        )

        // Command to start notifications
        private val START_COMMAND = hexStringToBytes("d1550700000000000000000000000000")

        // Device name to scan for
        private const val DEVICE_NAME = "BM300 Pro"

        private fun hexStringToBytes(hex: String): ByteArray {
            val len = hex.length
            val data = ByteArray(len / 2)
            for (i in 0 until len step 2) {
                data[i / 2] = ((Character.digit(hex[i], 16) shl 4) + Character.digit(hex[i + 1], 16)).toByte()
            }
            return data
        }

        // Singleton scanner reference - needed because Android can only have one active scanner
        private var activeScanner: BluetoothLeScanner? = null
        private var activeScanCallback: ScanCallback? = null
    }

    // Callback interface
    interface BM300Callback {
        fun onDeviceFound(name: String, address: String)
        fun onScanStopped(devicesFound: Int, totalCallbacks: Int)
        fun onConnected()
        fun onDisconnected()
        fun onDataReceived(voltage: Double, soc: Int, temperature: Int)
        fun onError(message: String)
    }

    private val bluetoothManager: BluetoothManager? = try {
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    } catch (e: Exception) {
        android.util.Log.e(TAG, "Failed to get BluetoothManager: ${e.message}")
        null
    }
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager?.adapter
    private var bluetoothGatt: BluetoothGatt? = null
    private var writeCharacteristic: BluetoothGattCharacteristic? = null
    private var notifyCharacteristic: BluetoothGattCharacteristic? = null
    private var callback: BM300Callback? = null
    private var isConnected = false
    private var isScanning = false
    private var isClassicScanning = false
    private var notificationsEnabled = false  // Track if we've already enabled notifications
    private val handler = Handler(Looper.getMainLooper())

    // Handler thread for BLE operations (more reliable on some devices)
    private val bleHandlerThread = HandlerThread("BM300BleScanner").apply { start() }
    private val bleHandler = Handler(bleHandlerThread.looper)

    // Periodic command timer
    private var commandTimer: Runnable? = null
    private val COMMAND_INTERVAL_MS = 5000L  // Send command every 5 seconds

    fun setCallback(callback: BM300Callback) {
        this.callback = callback
        android.util.Log.d(TAG, "Callback SET: ${callback.hashCode()}")
    }

    fun hasCallback(): Boolean {
        val hasIt = callback != null
        android.util.Log.d(TAG, "hasCallback: $hasIt")
        return hasIt
    }

    fun hasPermissions(): Boolean {
        // BLE scanning requires location permission on all Android versions for finding new devices
        val hasLocation = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+: Need BLUETOOTH_CONNECT, BLUETOOTH_SCAN, and location
            val hasBtConnect = ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            val hasBtScan = ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
            android.util.Log.d(TAG, "Permissions: BT_CONNECT=$hasBtConnect, BT_SCAN=$hasBtScan, LOCATION=$hasLocation")
            hasBtConnect && hasBtScan && hasLocation
        } else {
            // Android 11 and below
            val hasBt = ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED
            android.util.Log.d(TAG, "Permissions: BLUETOOTH=$hasBt, LOCATION=$hasLocation")
            hasBt && hasLocation
        }
    }

    fun isBluetoothEnabled(): Boolean {
        if (bluetoothManager == null) return false
        return bluetoothAdapter?.isEnabled ?: false
    }

    fun isConnected(): Boolean = isConnected

    /**
     * Check if location services are enabled (required for BLE scanning)
     */
    fun isLocationEnabled(): Boolean {
        val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as? android.location.LocationManager
        return locationManager?.isProviderEnabled(android.location.LocationManager.GPS_PROVIDER) == true ||
               locationManager?.isProviderEnabled(android.location.LocationManager.NETWORK_PROVIDER) == true
    }

    // Classic Bluetooth discovery receiver (fallback for devices where BLE scan doesn't work)
    private var classicDiscoveryReceiver: BroadcastReceiver? = null

    /**
     * Scan for BM300 Pro devices using both BLE and classic Bluetooth discovery
     */
    @Throws(SecurityException::class)
    fun startScan(timeoutMs: Long = 10000) {
        if (!hasPermissions()) {
            callback?.onError("Bluetooth permissions not granted")
            return
        }

        // Check if location is enabled - required for BLE scanning on Android
        if (!isLocationEnabled()) {
            android.util.Log.w(TAG, "Location services are DISABLED - BLE scanning may not work!")
            // Continue anyway - classic discovery might still work
        }

        if (bluetoothManager == null) {
            callback?.onError("Bluetooth not available on this device")
            return
        }

        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            callback?.onError("Bluetooth is not enabled")
            return
        }

        if (isScanning || isClassicScanning) {
            android.util.Log.d(TAG, "Already scanning")
            return
        }

        android.util.Log.d(TAG, "Starting scan for BM300 devices...")
        android.util.Log.d(TAG, "BLE adapter: ${bluetoothAdapter?.name}, state: ${bluetoothAdapter?.state}")
        android.util.Log.d(TAG, "Context type: ${context.javaClass.simpleName}")
        android.util.Log.d(TAG, "Callback is ${if (callback != null) "SET" else "NULL"}")

        seenDevices.clear()
        reportedBM300Devices.clear()
        scanDeviceCount = 0

        // Send test callback immediately to verify callback mechanism works
        if (callback != null) {
            android.util.Log.d(TAG, "Calling onDeviceFound for TEST_DEVICE...")
            callback?.onDeviceFound("TEST_DEVICE", "00:00:00:00:00:00")
            android.util.Log.d(TAG, "TEST_DEVICE callback completed")
        } else {
            android.util.Log.e(TAG, "ERROR: callback is null! Cannot send device found events!")
        }

        // Start classic Bluetooth discovery FIRST (works on more devices including AI boxes)
        startClassicDiscovery()

        // Also try BLE scanning
        startBleScan()

        // Log progress every 3 seconds
        val progressRunnable = object : Runnable {
            var count = 0
            override fun run() {
                if (isScanning || isClassicScanning) {
                    count++
                    android.util.Log.d(TAG, "Scan progress (${count * 3}s): ${seenDevices.size} unique devices, $scanDeviceCount BLE callbacks, classic=${isClassicScanning}")
                    if (count < (timeoutMs / 3000).toInt()) {
                        handler.postDelayed(this, 3000)
                    }
                }
            }
        }
        handler.postDelayed(progressRunnable, 3000)

        // Stop all scans after timeout
        handler.postDelayed({
            stopScan()
        }, timeoutMs)
    }

    /**
     * Start classic Bluetooth discovery (fallback for AI boxes and devices where BLE doesn't work)
     */
    @Throws(SecurityException::class)
    private fun startClassicDiscovery() {
        android.util.Log.d(TAG, "Starting classic Bluetooth discovery...")

        // Register receiver for discovered devices
        classicDiscoveryReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                        val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE).toInt()

                        device?.let {
                            try {
                                val deviceName = it.name
                                val deviceAddress = it.address

                                // Log all discovered devices
                                val isNewDevice = !seenDevices.contains(deviceAddress)
                                if (isNewDevice) {
                                    seenDevices.add(deviceAddress)
                                    android.util.Log.d(TAG, "Classic #${seenDevices.size}: name='$deviceName' addr=$deviceAddress rssi=$rssi")

                                    // DEBUG MODE: Report ALL devices to Flutter
                                    val displayName = deviceName ?: "Unknown (${deviceAddress.takeLast(5)})"
                                    callback?.onDeviceFound(displayName, deviceAddress)
                                }

                                // Also check if this looks like a BM300 device for logging
                                val isBM300 = when {
                                    deviceName == null -> false
                                    deviceName == DEVICE_NAME -> true
                                    deviceName.matches(Regex("^[0-9A-Fa-f]{12}$")) -> true
                                    deviceName.startsWith("BM") -> true
                                    deviceName.contains("BM300", ignoreCase = true) -> true
                                    deviceName.contains("BM6", ignoreCase = true) -> true
                                    deviceName.contains("Ancel", ignoreCase = true) -> true
                                    else -> false
                                }

                                if (isBM300 && !reportedBM300Devices.contains(deviceAddress)) {
                                    reportedBM300Devices.add(deviceAddress)
                                    android.util.Log.d(TAG, "*** CLASSIC MATCH! BM300 device: $deviceName ($deviceAddress) rssi=$rssi ***")
                                }
                            } catch (e: SecurityException) {
                                android.util.Log.e(TAG, "Security exception in classic discovery: ${e.message}")
                            }
                        }
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_STARTED -> {
                        android.util.Log.d(TAG, "Classic discovery started")
                        isClassicScanning = true
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                        android.util.Log.d(TAG, "Classic discovery finished")
                        isClassicScanning = false
                    }
                }
            }
        }

        // Register receiver
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(classicDiscoveryReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(classicDiscoveryReceiver, filter)
        }

        // Start discovery
        try {
            // Cancel any ongoing discovery first
            if (bluetoothAdapter?.isDiscovering == true) {
                bluetoothAdapter.cancelDiscovery()
            }
            val started = bluetoothAdapter?.startDiscovery() ?: false
            android.util.Log.d(TAG, "Classic discovery startDiscovery() returned: $started")
            isClassicScanning = started
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Failed to start classic discovery: ${e.message}")
        }
    }

    /**
     * Start BLE scanning
     */
    @Throws(SecurityException::class)
    private fun startBleScan() {
        val scanner: BluetoothLeScanner? = bluetoothAdapter?.bluetoothLeScanner
        if (scanner == null) {
            android.util.Log.w(TAG, "BLE scanner not available, using classic discovery only")
            return
        }

        // Stop any previously active scan first
        try {
            activeScanCallback?.let { oldCallback ->
                activeScanner?.stopScan(oldCallback)
            }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "Error stopping previous BLE scan: ${e.message}")
        }

        android.util.Log.d(TAG, "Starting BLE scan...")

        // Use LOW_LATENCY mode for fastest device discovery
        val scanSettings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
            .setReportDelay(0)
            .build()

        try {
            activeScanner = scanner
            activeScanCallback = scanCallback
            scanner.startScan(null, scanSettings, scanCallback)
            isScanning = true
            android.util.Log.d(TAG, "BLE scan started successfully")
        } catch (e: Exception) {
            android.util.Log.e(TAG, "BLE scan failed: ${e.message}")
            isScanning = false
            activeScanner = null
            activeScanCallback = null
        }
    }

    @Throws(SecurityException::class)
    fun stopScan() {
        val wasScanning = isScanning || isClassicScanning

        // Stop BLE scan
        if (isScanning) {
            try {
                activeScanCallback?.let { cb ->
                    activeScanner?.stopScan(cb)
                }
            } catch (e: Exception) {
                android.util.Log.e(TAG, "Error stopping BLE scan: ${e.message}")
            }
            isScanning = false
            activeScanner = null
            activeScanCallback = null
        }

        // Stop classic discovery
        if (isClassicScanning) {
            try {
                bluetoothAdapter?.cancelDiscovery()
            } catch (e: Exception) {
                android.util.Log.e(TAG, "Error stopping classic discovery: ${e.message}")
            }
            isClassicScanning = false
        }

        // Unregister receiver
        classicDiscoveryReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: Exception) {
                android.util.Log.w(TAG, "Error unregistering receiver: ${e.message}")
            }
            classicDiscoveryReceiver = null
        }

        if (wasScanning) {
            val devicesFound = seenDevices.size
            val totalCalls = scanDeviceCount
            android.util.Log.d(TAG, "All scans stopped - saw $devicesFound unique devices, $totalCalls BLE callbacks, ${reportedBM300Devices.size} BM300 matches")
            callback?.onScanStopped(devicesFound, totalCalls)
        }
    }

    // Track devices we've already seen during this scan (for logging)
    private val seenDevices = mutableSetOf<String>()
    // Track BM300 devices we've already reported to Flutter
    private val reportedBM300Devices = mutableSetOf<String>()
    private var scanDeviceCount = 0

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            scanDeviceCount++

            // Log first callback to confirm scanning is working
            if (scanDeviceCount == 1) {
                android.util.Log.d(TAG, "*** FIRST BLE CALLBACK RECEIVED! Scanner is working ***")
            }

            try {
                val deviceName = result.device.name
                val deviceAddress = result.device.address
                val rssi = result.rssi
                val scanRecord = result.scanRecord

                // Check if device advertises FFF0 service UUID
                val serviceUuids = scanRecord?.serviceUuids
                val hasFFF0Service = serviceUuids?.any { it.uuid == SERVICE_UUID } ?: false

                // Log ALL devices for debugging (first time we see them)
                val isNewDevice = !seenDevices.contains(deviceAddress)
                if (isNewDevice) {
                    seenDevices.add(deviceAddress)
                    val servicesStr = serviceUuids?.joinToString(",") { it.uuid.toString().substring(4, 8) } ?: "none"
                    android.util.Log.d(TAG, "BLE #${seenDevices.size}: name='$deviceName' addr=$deviceAddress rssi=$rssi services=[$servicesStr] hasFFF0=$hasFFF0Service")
                }

                // DEBUG MODE: Report ALL devices to Flutter for debugging
                // This helps identify what the BM300 advertises as
                if (isNewDevice) {
                    val displayName = deviceName ?: "Unknown (${deviceAddress.takeLast(5)})"
                    callback?.onDeviceFound(displayName, deviceAddress)
                }

                // Also check if this looks like a BM300 Pro device for logging:
                // 1. Device advertises FFF0 service UUID (most reliable)
                // 2. Named exactly "BM300 Pro"
                // 3. Name is a 12-character hex string (serial number like "3CAB72B2A9C0")
                // 4. Name contains "BM" prefix or brand names
                val isBM300 = when {
                    hasFFF0Service -> true  // Has FFF0 service - definitely a BM300/BM6 type device
                    deviceName == null -> false
                    deviceName == DEVICE_NAME -> true
                    deviceName.matches(Regex("^[0-9A-Fa-f]{12}$")) -> true  // 12 hex chars (serial number)
                    deviceName.startsWith("BM") -> true  // BM prefix variations
                    deviceName.contains("BM300", ignoreCase = true) -> true  // Contains BM300
                    deviceName.contains("BM6", ignoreCase = true) -> true  // BM6 variant
                    deviceName.contains("Ancel", ignoreCase = true) -> true  // Ancel brand
                    deviceName.contains("Battery", ignoreCase = true) && deviceName.contains("Monitor", ignoreCase = true) -> true
                    else -> false
                }

                if (isBM300 && !reportedBM300Devices.contains(deviceAddress)) {
                    reportedBM300Devices.add(deviceAddress)
                    android.util.Log.d(TAG, "*** MATCH! BM300 device: $deviceName ($deviceAddress) rssi=$rssi hasFFF0=$hasFFF0Service ***")
                }
            } catch (e: SecurityException) {
                android.util.Log.e(TAG, "Security exception in scan callback: ${e.message}")
            }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            android.util.Log.d(TAG, "Batch scan results: ${results.size} devices")
            for (result in results) {
                onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, result)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            val errorName = when (errorCode) {
                SCAN_FAILED_ALREADY_STARTED -> "ALREADY_STARTED"
                SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "APP_REGISTRATION_FAILED"
                SCAN_FAILED_INTERNAL_ERROR -> "INTERNAL_ERROR"
                SCAN_FAILED_FEATURE_UNSUPPORTED -> "FEATURE_UNSUPPORTED"
                5 -> "OUT_OF_HARDWARE_RESOURCES"
                6 -> "SCANNING_TOO_FREQUENTLY"
                else -> "UNKNOWN($errorCode)"
            }
            android.util.Log.e(TAG, "Scan failed: $errorName (code $errorCode)")
            isScanning = false
            activeScanner = null
            activeScanCallback = null
            callback?.onError("BLE scan failed: $errorName")
        }
    }

    /**
     * Connect to a BM300 Pro device by address
     */
    @Throws(SecurityException::class)
    fun connect(address: String) {
        if (!hasPermissions()) {
            callback?.onError("Bluetooth permissions not granted")
            return
        }

        if (bluetoothManager == null || bluetoothAdapter == null) {
            callback?.onError("Bluetooth not available")
            return
        }

        stopScan()

        val device = bluetoothAdapter.getRemoteDevice(address)
        if (device == null) {
            callback?.onError("Device not found: $address")
            return
        }

        android.util.Log.d(TAG, "Connecting to $address")
        bluetoothGatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    /**
     * Disconnect from the device
     */
    @Throws(SecurityException::class)
    fun disconnect() {
        stopCommandTimer()

        try {
            bluetoothGatt?.disconnect()
            bluetoothGatt?.close()
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error disconnecting: ${e.message}")
        }

        bluetoothGatt = null
        writeCharacteristic = null
        notifyCharacteristic = null
        isConnected = false
        notificationsEnabled = false
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            android.util.Log.d(TAG, "Connection state changed: $newState (status: $status)")

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    android.util.Log.d(TAG, "Connected, discovering services...")
                    try {
                        gatt.discoverServices()
                    } catch (e: SecurityException) {
                        callback?.onError("Permission denied for service discovery")
                    }
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    isConnected = false
                    stopCommandTimer()
                    handler.post { callback?.onDisconnected() }
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                android.util.Log.e(TAG, "Service discovery failed: $status")
                handler.post { callback?.onError("Service discovery failed") }
                return
            }

            android.util.Log.d(TAG, "Services discovered")
            handler.post { callback?.onError("GATT: services discovered") }

            // Find the FFF0 service
            val service = gatt.getService(SERVICE_UUID)
            if (service == null) {
                android.util.Log.e(TAG, "Service $SERVICE_UUID not found")
                handler.post { callback?.onError("BM300 service not found") }
                return
            }

            android.util.Log.d(TAG, "Found FFF0 service")
            handler.post { callback?.onError("GATT: found FFF0 service") }

            // Get characteristics
            writeCharacteristic = service.getCharacteristic(WRITE_CHAR_UUID)
            notifyCharacteristic = service.getCharacteristic(NOTIFY_CHAR_UUID)

            if (writeCharacteristic == null || notifyCharacteristic == null) {
                android.util.Log.e(TAG, "Characteristics not found: write=${writeCharacteristic != null}, notify=${notifyCharacteristic != null}")
                handler.post { callback?.onError("BM300 characteristics not found") }
                return
            }

            android.util.Log.d(TAG, "Found FFF3 and FFF4 characteristics")
            handler.post { callback?.onError("GATT: found FFF3/FFF4 chars") }

            // Python implementation sends command FIRST, then enables notifications
            // IMPORTANT: Command must be AES encrypted!
            try {
                // Step 1: Send the ENCRYPTED start command to FFF3 first (like Python does)
                android.util.Log.d(TAG, "Step 1: Encrypting and sending start command to FFF3...")
                val encryptedCommand = encryptAes(START_COMMAND)
                val cmdHex = encryptedCommand.joinToString("") { "%02x".format(it) }
                android.util.Log.d(TAG, "Encrypted command: $cmdHex")
                handler.post { callback?.onError("GATT: writing ENCRYPTED command to FFF3") }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeCharacteristic(writeCharacteristic!!, encryptedCommand, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                } else {
                    @Suppress("DEPRECATION")
                    writeCharacteristic!!.value = encryptedCommand
                    @Suppress("DEPRECATION")
                    gatt.writeCharacteristic(writeCharacteristic)
                }
                // onCharacteristicWrite will be called, then we enable notifications
            } catch (e: SecurityException) {
                handler.post { callback?.onError("Permission denied for write: ${e.message}") }
            } catch (e: Exception) {
                android.util.Log.e(TAG, "Error encrypting/sending command: ${e.message}")
                handler.post { callback?.onError("Encrypt/send error: ${e.message}") }
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            android.util.Log.d(TAG, "onDescriptorWrite: status=$status, uuid=${descriptor.uuid}")
            handler.post { callback?.onError("GATT: descriptor write status=$status") }

            if (status == BluetoothGatt.GATT_SUCCESS && descriptor.uuid == CCCD_UUID && !notificationsEnabled) {
                notificationsEnabled = true
                android.util.Log.d(TAG, "Notifications enabled successfully!")
                handler.post { callback?.onError("GATT: notifications enabled, waiting for data...") }
                isConnected = true
                handler.post { callback?.onConnected() }

                // Command was already sent before enabling notifications (like Python does)
                // Start the periodic timer to keep sending commands
                android.util.Log.d(TAG, "Starting command timer...")
                startCommandTimer()
            } else if (status != BluetoothGatt.GATT_SUCCESS) {
                android.util.Log.e(TAG, "onDescriptorWrite FAILED: status=$status")
                handler.post { callback?.onError("GATT: descriptor write FAILED status=$status") }
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            android.util.Log.d(TAG, "onCharacteristicWrite: status=$status, uuid=${characteristic.uuid}")
            handler.post { callback?.onError("GATT: char write status=$status uuid=${characteristic.uuid.toString().substring(4,8)}") }

            // If this was the FFF3 write (command), enable notifications on FFF4 (but only once!)
            if (characteristic.uuid == WRITE_CHAR_UUID && status == BluetoothGatt.GATT_SUCCESS && !notificationsEnabled) {
                android.util.Log.d(TAG, "Initial command written, now enabling notifications on FFF4")
                handler.post { callback?.onError("GATT: enabling notifications (first time)") }

                try {
                    gatt.setCharacteristicNotification(notifyCharacteristic, true)

                    val descriptor = notifyCharacteristic!!.getDescriptor(CCCD_UUID)
                    if (descriptor != null) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                        } else {
                            @Suppress("DEPRECATION")
                            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                            @Suppress("DEPRECATION")
                            gatt.writeDescriptor(descriptor)
                        }
                        android.util.Log.d(TAG, "Enabling notifications on FFF4...")
                    } else {
                        android.util.Log.e(TAG, "CCCD descriptor not found!")
                        handler.post { callback?.onError("GATT: CCCD descriptor not found!") }
                    }
                } catch (e: SecurityException) {
                    handler.post { callback?.onError("Permission denied for notifications: ${e.message}") }
                }
            } else if (characteristic.uuid == WRITE_CHAR_UUID && status == BluetoothGatt.GATT_SUCCESS) {
                // This is a periodic command write (notifications already enabled)
                android.util.Log.d(TAG, "Periodic command written OK")
            }
        }

        @Deprecated("Deprecated in API 33")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            android.util.Log.d(TAG, "onCharacteristicChanged (deprecated API)")
            if (characteristic.uuid == NOTIFY_CHAR_UUID) {
                try {
                    @Suppress("DEPRECATION")
                    val data = characteristic.value
                    if (data != null) {
                        val rawHex = data.joinToString("") { "%02x".format(it) }
                        android.util.Log.d(TAG, "DEP-NOTIFY[${data.size}]: $rawHex")
                        handler.post { callback?.onError("DEP-NOTIFY[${data.size}]: $rawHex") }
                        processNotification(data)
                    }
                } catch (e: Exception) {
                    android.util.Log.e(TAG, "deprecated onCharacteristicChanged error: ${e.message}")
                    handler.post { callback?.onError("DEP-NOTIFY ERROR: ${e.message}") }
                }
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            android.util.Log.d(TAG, "onCharacteristicChanged (new API)")
            if (characteristic.uuid == NOTIFY_CHAR_UUID) {
                try {
                    val rawHex = value.joinToString("") { "%02x".format(it) }
                    android.util.Log.d(TAG, "NEW-NOTIFY[${value.size}]: $rawHex")
                    handler.post { callback?.onError("NEW-NOTIFY[${value.size}]: $rawHex") }
                    processNotification(value)
                } catch (e: Exception) {
                    android.util.Log.e(TAG, "new onCharacteristicChanged error: ${e.message}")
                    handler.post { callback?.onError("NEW-NOTIFY ERROR: ${e.message}") }
                }
            }
        }
    }

    private fun sendCommand() {
        val gatt = bluetoothGatt
        val char = writeCharacteristic

        if (gatt == null) {
            android.util.Log.e(TAG, "sendCommand: bluetoothGatt is null!")
            handler.post { callback?.onError("sendCommand: gatt is null!") }
            return
        }
        if (char == null) {
            android.util.Log.e(TAG, "sendCommand: writeCharacteristic is null!")
            handler.post { callback?.onError("sendCommand: writeChar is null!") }
            return
        }

        try {
            // IMPORTANT: The command must be AES encrypted before sending (like Python does)
            val encryptedCommand = encryptAes(START_COMMAND)
            val cmdHex = encryptedCommand.joinToString("") { "%02x".format(it) }
            android.util.Log.d(TAG, "Sending ENCRYPTED command: $cmdHex")
            handler.post { callback?.onError("sendCommand: encrypted ${encryptedCommand.size} bytes") }

            val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(char, encryptedCommand, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            } else {
                @Suppress("DEPRECATION")
                char.value = encryptedCommand
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(char)
            }
            android.util.Log.d(TAG, "Command write result: $result")
            handler.post { callback?.onError("sendCommand: result=$result") }
        } catch (e: SecurityException) {
            android.util.Log.e(TAG, "Permission denied sending command: ${e.message}")
            handler.post { callback?.onError("sendCommand: SecurityException: ${e.message}") }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error sending command: ${e.message}")
            handler.post { callback?.onError("sendCommand: Exception: ${e.message}") }
        }
    }

    private fun startCommandTimer() {
        stopCommandTimer()

        commandTimer = object : Runnable {
            override fun run() {
                if (isConnected) {
                    sendCommand()
                    handler.postDelayed(this, COMMAND_INTERVAL_MS)
                }
            }
        }
        handler.postDelayed(commandTimer!!, COMMAND_INTERVAL_MS)
    }

    private fun stopCommandTimer() {
        commandTimer?.let { handler.removeCallbacks(it) }
        commandTimer = null
    }

    private fun processNotification(encryptedData: ByteArray) {
        try {
            val encHex = encryptedData.joinToString("") { "%02x".format(it) }
            android.util.Log.d(TAG, "Encrypted data: $encHex")
            handler.post { callback?.onError("decrypt: enc=$encHex") }

            // Decrypt the data
            val decrypted = decryptAes(encryptedData)
            val hexString = decrypted.joinToString("") { "%02x".format(it) }

            android.util.Log.d(TAG, "Decrypted: $hexString")
            handler.post { callback?.onError("decrypt: dec=$hexString") }

            // Validate header
            if (!hexString.startsWith("d1550700")) {
                android.util.Log.d(TAG, "Invalid header, ignoring")
                handler.post { callback?.onError("decrypt: INVALID header (expected d1550700)") }
                return
            }

            // Parse data based on Python bm7-battery-monitor implementation
            // Hex string format: d15507001b003c052600000000000000
            //                    0         1
            //                    0123456789012345678
            // Temperature sign: hex[6:8] = "00" positive, "01" negative
            // Temperature value: hex[8:10] = value in Celsius
            // SOC: hex[12:14] = percentage
            // Voltage: hex[15:18] = 3 hex chars, divide by 100 for volts

            if (hexString.length >= 18) {
                val tempSign = hexString.substring(6, 8)
                val tempHex = hexString.substring(8, 10)
                val socHex = hexString.substring(12, 14)
                val voltageHex = hexString.substring(15, 18)  // 3 chars: positions 15,16,17

                var temperature = tempHex.toInt(16)
                if (tempSign == "01") temperature = -temperature
                val soc = socHex.toInt(16)
                val voltage = voltageHex.toInt(16) / 100.0

                android.util.Log.d(TAG, "Parsed: Voltage=${voltage}V, SOC=$soc%, Temp=$temperature°C")
                handler.post { callback?.onError("PARSED: ${voltage}V, $soc%, ${temperature}C") }

                handler.post { callback?.onDataReceived(voltage, soc, temperature) }
            } else {
                handler.post { callback?.onError("decrypt: hex too short (${hexString.length} < 18)") }
            }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error processing notification: ${e.message}")
            handler.post { callback?.onError("decrypt ERROR: ${e.message}") }
        }
    }

    private fun decryptAes(encryptedData: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/CBC/NoPadding")
        val keySpec = SecretKeySpec(AES_KEY, "AES")
        val ivSpec = IvParameterSpec(ByteArray(16))  // Zero IV
        cipher.init(Cipher.DECRYPT_MODE, keySpec, ivSpec)
        return cipher.doFinal(encryptedData)
    }

    private fun encryptAes(plainData: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/CBC/NoPadding")
        val keySpec = SecretKeySpec(AES_KEY, "AES")
        val ivSpec = IvParameterSpec(ByteArray(16))  // Zero IV
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, ivSpec)
        return cipher.doFinal(plainData)
    }

    fun dispose() {
        stopScan()
        disconnect()
        // Clean up handler thread
        try {
            bleHandlerThread.quitSafely()
        } catch (e: Exception) {
            android.util.Log.w(TAG, "Error stopping handler thread: ${e.message}")
        }
    }
}
