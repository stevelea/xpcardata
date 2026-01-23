package com.example.carsoc

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
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

        // AES encryption key for BM300 Pro
        private val AES_KEY = byteArrayOf(
            108, 101, 97, 103, 101, 110, 100, -1,  // "legeng" + 0xFF 0xFE
            -2, 48, 49, 48, 48, 48, 48, 64         // "010000@"
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
    }

    // Callback interface
    interface BM300Callback {
        fun onDeviceFound(name: String, address: String)
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
    private val handler = Handler(Looper.getMainLooper())

    // Periodic command timer
    private var commandTimer: Runnable? = null
    private val COMMAND_INTERVAL_MS = 5000L  // Send command every 5 seconds

    fun setCallback(callback: BM300Callback) {
        this.callback = callback
    }

    fun hasPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun isBluetoothEnabled(): Boolean {
        if (bluetoothManager == null) return false
        return bluetoothAdapter?.isEnabled ?: false
    }

    fun isConnected(): Boolean = isConnected

    /**
     * Scan for BM300 Pro devices
     */
    @Throws(SecurityException::class)
    fun startScan(timeoutMs: Long = 10000) {
        if (!hasPermissions()) {
            callback?.onError("Bluetooth permissions not granted")
            return
        }

        if (bluetoothManager == null) {
            callback?.onError("Bluetooth not available on this device")
            return
        }

        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            callback?.onError("Bluetooth is not enabled")
            return
        }

        val scanner: BluetoothLeScanner? = bluetoothAdapter.bluetoothLeScanner
        if (scanner == null) {
            callback?.onError("BLE scanner not available")
            return
        }

        if (isScanning) {
            android.util.Log.d(TAG, "Already scanning")
            return
        }

        android.util.Log.d(TAG, "Starting BLE scan for BM300 devices (service UUID: $SERVICE_UUID)")
        isScanning = true
        reportedDevices.clear()  // Clear previously found devices

        val scanSettings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        // Create scan filter for devices advertising the FFF0 service UUID
        val serviceFilter = ScanFilter.Builder()
            .setServiceUuid(android.os.ParcelUuid(SERVICE_UUID))
            .build()

        // Also scan without filter to catch devices that don't advertise service UUID
        // We'll filter in the callback by checking both name and service data
        android.util.Log.d(TAG, "Scanning with service UUID filter AND unfiltered scan")

        // Start unfiltered scan (filter in callback) - more reliable for catching all devices
        scanner.startScan(null, scanSettings, scanCallback)

        // Stop scan after timeout
        handler.postDelayed({
            stopScan()
        }, timeoutMs)
    }

    @Throws(SecurityException::class)
    fun stopScan() {
        if (!isScanning) return

        try {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
            isScanning = false
            android.util.Log.d(TAG, "Scan stopped")
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error stopping scan: ${e.message}")
        }
    }

    // Track devices we've already reported to avoid duplicates
    private val reportedDevices = mutableSetOf<String>()

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            try {
                val deviceName = result.device.name
                val deviceAddress = result.device.address
                val scanRecord = result.scanRecord

                // Check if device advertises FFF0 service UUID
                val serviceUuids = scanRecord?.serviceUuids
                val hasFFF0Service = serviceUuids?.any { it.uuid == SERVICE_UUID } ?: false

                // Log ALL devices for debugging (first time we see them)
                if (!reportedDevices.contains(deviceAddress)) {
                    val servicesStr = serviceUuids?.joinToString(",") { it.uuid.toString().substring(4, 8) } ?: "none"
                    android.util.Log.d(TAG, "BLE device: name='$deviceName' addr=$deviceAddress services=[$servicesStr] hasFFF0=$hasFFF0Service")
                }

                // Check if this looks like a BM300 Pro device:
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

                if (isBM300 && !reportedDevices.contains(deviceAddress)) {
                    reportedDevices.add(deviceAddress)
                    val displayName = deviceName ?: if (hasFFF0Service) "BM Battery Monitor" else "BM300"
                    android.util.Log.d(TAG, "*** Found BM300 device: $displayName ($deviceAddress) hasFFF0=$hasFFF0Service ***")
                    callback?.onDeviceFound(displayName, deviceAddress)
                }
            } catch (e: SecurityException) {
                android.util.Log.e(TAG, "Security exception in scan callback: ${e.message}")
            }
        }

        override fun onScanFailed(errorCode: Int) {
            android.util.Log.e(TAG, "Scan failed with error: $errorCode")
            isScanning = false
            callback?.onError("BLE scan failed: $errorCode")
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

            // Find the FFF0 service
            val service = gatt.getService(SERVICE_UUID)
            if (service == null) {
                android.util.Log.e(TAG, "Service $SERVICE_UUID not found")
                handler.post { callback?.onError("BM300 service not found") }
                return
            }

            // Get characteristics
            writeCharacteristic = service.getCharacteristic(WRITE_CHAR_UUID)
            notifyCharacteristic = service.getCharacteristic(NOTIFY_CHAR_UUID)

            if (writeCharacteristic == null || notifyCharacteristic == null) {
                android.util.Log.e(TAG, "Characteristics not found")
                handler.post { callback?.onError("BM300 characteristics not found") }
                return
            }

            // Enable notifications on FFF4
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
                    android.util.Log.d(TAG, "Notification enabled on FFF4")
                }
            } catch (e: SecurityException) {
                handler.post { callback?.onError("Permission denied for notifications") }
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS && descriptor.uuid == CCCD_UUID) {
                android.util.Log.d(TAG, "Notifications enabled, sending start command")
                isConnected = true
                handler.post { callback?.onConnected() }

                // Send initial command and start periodic timer
                sendCommand()
                startCommandTimer()
            }
        }

        @Deprecated("Deprecated in API 33")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (characteristic.uuid == NOTIFY_CHAR_UUID) {
                @Suppress("DEPRECATION")
                processNotification(characteristic.value)
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (characteristic.uuid == NOTIFY_CHAR_UUID) {
                processNotification(value)
            }
        }
    }

    private fun sendCommand() {
        val gatt = bluetoothGatt ?: return
        val char = writeCharacteristic ?: return

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(char, START_COMMAND, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            } else {
                @Suppress("DEPRECATION")
                char.value = START_COMMAND
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(char)
            }
            android.util.Log.d(TAG, "Command sent")
        } catch (e: SecurityException) {
            android.util.Log.e(TAG, "Permission denied sending command: ${e.message}")
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
            // Decrypt the data
            val decrypted = decryptAes(encryptedData)
            val hexString = decrypted.joinToString("") { "%02x".format(it) }

            android.util.Log.d(TAG, "Decrypted: $hexString")

            // Validate header
            if (!hexString.startsWith("d1550700")) {
                android.util.Log.d(TAG, "Invalid header, ignoring")
                return
            }

            // Parse data (based on Python implementation)
            // Voltage: bytes 15-17 (hex positions 30-35), divided by 100
            // SOC: bytes 12-13 (hex positions 24-27)
            // Temperature: bytes 8-9 (hex positions 16-19), negative if byte 6 = "01"

            if (hexString.length >= 36) {
                val voltageHex = hexString.substring(30, 34)
                val socHex = hexString.substring(24, 26)
                val tempHex = hexString.substring(16, 18)
                val negativeTemp = hexString.substring(12, 14) == "01"

                val voltage = voltageHex.toInt(16) / 100.0
                val soc = socHex.toInt(16)
                var temperature = tempHex.toInt(16)
                if (negativeTemp) temperature = -temperature

                android.util.Log.d(TAG, "Parsed: Voltage=${voltage}V, SOC=$soc%, Temp=$temperature°C")

                handler.post { callback?.onDataReceived(voltage, soc, temperature) }
            }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error processing notification: ${e.message}")
        }
    }

    private fun decryptAes(encryptedData: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/CBC/NoPadding")
        val keySpec = SecretKeySpec(AES_KEY, "AES")
        val ivSpec = IvParameterSpec(ByteArray(16))  // Zero IV
        cipher.init(Cipher.DECRYPT_MODE, keySpec, ivSpec)
        return cipher.doFinal(encryptedData)
    }

    fun dispose() {
        stopScan()
        disconnect()
    }
}
