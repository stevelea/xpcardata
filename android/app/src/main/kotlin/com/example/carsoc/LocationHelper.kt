package com.example.carsoc

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Native location helper for AAOS compatibility.
 * Uses Android LocationManager directly to bypass Flutter plugin issues.
 */
class LocationHelper(private val context: Context) {

    private val TAG = "LocationHelper"
    private val locationManager: LocationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    private var lastLocation: Location? = null
    private var locationListener: LocationListener? = null
    private var isTracking = false

    /**
     * Check if location permissions are granted
     */
    fun hasPermissions(): Boolean {
        val fineLocation = ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        val coarseLocation = ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        Log.d(TAG, "Permissions check: fine=$fineLocation, coarse=$coarseLocation")
        return fineLocation || coarseLocation
    }

    /**
     * Check if location services are enabled
     */
    fun isLocationEnabled(): Boolean {
        val gpsEnabled = try {
            locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)
        } catch (e: Exception) {
            Log.w(TAG, "GPS provider check failed: ${e.message}")
            false
        }

        val networkEnabled = try {
            locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } catch (e: Exception) {
            Log.w(TAG, "Network provider check failed: ${e.message}")
            false
        }

        Log.d(TAG, "Location enabled: gps=$gpsEnabled, network=$networkEnabled")
        return gpsEnabled || networkEnabled
    }

    /**
     * Get the last known location (quick, may be stale)
     */
    fun getLastKnownLocation(): Map<String, Any?>? {
        if (!hasPermissions()) {
            Log.w(TAG, "No location permission")
            return null
        }

        try {
            // Try GPS first
            var location = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)

            // Fall back to network
            if (location == null) {
                location = locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
            }

            // Use cached location if available
            if (location == null && lastLocation != null) {
                location = lastLocation
            }

            return location?.let { locationToMap(it) }
        } catch (e: SecurityException) {
            Log.e(TAG, "Security exception getting last location: ${e.message}")
            return null
        } catch (e: Exception) {
            Log.e(TAG, "Error getting last location: ${e.message}")
            return null
        }
    }

    /**
     * Get current location (triggers a fresh location update)
     * Returns null if location cannot be obtained within timeout
     */
    fun getCurrentLocation(): Map<String, Any?>? {
        if (!hasPermissions()) {
            Log.w(TAG, "No location permission for getCurrentLocation")
            return null
        }

        if (!isLocationEnabled()) {
            Log.w(TAG, "Location services disabled")
            return null
        }

        try {
            // First try to get last known location as immediate result
            val lastKnown = getLastKnownLocation()
            if (lastKnown != null) {
                Log.d(TAG, "Returning last known location")
                return lastKnown
            }

            // If no last known, request a single update (blocking call with timeout)
            var result: Location? = null
            val latch = java.util.concurrent.CountDownLatch(1)

            val singleUpdateListener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    result = location
                    lastLocation = location
                    latch.countDown()
                    try {
                        locationManager.removeUpdates(this)
                    } catch (e: Exception) {
                        // Ignore
                    }
                }

                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {}
            }

            // Request from GPS provider
            val provider = if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                LocationManager.GPS_PROVIDER
            } else {
                LocationManager.NETWORK_PROVIDER
            }

            locationManager.requestSingleUpdate(provider, singleUpdateListener, Looper.getMainLooper())

            // Wait up to 10 seconds for location
            val gotLocation = latch.await(10, java.util.concurrent.TimeUnit.SECONDS)

            if (!gotLocation) {
                Log.w(TAG, "Location request timed out")
                try {
                    locationManager.removeUpdates(singleUpdateListener)
                } catch (e: Exception) {
                    // Ignore
                }
            }

            return result?.let { locationToMap(it) }
        } catch (e: SecurityException) {
            Log.e(TAG, "Security exception getting current location: ${e.message}")
            return null
        } catch (e: Exception) {
            Log.e(TAG, "Error getting current location: ${e.message}")
            return null
        }
    }

    /**
     * Start continuous location tracking
     */
    fun startTracking(minTimeMs: Long = 10000, minDistanceM: Float = 10f): Boolean {
        if (!hasPermissions()) {
            Log.w(TAG, "No permission to start tracking")
            return false
        }

        if (!isLocationEnabled()) {
            Log.w(TAG, "Location disabled, cannot start tracking")
            return false
        }

        if (isTracking) {
            Log.d(TAG, "Already tracking")
            return true
        }

        try {
            locationListener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    lastLocation = location
                    Log.d(TAG, "Location update: ${location.latitude}, ${location.longitude}")
                }

                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                override fun onProviderEnabled(provider: String) {
                    Log.d(TAG, "Provider enabled: $provider")
                }
                override fun onProviderDisabled(provider: String) {
                    Log.d(TAG, "Provider disabled: $provider")
                }
            }

            // Try GPS provider first
            if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                locationManager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    minTimeMs,
                    minDistanceM,
                    locationListener!!,
                    Looper.getMainLooper()
                )
                Log.d(TAG, "GPS tracking started")
            }

            // Also request network updates as fallback
            if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                locationManager.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    minTimeMs,
                    minDistanceM,
                    locationListener!!,
                    Looper.getMainLooper()
                )
                Log.d(TAG, "Network tracking started")
            }

            isTracking = true
            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "Security exception starting tracking: ${e.message}")
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Error starting tracking: ${e.message}")
            return false
        }
    }

    /**
     * Stop continuous location tracking
     */
    fun stopTracking() {
        try {
            locationListener?.let {
                locationManager.removeUpdates(it)
                Log.d(TAG, "Location tracking stopped")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping tracking: ${e.message}")
        }
        locationListener = null
        isTracking = false
    }

    /**
     * Check if currently tracking
     */
    fun isTracking(): Boolean = isTracking

    /**
     * Convert Location to Map for Flutter
     */
    private fun locationToMap(location: Location): Map<String, Any?> {
        return mapOf(
            "latitude" to location.latitude,
            "longitude" to location.longitude,
            "altitude" to if (location.hasAltitude()) location.altitude else null,
            "accuracy" to if (location.hasAccuracy()) location.accuracy.toDouble() else null,
            "speed" to if (location.hasSpeed()) location.speed.toDouble() else null,
            "heading" to if (location.hasBearing()) location.bearing.toDouble() else null,
            "timestamp" to location.time,
            "provider" to location.provider
        )
    }
}
