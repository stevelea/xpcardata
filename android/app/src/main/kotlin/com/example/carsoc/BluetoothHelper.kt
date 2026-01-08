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

class BluetoothHelper(private val context: Context, private val activity: Activity?) {
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

    @Throws(SecurityException::class, IOException::class)
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
