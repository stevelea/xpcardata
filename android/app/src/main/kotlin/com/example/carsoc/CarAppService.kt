package com.example.carsoc

import android.content.Intent
import androidx.car.app.CarAppService
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator

/**
 * Android Auto Car App Service
 * Entry point for the Android Auto application
 */
class CarSOCCarAppService : CarAppService() {

    override fun createHostValidator(): HostValidator {
        // Allow all hosts for development
        // In production, you should validate specific hosts
        return HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
    }

    override fun onCreateSession(): Session {
        return CarSOCSession()
    }
}

/**
 * Car App Session
 * Manages the lifecycle of screens in Android Auto
 */
class CarSOCSession : Session() {

    override fun onCreateScreen(intent: Intent): Screen {
        // Initialize VehicleDataStore if not already initialized
        VehicleDataStore.initialize(carContext)

        // Return the main dashboard screen
        return DashboardScreen(carContext)
    }
}
