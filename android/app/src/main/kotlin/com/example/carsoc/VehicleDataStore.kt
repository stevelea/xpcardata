package com.example.carsoc

import android.content.Context
import android.content.SharedPreferences
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import com.google.gson.Gson
import com.google.gson.JsonSyntaxException

/**
 * Singleton data store for vehicle data shared between Flutter app and Android Auto
 * Uses SharedPreferences for persistence and LiveData for reactive updates
 */
object VehicleDataStore {
    private const val PREFS_NAME = "vehicle_data_prefs"
    private const val KEY_VEHICLE_DATA = "current_vehicle_data"

    private var sharedPreferences: SharedPreferences? = null
    private val gson = Gson()

    // LiveData for reactive updates to Car App
    private val _vehicleData = MutableLiveData<VehicleData?>()
    val vehicleData: LiveData<VehicleData?> = _vehicleData

    /**
     * Initialize the data store with application context
     * Must be called before using the store
     */
    fun initialize(context: Context) {
        if (sharedPreferences == null) {
            sharedPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            // Load initial data
            loadData()
        }
    }

    /**
     * Update vehicle data from Flutter
     * Saves to SharedPreferences and notifies observers
     */
    fun updateVehicleData(data: Map<String, Any?>) {
        try {
            val vehicleData = VehicleData.fromMap(data)

            // Save to SharedPreferences
            sharedPreferences?.edit()?.apply {
                putString(KEY_VEHICLE_DATA, gson.toJson(vehicleData))
                apply()
            }

            // Notify observers
            _vehicleData.postValue(vehicleData)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * Load saved vehicle data from SharedPreferences
     */
    private fun loadData() {
        try {
            val json = sharedPreferences?.getString(KEY_VEHICLE_DATA, null)
            if (json != null) {
                val data = gson.fromJson(json, VehicleData::class.java)
                _vehicleData.postValue(data)
            }
        } catch (e: JsonSyntaxException) {
            e.printStackTrace()
        }
    }

    /**
     * Get current vehicle data synchronously
     */
    fun getCurrentData(): VehicleData? {
        return _vehicleData.value
    }

    /**
     * Clear all stored vehicle data
     */
    fun clearData() {
        sharedPreferences?.edit()?.clear()?.apply()
        _vehicleData.postValue(null)
    }
}

/**
 * Vehicle data model matching the Dart VehicleData class
 */
data class VehicleData(
    val timestamp: Long,
    val stateOfCharge: Double?,
    val stateOfHealth: Double?,
    val batteryCapacity: Double?,
    val batteryVoltage: Double?,
    val batteryCurrent: Double?,
    val batteryTemperature: Double?,
    val range: Double?,
    val speed: Double?,
    val odometer: Double?,
    val power: Double?
) {
    companion object {
        /**
         * Create VehicleData from Flutter map
         */
        fun fromMap(map: Map<String, Any?>): VehicleData {
            return VehicleData(
                timestamp = (map["timestamp"] as? Number)?.toLong() ?: System.currentTimeMillis(),
                stateOfCharge = (map["stateOfCharge"] as? Number)?.toDouble(),
                stateOfHealth = (map["stateOfHealth"] as? Number)?.toDouble(),
                batteryCapacity = (map["batteryCapacity"] as? Number)?.toDouble(),
                batteryVoltage = (map["batteryVoltage"] as? Number)?.toDouble(),
                batteryCurrent = (map["batteryCurrent"] as? Number)?.toDouble(),
                batteryTemperature = (map["batteryTemperature"] as? Number)?.toDouble(),
                range = (map["range"] as? Number)?.toDouble(),
                speed = (map["speed"] as? Number)?.toDouble(),
                odometer = (map["odometer"] as? Number)?.toDouble(),
                power = (map["power"] as? Number)?.toDouble()
            )
        }
    }

    /**
     * Format value with unit, handling null values
     */
    fun formatValue(value: Double?, unit: String, decimals: Int = 1): String {
        return if (value != null) {
            "%.${decimals}f %s".format(value, unit)
        } else {
            "--"
        }
    }

    // Formatted getters for display
    fun getFormattedSOC(): String = formatValue(stateOfCharge, "%", 1)
    fun getFormattedSOH(): String = formatValue(stateOfHealth, "%", 1)
    fun getFormattedRange(): String = formatValue(range, "km", 0)
    fun getFormattedSpeed(): String = formatValue(speed, "km/h", 0)
    fun getFormattedTemperature(): String = formatValue(batteryTemperature, "°C", 1)
    fun getFormattedPower(): String = formatValue(power, "kW", 1)
    fun getFormattedVoltage(): String = formatValue(batteryVoltage, "V", 1)
    fun getFormattedCurrent(): String = formatValue(batteryCurrent, "A", 1)
    fun getFormattedCapacity(): String = formatValue(batteryCapacity, "kWh", 1)
    fun getFormattedOdometer(): String = formatValue(odometer, "km", 0)

    /**
     * Get battery color based on SOC level
     */
    fun getBatteryColor(): Int {
        return when {
            stateOfCharge == null -> android.graphics.Color.GRAY
            stateOfCharge >= 60.0 -> android.graphics.Color.parseColor("#4CAF50") // Green
            stateOfCharge >= 30.0 -> android.graphics.Color.parseColor("#FF9800") // Orange
            else -> android.graphics.Color.parseColor("#F44336") // Red
        }
    }

    /**
     * Check if data is fresh (less than 60 seconds old)
     */
    fun isFresh(): Boolean {
        val age = System.currentTimeMillis() - timestamp
        return age < 60_000 // 60 seconds
    }
}
