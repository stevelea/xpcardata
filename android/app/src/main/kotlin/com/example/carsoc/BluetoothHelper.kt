package com.example.carsoc

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class BluetoothHelper(private val context: Context, private val activity: Activity?) {
    // Background executor for Bluetooth operations to avoid blocking main thread
    // and prevent native crashes from taking down the app
    private val executor = Executors.newSingleThreadExecutor()

    // Connection timeout in seconds
    private val CONNECTION_TIMEOUT_SECONDS = 15L
    private val bluetoothManager: BluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private var socket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null

    companion object {
        private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        const val REQUEST_BLUETOOTH_PERMISSIONS = 1001
    }

    fun hasPermissions(): Boolean {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
                // Android 12+ (API 31+)
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> {
                // Android 6-11 (API 23-30)
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADMIN) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            }
            else -> {
                // Android 4.4-5 (API 19-22) - no runtime permissions
                true
            }
        }
    }

    fun requestPermissions(): Boolean {
        if (activity == null) return false

        val permissions = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
                arrayOf(
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.BLUETOOTH_SCAN
                )
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> {
                arrayOf(
                    Manifest.permission.BLUETOOTH,
                    Manifest.permission.BLUETOOTH_ADMIN,
                    Manifest.permission.ACCESS_FINE_LOCATION
                )
            }
            else -> {
                // No runtime permissions needed
                return true
            }
        }

        ActivityCompat.requestPermissions(activity, permissions, REQUEST_BLUETOOTH_PERMISSIONS)
        return true
    }

    fun isBluetoothSupported(): Boolean {
        return bluetoothAdapter != null
    }

    fun isBluetoothEnabled(): Boolean {
        return bluetoothAdapter?.isEnabled ?: false
    }

    @Throws(SecurityException::class)
    fun getPairedDevices(): List<Map<String, Any>> {
        if (!hasPermissions()) {
            throw SecurityException("Bluetooth permissions not granted")
        }

        val devices = mutableListOf<Map<String, Any>>()
        bluetoothAdapter?.bondedDevices?.forEach { device ->
            devices.add(mapOf(
                "name" to (device.name ?: "Unknown"),
                "address" to device.address
            ))
        }
        return devices
    }

    /**
     * Callback interface for async Bluetooth operations
     */
    interface ConnectCallback {
        fun onSuccess()
        fun onError(message: String)
    }

    /**
     * Connect to a Bluetooth device asynchronously on a background thread.
     * This prevents native Bluetooth crashes from taking down the main thread/app.
     *
     * @param address The MAC address of the device
     * @param callback Callback for success/error
     */
    fun connectAsync(address: String, callback: ConnectCallback) {
        if (!hasPermissions()) {
            callback.onError("Bluetooth permissions not granted")
            return
        }

        executor.submit {
            try {
                android.util.Log.d("BluetoothHelper", "Starting async connect to $address")

                // Ensure any previous connection is closed
                disconnect()

                // Give OS time to release the socket
                Thread.sleep(300)

                val device = bluetoothAdapter?.getRemoteDevice(address)
                if (device == null) {
                    android.util.Log.e("BluetoothHelper", "Failed to get remote device")
                    callback.onError("Failed to get remote device")
                    return@submit
                }

                socket = device.createRfcommSocketToServiceRecord(SPP_UUID)

                // Set a timeout for the connection attempt using a watchdog thread
                val connectionComplete = AtomicBoolean(false)
                val connectionThread = Thread.currentThread()

                // Watchdog that will close socket if connection takes too long
                val watchdog = Thread {
                    try {
                        Thread.sleep(CONNECTION_TIMEOUT_SECONDS * 1000)
                        if (!connectionComplete.get()) {
                            android.util.Log.w("BluetoothHelper", "Connection timeout - closing socket")
                            try {
                                socket?.close()
                            } catch (e: Exception) {
                                // Ignore close errors
                            }
                        }
                    } catch (e: InterruptedException) {
                        // Watchdog was cancelled, connection completed
                    }
                }
                watchdog.start()

                try {
                    // Attempt connection - this can crash with native exception
                    socket?.connect()
                    connectionComplete.set(true)
                    watchdog.interrupt() // Cancel watchdog

                    inputStream = socket?.inputStream
                    outputStream = socket?.outputStream

                    val connected = socket?.isConnected ?: false
                    if (connected) {
                        android.util.Log.d("BluetoothHelper", "Connection successful")
                        callback.onSuccess()
                    } else {
                        android.util.Log.e("BluetoothHelper", "Socket not connected after connect()")
                        disconnect()
                        callback.onError("Connection failed - socket not connected")
                    }
                } catch (e: IOException) {
                    connectionComplete.set(true)
                    watchdog.interrupt()
                    android.util.Log.e("BluetoothHelper", "Connection IOException: ${e.message}")
                    disconnect()
                    callback.onError("Connection failed: ${e.message}")
                }
            } catch (e: Exception) {
                android.util.Log.e("BluetoothHelper", "Connection error: ${e.message}")
                disconnect()
                callback.onError("Connection error: ${e.message}")
            }
        }
    }

    /**
     * Synchronous connect - kept for backwards compatibility but should avoid using.
     * Use connectAsync() instead to prevent main thread blocking and native crashes.
     */
    @Throws(SecurityException::class, IOException::class)
    @Deprecated("Use connectAsync() to avoid main thread blocking and native crashes")
    fun connect(address: String): Boolean {
        if (!hasPermissions()) {
            throw SecurityException("Bluetooth permissions not granted")
        }

        try {
            // Ensure any previous connection is closed
            disconnect()

            // Give OS time to release the socket
            Thread.sleep(300)

            val device = bluetoothAdapter?.getRemoteDevice(address) ?: return false
            socket = device.createRfcommSocketToServiceRecord(SPP_UUID)

            // Attempt connection
            socket?.connect()

            inputStream = socket?.inputStream
            outputStream = socket?.outputStream

            return socket?.isConnected ?: false
        } catch (e: Exception) {
            disconnect()
            throw e
        }
    }

    fun disconnect() {
        try {
            inputStream?.close()
            outputStream?.close()
            socket?.close()
        } catch (e: IOException) {
            // Ignore
        } finally {
            inputStream = null
            outputStream = null
            socket = null
        }
    }

    fun isConnected(): Boolean {
        return socket?.isConnected ?: false
    }

    @Throws(IOException::class)
    fun sendData(data: ByteArray) {
        outputStream?.write(data) ?: throw IOException("Not connected")
        outputStream?.flush()
    }

    @Throws(IOException::class)
    fun readData(bufferSize: Int = 1024): ByteArray {
        val stream = inputStream ?: throw IOException("Not connected")
        val buffer = ByteArray(bufferSize)

        // Only read if data is actually available to prevent blocking
        val available = stream.available()
        if (available <= 0) {
            return ByteArray(0)
        }

        // Read only what's available, up to buffer size
        val toRead = minOf(available, bufferSize)
        val bytesRead = stream.read(buffer, 0, toRead)
        return if (bytesRead > 0) buffer.copyOf(bytesRead) else ByteArray(0)
    }

    fun readAvailable(): Int {
        return try {
            inputStream?.available() ?: 0
        } catch (e: IOException) {
            0
        }
    }
}
