# CarSOC - Vehicle Battery Monitor

A Flutter mobile app for Android Auto that monitors electric vehicle battery data (SOC, SOH, and more) and publishes to MQTT for cloud monitoring.

![Platform](https://img.shields.io/badge/platform-Android%20Auto-green)
![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)

## Features

### 📱 Data Collection
- **Android Automotive CarInfo API** - Direct access to vehicle data on AAOS devices
- **OBD-II Support** - Bluetooth adapter for any Android device
- **AI Box Compatible** - Run on Android AI boxes (e.g., Carlinkit) connected to your vehicle
- **Mock Data** - Realistic simulation for testing

### 📊 Real-time Monitoring
- Battery State of Charge (SOC) %
- Battery State of Health (SOH) %
- Battery Capacity (kWh)
- Battery Voltage, Current, Temperature
- Remaining Range (km)
- Vehicle Speed (km/h)
- Power Consumption (kW)
- Odometer (km)

### 🚗 Android Auto Integration
- **Dashboard Screen** - Grid view with 6 key metrics
- **Detail Screen** - Complete vehicle data list
- **Live Updates** - Automatic refresh every 2 seconds
- **Color Coding** - Battery level indicators (green/yellow/red)

### ☁️ Cloud Publishing
- **MQTT** - Real-time data streaming to remote broker
- **QoS 1** - At-least-once delivery guarantee
- **TLS Support** - Secure connections
- **Auto-reconnect** - Exponential backoff

### 💾 Data Persistence
- **SQLite Database** - Local time-series storage
- **Historical Data** - Query by date range
- **Alerts** - Low battery, high temperature warnings

## Quick Start

```bash
# Install dependencies
flutter pub get

# Run the app (uses mock data automatically)
flutter run
```

The app will display simulated vehicle data updating every 2 seconds. See [TESTING.md](TESTING.md) for detailed testing instructions.

## Testing

For comprehensive testing instructions, see **[TESTING.md](TESTING.md)**, which covers:

- ✅ Mock data testing (easiest - start here)
- ✅ Android Auto Desktop Head Unit (DHU) setup
- ✅ MQTT broker configuration and monitoring
- ✅ Database verification
- ✅ Performance testing
- ✅ Troubleshooting tips

## Architecture

```
┌─────────────────────────────────────────────────┐
│   Data Sources                                  │
│   • CarInfo API (AAOS)                         │
│   • OBD-II Bluetooth                           │
│   • Mock Data                                  │
└──────────────┬──────────────────────────────────┘
               ↓
┌─────────────────────────────────────────────────┐
│   DataSourceManager (Intelligent Fallback)      │
└──┬────┬────┬────┬───────────────────────────┬──┘
   ↓    ↓    ↓    ↓                           ↓
  DB  MQTT  ABRP  Phone UI              Android Auto
```

## Tech Stack

- **Flutter** 3.10.4+ - Cross-platform framework
- **Riverpod** - State management
- **SQLite/sqflite** - Local database
- **mqtt_client** - MQTT publishing
- **flutter_automotive** - CarInfo API access
- **Android Car App Library** - Android Auto templates
- **Kotlin** - Native Android code

## Implementation Status

### ✅ Completed

- [x] Data models and SQLite database
- [x] CarInfo API service (flutter_automotive)
- [x] MQTT service with auto-reconnect
- [x] Mock data generator
- [x] Data source manager with intelligent fallback
- [x] Android Auto integration (CarAppService, Dashboard, Details)
- [x] Method channel bridge (Flutter ↔ Native)
- [x] Phone UI with live data display
- [x] Automatic data flow (Source → DB → MQTT → Android Auto)
- [x] OBD-II Bluetooth support with custom PIDs
- [x] ABRP (A Better Route Planner) integration
- [x] Settings UI (MQTT, ABRP, data sources, alerts)
- [x] Background service for continuous monitoring
- [x] Charging session detection

### 🔧 Planned

- [ ] Historical data charts
- [ ] Notification service
- [ ] Data export (CSV, JSON)

## Project Structure

```
lib/
├── main.dart                    # App entry point
├── models/                      # Data models
├── services/                    # Business logic
│   ├── car_info_service.dart   # CarInfo API
│   ├── mock_data_service.dart  # Mock data
│   ├── mqtt_service.dart       # MQTT client
│   ├── database_service.dart   # SQLite
│   └── data_source_manager.dart # Orchestration
├── providers/                   # Riverpod state
└── screens/                     # UI screens

android/app/src/main/kotlin/
├── MainActivity.kt              # Method channel
├── VehicleDataStore.kt          # Shared data
├── CarAppService.kt             # Android Auto entry
├── DashboardScreen.kt           # Car dashboard
└── DetailListScreen.kt          # Car details
```

## Configuration

### MQTT Settings (Temporary)

Until Settings UI is implemented, edit `lib/providers/mqtt_provider.dart`:

```dart
factory MqttSettings.defaultSettings() {
  return const MqttSettings(
    broker: 'mqtt.eclipseprojects.io',
    port: 1883,
    vehicleId: 'vehicle_001',  // Change to unique ID
    useTLS: false,
  );
}
```

## Known Limitations

- **CarInfo API** only works on Android Automotive OS (AAOS), not Android Auto projection
- **OBD-II PIDs** are vehicle-specific; you may need to configure custom PIDs for your vehicle
- **Battery SOH** may not be available on all vehicles

## Resources

- [TESTING.md](TESTING.md) - Complete testing guide
- [Android Auto Developer Guide](https://developer.android.com/training/cars)
- [CarInfo API Reference](https://developer.android.com/reference/android/car/VehiclePropertyIds)
- [flutter_automotive Package](https://pub.dev/packages/flutter_automotive)

---

**Note:** This app works on Android Automotive OS (using CarInfo API) or any Android device with an OBD-II Bluetooth adapter. Can also run on an AI Box (e.g., Carlinkit) connected to your vehicle's head unit.

🚗⚡ Happy Monitoring!
