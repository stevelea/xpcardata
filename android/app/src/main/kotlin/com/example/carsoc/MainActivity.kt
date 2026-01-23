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
    private val LOCATION_CHANNEL = "com.example.carsoc/location"
    private val APP_LIFECYCLE_CHANNEL = "com.example.carsoc/app_lifecycle"
    private val KEEP_ALIVE_CHANNEL = "com.example.carsoc/keep_alive"
    private val BM300_CHANNEL = "com.example.carsoc/bm300"
    private lateinit var bluetoothHelper: BluetoothHelper
    private lateinit var locationHelper: LocationHelper
    private var bm300Helper: BM300BleHelper? = null
    private var shouldMinimiseOnStart = false
    private var stayInBackground = false
    private var wasInBackground = false

    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val STAY_IN_BACKGROUND_KEY = "flutter.stay_in_background"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Initialize VehicleDataStore
        VehicleDataStore.initialize(applicationContext)
        // Initialize BluetoothHelper
        bluetoothHelper = BluetoothHelper(applicationContext, this)
        // Initialize LocationHelper
        locationHelper = LocationHelper(applicationContext)
        // Initialize BM300 BLE Helper (with error handling for devices without BLE)
        try {
            bm300Helper = BM300BleHelper(applicationContext)
            android.util.Log.d("MainActivity", "BM300BleHelper initialized")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to initialize BM300BleHelper: ${e.message}")
            bm300Helper = null
        }

        // Check if app was launched with start_minimised flag from BootReceiver
        shouldMinimiseOnStart = intent?.getBooleanExtra("start_minimised", false) ?: false
        if (shouldMinimiseOnStart) {
            android.util.Log.d("MainActivity", "App started with start_minimised flag, will minimize after Flutter init")
        }

        // Load "stay in background" preference
        loadStayInBackgroundPreference()
    }

    private fun loadStayInBackgroundPreference() {
        try {
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            stayInBackground = prefs.getBoolean(STAY_IN_BACKGROUND_KEY, false)
            android.util.Log.d("MainActivity", "Stay in background: $stayInBackground")
        } catch (e: Exception) {
            android.util.Log.w("MainActivity", "Failed to load stay_in_background: ${e.message}")
        }
    }

    override fun onPause() {
        super.onPause()
        wasInBackground = true
    }

    override fun onPostResume() {
        super.onPostResume()
        // Move to background after Flutter has initialized if start_minimised was requested
        if (shouldMinimiseOnStart) {
            shouldMinimiseOnStart = false // Only do this once
            android.util.Log.d("MainActivity", "Moving app to background (start minimised)")
            // Small delay to ensure Flutter is fully initialized
            window.decorView.postDelayed({
                moveTaskToBack(true)
            }, 500)
        }
        // If "stay in background" is enabled and we were in background, move back
        else if (stayInBackground && wasInBackground) {
            android.util.Log.d("MainActivity", "Stay in background enabled, returning to background")
            // Reload preference in case it was changed
            loadStayInBackgroundPreference()
            if (stayInBackground) {
                window.decorView.postDelayed({
                    moveTaskToBack(true)
                }, 100)
            }
        }
        wasInBackground = false
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

        // Set up Location method channel (native implementation for Android 13+ compatibility)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCATION_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "hasPermissions" -> {
                        result.success(locationHelper.hasPermissions())
                    }
                    "isLocationEnabled" -> {
                        result.success(locationHelper.isLocationEnabled())
                    }
                    "getLastKnownLocation" -> {
                        val location = locationHelper.getLastKnownLocation()
                        result.success(location)
                    }
                    "getCurrentLocation" -> {
                        val location = locationHelper.getCurrentLocation()
                        result.success(location)
                    }
                    "startTracking" -> {
                        // Use Number to handle both Int and Long from Dart
                        val minTimeMs = (call.argument<Number>("minTimeMs")?.toLong()) ?: 10000L
                        val minDistanceM = (call.argument<Number>("minDistanceM")?.toFloat()) ?: 10f
                        val success = locationHelper.startTracking(minTimeMs, minDistanceM)
                        result.success(success)
                    }
                    "stopTracking" -> {
                        locationHelper.stopTracking()
                        result.success(true)
                    }
                    "isTracking" -> {
                        result.success(locationHelper.isTracking())
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

        // Set up App Lifecycle method channel (for minimize/background control)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_LIFECYCLE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "moveToBackground" -> {
                    try {
                        moveTaskToBack(true)
                        android.util.Log.d("AppLifecycle", "App moved to background")
                        result.success(true)
                    } catch (e: Exception) {
                        android.util.Log.e("AppLifecycle", "Failed to move to background: ${e.message}")
                        result.error("MOVE_FAILED", e.message, null)
                    }
                }
                "wasStartedMinimised" -> {
                    // Check if app was launched via boot receiver with start_minimised flag
                    val wasMinimised = intent?.getBooleanExtra("start_minimised", false) ?: false
                    result.success(wasMinimised)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Set up Keep Alive method channel (native foreground service for AI boxes)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KEEP_ALIVE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    try {
                        KeepAliveService.start(applicationContext)
                        android.util.Log.d("KeepAlive", "Native keep-alive service started")
                        result.success(true)
                    } catch (e: Exception) {
                        android.util.Log.e("KeepAlive", "Failed to start service: ${e.message}")
                        result.error("START_FAILED", e.message, null)
                    }
                }
                "stopService" -> {
                    try {
                        KeepAliveService.stop(applicationContext)
                        android.util.Log.d("KeepAlive", "Native keep-alive service stopped")
                        result.success(true)
                    } catch (e: Exception) {
                        android.util.Log.e("KeepAlive", "Failed to stop service: ${e.message}")
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
                "isServiceRunning" -> {
                    try {
                        val running = KeepAliveService.isServiceRunning()
                        result.success(running)
                    } catch (e: Exception) {
                        result.error("CHECK_FAILED", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Set up BM300 Pro battery monitor method channel
        val bm300Channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BM300_CHANNEL)

        // Set up BM300 callback to send data to Flutter (only if helper is available)
        bm300Helper?.setCallback(object : BM300BleHelper.BM300Callback {
            override fun onDeviceFound(name: String, address: String) {
                runOnUiThread {
                    bm300Channel.invokeMethod("onDeviceFound", mapOf(
                        "name" to name,
                        "address" to address
                    ))
                }
            }

            override fun onScanStopped(devicesFound: Int, totalCallbacks: Int) {
                runOnUiThread {
                    bm300Channel.invokeMethod("onScanStopped", mapOf(
                        "devicesFound" to devicesFound,
                        "totalCallbacks" to totalCallbacks
                    ))
                }
            }

            override fun onConnected() {
                runOnUiThread {
                    bm300Channel.invokeMethod("onConnected", null)
                }
            }

            override fun onDisconnected() {
                runOnUiThread {
                    bm300Channel.invokeMethod("onDisconnected", null)
                }
            }

            override fun onDataReceived(voltage: Double, soc: Int, temperature: Int) {
                runOnUiThread {
                    bm300Channel.invokeMethod("onDataReceived", mapOf(
                        "voltage" to voltage,
                        "soc" to soc,
                        "temperature" to temperature
                    ))
                }
            }

            override fun onError(message: String) {
                runOnUiThread {
                    bm300Channel.invokeMethod("onError", mapOf("message" to message))
                }
            }
        })

        bm300Channel.setMethodCallHandler { call, result ->
            val helper = bm300Helper
            if (helper == null) {
                // BM300 helper not available - return safe defaults
                when (call.method) {
                    "hasPermissions" -> result.success(false)
                    "isBluetoothEnabled" -> result.success(false)
                    "isConnected" -> result.success(false)
                    "startScan", "stopScan", "connect", "disconnect" -> {
                        result.error("NOT_AVAILABLE", "BM300 BLE not available on this device", null)
                    }
                    else -> result.notImplemented()
                }
                return@setMethodCallHandler
            }

            when (call.method) {
                "hasPermissions" -> {
                    result.success(helper.hasPermissions())
                }
                "isBluetoothEnabled" -> {
                    result.success(helper.isBluetoothEnabled())
                }
                "isConnected" -> {
                    result.success(helper.isConnected())
                }
                "startScan" -> {
                    try {
                        val timeout = (call.argument<Number>("timeout")?.toLong()) ?: 10000L
                        helper.startScan(timeout)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SCAN_FAILED", e.message, null)
                    }
                }
                "stopScan" -> {
                    try {
                        helper.stopScan()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
                "connect" -> {
                    try {
                        val address = call.argument<String>("address")
                        if (address != null) {
                            helper.connect(address)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGUMENT", "Address is required", null)
                        }
                    } catch (e: Exception) {
                        result.error("CONNECT_FAILED", e.message, null)
                    }
                }
                "disconnect" -> {
                    try {
                        helper.disconnect()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("DISCONNECT_FAILED", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Set up URL launcher method channel (for AAOS where url_launcher doesn't work)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.carsoc/url_launcher").setMethodCallHandler { call, result ->
            when (call.method) {
                "openUrl" -> {
                    try {
                        val url = call.argument<String>("url")
                        if (url != null) {
                            val success = openUrl(url)
                            result.success(success)
                        } else {
                            result.error("INVALID_ARGUMENT", "url is required", null)
                        }
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", e.message, null)
                    }
                }
                "openMaps" -> {
                    try {
                        val latitude = call.argument<Double>("latitude")
                        val longitude = call.argument<Double>("longitude")
                        val label = call.argument<String>("label")
                        if (latitude != null && longitude != null) {
                            val success = openMapsLocation(latitude, longitude, label)
                            result.success(success)
                        } else {
                            result.error("INVALID_ARGUMENT", "latitude and longitude are required", null)
                        }
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", e.message, null)
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

    /// Open a URL using Android Intent
    private fun openUrl(url: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            android.util.Log.d("UrlLauncher", "Opened URL: $url")
            true
        } catch (e: Exception) {
            android.util.Log.e("UrlLauncher", "Failed to open URL: ${e.message}")
            false
        }
    }

    /// Open maps app at a specific location
    private fun openMapsLocation(latitude: Double, longitude: Double, label: String?): Boolean {
        return try {
            // Use geo: URI with label - this drops a pin at exact coordinates with the label
            // This is more reliable than search queries which can find wrong places
            val geoUri = if (!label.isNullOrEmpty() && label != "Home") {
                // geo: URI with label shows exact location with a pin labeled with the name
                val encodedLabel = Uri.encode(label)
                Uri.parse("geo:$latitude,$longitude?q=$latitude,$longitude($encodedLabel)")
            } else {
                // Just coordinates
                Uri.parse("geo:$latitude,$longitude?q=$latitude,$longitude")
            }

            android.util.Log.d("UrlLauncher", "Opening maps with URI: $geoUri")

            val intent = Intent(Intent.ACTION_VIEW, geoUri).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }

            // Check if there's an app that can handle this
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                android.util.Log.d("UrlLauncher", "Opened maps: $geoUri")
                true
            } else {
                // Fallback: try Google Maps URL with coordinates only
                val mapsUrl = Uri.parse("https://www.google.com/maps/search/?api=1&query=$latitude,$longitude")
                val mapsIntent = Intent(Intent.ACTION_VIEW, mapsUrl).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(mapsIntent)
                android.util.Log.d("UrlLauncher", "Opened Google Maps URL: $mapsUrl")
                true
            }
        } catch (e: Exception) {
            android.util.Log.e("UrlLauncher", "Failed to open maps: ${e.message}")
            false
        }
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
