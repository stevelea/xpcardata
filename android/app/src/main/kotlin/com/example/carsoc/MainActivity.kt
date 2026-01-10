package com.example.carsoc

import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.carsoc/car_app"
    private val BLUETOOTH_CHANNEL = "com.example.carsoc/bluetooth"
    private val VPN_CHANNEL = "com.example.carsoc/vpn_status"
    private val UPDATE_CHANNEL = "com.example.carsoc/update"
    private lateinit var bluetoothHelper: BluetoothHelper

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Initialize VehicleDataStore
        VehicleDataStore.initialize(applicationContext)
        // Initialize BluetoothHelper
        bluetoothHelper = BluetoothHelper(applicationContext, this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Set up Bluetooth method channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BLUETOOTH_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "hasPermissions" -> {
                        result.success(bluetoothHelper.hasPermissions())
                    }
                    "requestPermissions" -> {
                        result.success(bluetoothHelper.requestPermissions())
                    }
                    "isBluetoothSupported" -> {
                        result.success(bluetoothHelper.isBluetoothSupported())
                    }
                    "isBluetoothEnabled" -> {
                        result.success(bluetoothHelper.isBluetoothEnabled())
                    }
                    "getPairedDevices" -> {
                        val devices = bluetoothHelper.getPairedDevices()
                        result.success(devices)
                    }
                    "connect" -> {
                        val address = call.argument<String>("address")
                        if (address != null) {
                            val connected = bluetoothHelper.connect(address)
                            result.success(connected)
                        } else {
                            result.error("INVALID_ARGUMENT", "Address is required", null)
                        }
                    }
                    "disconnect" -> {
                        bluetoothHelper.disconnect()
                        result.success(true)
                    }
                    "isConnected" -> {
                        result.success(bluetoothHelper.isConnected())
                    }
                    "sendData" -> {
                        val data = call.argument<ByteArray>("data")
                        if (data != null) {
                            bluetoothHelper.sendData(data)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGUMENT", "Data is required", null)
                        }
                    }
                    "readData" -> {
                        val bufferSize = call.argument<Int>("bufferSize") ?: 1024
                        val data = bluetoothHelper.readData(bufferSize)
                        result.success(data)
                    }
                    "readAvailable" -> {
                        result.success(bluetoothHelper.readAvailable())
                    }
                    else -> {
                        result.notImplemented()
                    }
                }
            } catch (e: SecurityException) {
                result.error("PERMISSION_DENIED", e.message, null)
            } catch (e: Exception) {
                result.error("ERROR", e.message, null)
            }
        }

        // Set up method channel for Flutter ↔ Android Auto communication
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "updateVehicleData" -> {
                    try {
                        val data = call.arguments as? Map<String, Any?>
                        if (data != null) {
                            VehicleDataStore.updateVehicleData(data)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGUMENT", "Vehicle data is null", null)
                        }
                    } catch (e: Exception) {
                        result.error("UPDATE_FAILED", e.message, null)
                    }
                }

                "requestRefresh" -> {
                    // Force refresh of Android Auto display
                    // The CarAppService will observe the LiveData and update automatically
                    result.success(true)
                }

                "isCarConnected" -> {
                    // Check if Android Auto is currently active
                    // This is a simplified check - in production you'd check the Car App Service state
                    result.success(false)
                }

                "getCurrentData" -> {
                    try {
                        val currentData = VehicleDataStore.getCurrentData()
                        if (currentData != null) {
                            // Convert to map for Flutter
                            val dataMap = mapOf(
                                "timestamp" to currentData.timestamp,
                                "stateOfCharge" to currentData.stateOfCharge,
                                "stateOfHealth" to currentData.stateOfHealth,
                                "batteryCapacity" to currentData.batteryCapacity,
                                "batteryVoltage" to currentData.batteryVoltage,
                                "batteryCurrent" to currentData.batteryCurrent,
                                "batteryTemperature" to currentData.batteryTemperature,
                                "range" to currentData.range,
                                "speed" to currentData.speed,
                                "odometer" to currentData.odometer,
                                "power" to currentData.power
                            )
                            result.success(dataMap)
                        } else {
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        result.error("GET_FAILED", e.message, null)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }

        // Set up VPN status method channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isVpnActive" -> {
                    try {
                        val isActive = isVpnActive()
                        android.util.Log.d("VpnStatus", "VPN active check result: $isActive")
                        result.success(isActive)
                    } catch (e: Exception) {
                        android.util.Log.e("VpnStatus", "VPN check failed: ${e.message}")
                        result.error("VPN_CHECK_FAILED", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Set up update method channel for APK installation
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    try {
                        val filePath = call.argument<String>("filePath")
                        if (filePath != null) {
                            val success = installApk(filePath)
                            result.success(success)
                        } else {
                            result.error("INVALID_ARGUMENT", "filePath is required", null)
                        }
                    } catch (e: Exception) {
                        result.error("INSTALL_FAILED", e.message, null)
                    }
                }
                "canRequestPackageInstalls" -> {
                    try {
                        val canInstall = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true // No permission needed on older Android
                        }
                        result.success(canInstall)
                    } catch (e: Exception) {
                        result.error("CHECK_FAILED", e.message, null)
                    }
                }
                "openInstallPermissionSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                            intent.data = Uri.parse("package:$packageName")
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(true) // No permission needed
                        }
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_FAILED", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Set up package manager method channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.carsoc/package_manager").setMethodCallHandler { call, result ->
            when (call.method) {
                "isPackageInstalled" -> {
                    try {
                        val packageName = call.argument<String>("packageName")
                        if (packageName != null) {
                            val isInstalled = isPackageInstalled(packageName)
                            result.success(isInstalled)
                        } else {
                            result.error("INVALID_ARGUMENT", "packageName is required", null)
                        }
                    } catch (e: Exception) {
                        result.error("CHECK_FAILED", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    /// Check if a package is installed
    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            packageManager.getPackageInfo(packageName, 0)
            true
        } catch (e: android.content.pm.PackageManager.NameNotFoundException) {
            false
        }
    }

    /// Check if any VPN is currently active using ConnectivityManager
    private fun isVpnActive(): Boolean {
        val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager

        // Method 1: Check active network first (most reliable on newer Android versions)
        val activeNetwork = connectivityManager.activeNetwork
        if (activeNetwork != null) {
            val activeCapabilities = connectivityManager.getNetworkCapabilities(activeNetwork)
            if (activeCapabilities != null && activeCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                android.util.Log.d("VpnStatus", "VPN detected via active network")
                return true
            }
        }

        // Method 2: Check all networks (for VPNs that may not be the active network)
        val networks = connectivityManager.allNetworks
        android.util.Log.d("VpnStatus", "Checking ${networks.size} networks for VPN")
        for (network in networks) {
            val capabilities = connectivityManager.getNetworkCapabilities(network)
            if (capabilities != null) {
                android.util.Log.d("VpnStatus", "Network capabilities: $capabilities")
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                    android.util.Log.d("VpnStatus", "VPN detected via allNetworks")
                    return true
                }
            }
        }

        // Method 3: Check network interfaces for tun/tap (fallback for older Android or edge cases)
        try {
            val networkInterfaces = java.net.NetworkInterface.getNetworkInterfaces()
            while (networkInterfaces != null && networkInterfaces.hasMoreElements()) {
                val networkInterface = networkInterfaces.nextElement()
                val name = networkInterface.name.lowercase()
                if ((name.contains("tun") || name.contains("tap") || name.contains("ppp")) && networkInterface.isUp) {
                    android.util.Log.d("VpnStatus", "VPN detected via network interface: $name")
                    return true
                }
            }
        } catch (e: Exception) {
            android.util.Log.w("VpnStatus", "Failed to check network interfaces: ${e.message}")
        }

        android.util.Log.d("VpnStatus", "No VPN detected")
        return false
    }

    /// Install APK from file path
    private fun installApk(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists()) {
                android.util.Log.e("Update", "APK file not found: $filePath")
                return false
            }

            val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                // For Android 7.0+ use FileProvider
                FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    file
                )
            } else {
                Uri.fromFile(file)
            }

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            startActivity(intent)
            true
        } catch (e: Exception) {
            android.util.Log.e("Update", "Failed to install APK: ${e.message}")
            false
        }
    }
}
