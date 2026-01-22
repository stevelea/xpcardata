package com.example.carsoc

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Native foreground service to keep the app alive on AI boxes
 * where Flutter plugins (wakelock_plus, etc.) fail due to platform channel issues.
 *
 * This service:
 * - Runs as a foreground service with a persistent notification
 * - Holds a partial wake lock to prevent CPU sleep
 * - Runs a periodic heartbeat to detect and recover from issues
 * - Works even when Flutter platform channels fail
 */
class KeepAliveService : Service() {

    companion object {
        private const val CHANNEL_ID = "keep_alive_channel"
        private const val NOTIFICATION_ID = 1001
        private const val TAG = "KeepAliveService"
        private const val HEARTBEAT_INTERVAL_MS = 30000L  // 30 seconds

        private var isRunning = false

        fun isServiceRunning(): Boolean = isRunning

        fun start(context: Context) {
            if (isRunning) {
                android.util.Log.d(TAG, "Service already running")
                return
            }
            val intent = Intent(context, KeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            android.util.Log.d(TAG, "Service start requested")
        }

        fun stop(context: Context) {
            val intent = Intent(context, KeepAliveService::class.java)
            context.stopService(intent)
            android.util.Log.d(TAG, "Service stop requested")
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private var heartbeatRunnable: Runnable? = null

    override fun onCreate() {
        super.onCreate()
        android.util.Log.d(TAG, "Service onCreate")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        android.util.Log.d(TAG, "Service onStartCommand")

        // Start as foreground service
        startForeground(NOTIFICATION_ID, createNotification())
        isRunning = true

        // Acquire wake lock
        acquireWakeLock()

        // Start heartbeat to keep service alive and verify wake lock
        startHeartbeat()

        // Return START_STICKY so Android restarts the service if it's killed
        return START_STICKY
    }

    override fun onDestroy() {
        android.util.Log.d(TAG, "Service onDestroy")
        isRunning = false
        stopHeartbeat()
        releaseWakeLock()

        // Schedule restart if the service was killed unexpectedly
        // This helps recover from aggressive battery optimization
        val restartIntent = Intent(applicationContext, KeepAliveService::class.java)
        val pendingIntent = PendingIntent.getService(
            applicationContext,
            1,
            restartIntent,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
        )
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
        alarmManager.set(
            android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP,
            android.os.SystemClock.elapsedRealtime() + 5000,
            pendingIntent
        )
        android.util.Log.d(TAG, "Scheduled restart in 5 seconds")

        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        android.util.Log.d(TAG, "onTaskRemoved - app was swiped away")
        // Don't stop the service when the app is swiped away
        // The foreground notification will keep it running
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "XPCarData Keep Alive",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the app running in the background"
                setShowBadge(false)
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("XPCarData")
            .setContentText("Monitoring vehicle data")
            .setSmallIcon(android.R.drawable.ic_menu_compass)  // Use a system icon
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun acquireWakeLock() {
        if (wakeLock != null) return

        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "XPCarData::KeepAlive"
            ).apply {
                setReferenceCounted(false)
                acquire(24 * 60 * 60 * 1000L)  // 24 hours max
            }
            android.util.Log.d(TAG, "Wake lock acquired")
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Failed to acquire wake lock: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    android.util.Log.d(TAG, "Wake lock released")
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Failed to release wake lock: ${e.message}")
        }
    }

    private fun startHeartbeat() {
        stopHeartbeat()

        heartbeatRunnable = object : Runnable {
            override fun run() {
                if (!isRunning) return

                // Check if wake lock is still held, re-acquire if needed
                if (wakeLock == null || wakeLock?.isHeld != true) {
                    android.util.Log.w(TAG, "Wake lock lost, re-acquiring")
                    acquireWakeLock()
                }

                // Schedule next heartbeat
                handler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
            }
        }

        handler.post(heartbeatRunnable!!)
        android.util.Log.d(TAG, "Heartbeat started (interval: ${HEARTBEAT_INTERVAL_MS}ms)")
    }

    private fun stopHeartbeat() {
        heartbeatRunnable?.let {
            handler.removeCallbacks(it)
        }
        heartbeatRunnable = null
    }
}
