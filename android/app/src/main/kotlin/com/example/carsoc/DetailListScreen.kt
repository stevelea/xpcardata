package com.example.carsoc

import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.*
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import java.text.SimpleDateFormat
import java.util.*

/**
 * Detail list screen for Android Auto
 * Displays all vehicle properties in a scrollable list
 */
class DetailListScreen(carContext: CarContext) : Screen(carContext) {

    private var vehicleData: VehicleData? = null
    private val dateFormat = SimpleDateFormat("HH:mm:ss", Locale.getDefault())

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

        // Build list items
        val listBuilder = ItemList.Builder()

        // Section: Battery Information
        listBuilder.addItem(
            Row.Builder()
                .setTitle("Battery Information")
                .setBrowsable(false)
                .build()
        )

        addDataRow(listBuilder, "State of Charge", data?.getFormattedSOC() ?: "--")
        addDataRow(listBuilder, "State of Health", data?.getFormattedSOH() ?: "--")
        addDataRow(listBuilder, "Battery Capacity", data?.getFormattedCapacity() ?: "--")
        addDataRow(listBuilder, "Battery Voltage", data?.getFormattedVoltage() ?: "--")
        addDataRow(listBuilder, "Battery Current", data?.getFormattedCurrent() ?: "--")
        addDataRow(listBuilder, "Battery Temperature", data?.getFormattedTemperature() ?: "--")
        addDataRow(listBuilder, "Power", data?.getFormattedPower() ?: "--")

        // Divider
        listBuilder.addItem(
            Row.Builder()
                .setTitle("Vehicle Information")
                .setBrowsable(false)
                .build()
        )

        addDataRow(listBuilder, "Range", data?.getFormattedRange() ?: "--")
        addDataRow(listBuilder, "Speed", data?.getFormattedSpeed() ?: "--")
        addDataRow(listBuilder, "Odometer", data?.getFormattedOdometer() ?: "--")

        // Timestamp
        val timestampText = if (data != null) {
            dateFormat.format(Date(data.timestamp))
        } else {
            "No data"
        }
        addDataRow(listBuilder, "Last Update", timestampText)

        // Build action strip with refresh and quit buttons
        val actionStrip = ActionStrip.Builder()
            .addAction(
                Action.Builder()
                    .setTitle("Refresh")
                    .setOnClickListener {
                        invalidate()
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

        // Build list template
        return ListTemplate.Builder()
            .setTitle("Vehicle Details")
            .setHeaderAction(Action.BACK)
            .setSingleList(listBuilder.build())
            .setActionStrip(actionStrip)
            .build()
    }

    /**
     * Helper function to add a data row
     */
    private fun addDataRow(listBuilder: ItemList.Builder, title: String, value: String) {
        listBuilder.addItem(
            Row.Builder()
                .setTitle(title)
                .addText(value)
                .setBrowsable(false)
                .build()
        )
    }
}
