package com.example.carsoc

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.carsoc/car_app"
    private val BLUETOOTH_CHANNEL = "com.example.carsoc/bluetooth"
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
    }
}
