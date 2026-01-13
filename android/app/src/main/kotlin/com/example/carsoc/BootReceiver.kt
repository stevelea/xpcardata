package com.example.carsoc

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import java.io.File

/**
 * BroadcastReceiver that starts the app when the device boots
 * if the "Start Minimised" setting is enabled.
 */
class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val START_MINIMISED_KEY = "flutter.start_minimised"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        Log.d(TAG, "Received action: $action")

        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED) {

            // Check if start minimised is enabled
            if (isStartMinimisedEnabled(context)) {
                Log.d(TAG, "Start Minimised is enabled, launching app in background")
                launchAppMinimised(context)
            } else {
                Log.d(TAG, "Start Minimised is not enabled, skipping auto-start")
            }
        }
    }

    /**
     * Check if "Start Minimised" setting is enabled.
     * Checks both SharedPreferences and the settings JSON file.
     */
    private fun isStartMinimisedEnabled(context: Context): Boolean {
        // Method 1: Check SharedPreferences (Flutter's default storage)
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (prefs.contains(START_MINIMISED_KEY)) {
                val enabled = prefs.getBoolean(START_MINIMISED_KEY, false)
                Log.d(TAG, "SharedPreferences start_minimised: $enabled")
                return enabled
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read SharedPreferences: ${e.message}")
        }

        // Method 2: Check settings JSON file (fallback for AI boxes)
        try {
            val settingsFile = File(context.filesDir.parentFile, "app_flutter/app_settings.json")
            if (settingsFile.exists()) {
                val content = settingsFile.readText()
                // Simple JSON parsing for start_minimised
                if (content.contains("\"start_minimised\"")) {
                    val enabled = content.contains("\"start_minimised\":true") ||
                                  content.contains("\"start_minimised\": true")
                    Log.d(TAG, "File settings start_minimised: $enabled")
                    return enabled
                }
            }

            // Also try documents directory
            val docsSettingsFile = File(context.filesDir.parentFile, "files/app_settings.json")
            if (docsSettingsFile.exists()) {
                val content = docsSettingsFile.readText()
                if (content.contains("\"start_minimised\"")) {
                    val enabled = content.contains("\"start_minimised\":true") ||
                                  content.contains("\"start_minimised\": true")
                    Log.d(TAG, "Docs file settings start_minimised: $enabled")
                    return enabled
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read settings file: ${e.message}")
        }

        Log.d(TAG, "start_minimised setting not found, defaulting to false")
        return false
    }

    /**
     * Launch the app but immediately move it to the background.
     */
    private fun launchAppMinimised(context: Context) {
        try {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                // FLAG_ACTIVITY_NEW_TASK is required when starting from a BroadcastReceiver
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                // Add extra to indicate this is a minimised start
                putExtra("start_minimised", true)
            }
            context.startActivity(launchIntent)
            Log.d(TAG, "App launched with start_minimised flag")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch app: ${e.message}")
        }
    }
}
