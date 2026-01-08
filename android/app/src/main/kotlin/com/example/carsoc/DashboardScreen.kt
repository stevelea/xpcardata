package com.example.carsoc

import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.*
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/**
 * Dashboard screen for Android Auto
 * Displays vehicle data in a grid template with cards
 */
class DashboardScreen(carContext: CarContext) : Screen(carContext) {

    private var vehicleData: VehicleData? = null

    init {
        // Observe vehicle data changes
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                VehicleDataStore.vehicleData.observeForever { data ->
                    vehicleData = data
                    invalidate() // Refresh the screen
                }
            }
        })
    }

    override fun onGetTemplate(): Template {
        val data = vehicleData

        // Build grid items
        val gridItemListBuilder = ItemList.Builder()

        // Battery SOC - Primary card
        gridItemListBuilder.addItem(
            GridItem.Builder()
                .setTitle(data?.getFormattedSOC() ?: "--")
                .setText("Battery Level")
                .build()
        )

        // Range
        gridItemListBuilder.addItem(
            GridItem.Builder()
                .setTitle(data?.getFormattedRange() ?: "--")
                .setText("Range")
                .build()
        )

        // Battery Temperature
        gridItemListBuilder.addItem(
            GridItem.Builder()
                .setTitle(data?.getFormattedTemperature() ?: "--")
                .setText("Battery Temp")
                .build()
        )

        // Speed
        gridItemListBuilder.addItem(
            GridItem.Builder()
                .setTitle(data?.getFormattedSpeed() ?: "--")
                .setText("Speed")
                .build()
        )

        // Power
        gridItemListBuilder.addItem(
            GridItem.Builder()
                .setTitle(data?.getFormattedPower() ?: "--")
                .setText("Power")
                .build()
        )

        // Battery Health (SOH)
        gridItemListBuilder.addItem(
            GridItem.Builder()
                .setTitle(data?.getFormattedSOH() ?: "--")
                .setText("Battery Health")
                .build()
        )

        // Build action strip with refresh, details, and quit buttons
        val actionStrip = ActionStrip.Builder()
            .addAction(
                Action.Builder()
                    .setTitle("Refresh")
                    .setOnClickListener {
                        invalidate() // Refresh the screen
                    }
                    .build()
            )
            .addAction(
                Action.Builder()
                    .setTitle("Details")
                    .setOnClickListener {
                        screenManager.push(DetailListScreen(carContext))
                    }
                    .build()
            )
            .addAction(
                Action.Builder()
                    .setTitle("Quit")
                    .setOnClickListener {
                        carContext.finishCarApp()
                    }
                    .build()
            )
            .build()

        // Build grid template
        return GridTemplate.Builder()
            .setTitle("XPCarData - Battery Monitor")
            .setHeaderAction(Action.APP_ICON)
            .setSingleList(gridItemListBuilder.build())
            .setActionStrip(actionStrip)
            .build()
    }
}
