# XPCarData - Battery Monitor for XPENG Vehicles

A Flutter app for monitoring XPENG electric vehicle battery data via OBD-II Bluetooth, with integrations for ABRP, MQTT/Home Assistant, and anonymous Fleet Statistics.

![Platform](https://img.shields.io/badge/platform-Android-green)
![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)
![Version](https://img.shields.io/badge/version-1.2.0-orange)

## Features

### Real-time Battery Monitoring
- State of Charge (SOC) %
- State of Health (SOH) %
- HV Battery Voltage, Current, Power
- Max/Min Cell Voltages
- Battery Temperature (Max/Min)
- Coolant Temperatures (Battery, Motor)
- DC Charging Voltage/Current/Power
- Guestimated Range (calculated)
- Speed, Odometer

### Integrations
- **ABRP** - Live telemetry for A Better Route Planner
- **MQTT** - Publish to any broker for home automation
- **Home Assistant** - Auto-discovery creates entities automatically
- **Fleet Statistics** - Anonymous, opt-in fleet-wide insights

### Data Sources
- **OBD-II Bluetooth** - ELM327 compatible adapters
- **CarInfo API** - For Android Automotive OS devices
- **OBD Proxy** - Share data with external apps

### Additional Features
- Background service for continuous monitoring
- Charging session detection and history
- **OpenChargeMap integration** - Auto-lookup charger names from GPS coordinates
- Priority-based PID polling (reduces OBD traffic by ~50%)
- Tailscale VPN control from settings
- In-app updates via GitHub
- Location services for enhanced ABRP data
- Configurable alerts (low battery, high temperature)
- Mock data mode for testing without vehicle connection

## Installation

### Download
Get the latest APK from the [releases](releases/) folder or check for updates in-app.

**Current Version:** v1.2.0 (Build 87)

### Requirements
- Android 10 (API 29) or higher
- OBD-II Bluetooth adapter (ELM327 v1.5+ compatible)
- XPENG G6 (verified), other XPENG models may need PID adjustments

### Platforms
- Android phones and tablets
- Android AI Boxes (e.g., Carlinkit) - ideal for in-car use
- **Note:** Cannot be installed directly on XPENG's built-in infotainment

## Quick Start

1. Install the APK on your Android device
2. Plug OBD-II adapter into your vehicle
3. Turn on vehicle ignition
4. Open XPCarData → Settings → OBD-II Connection
5. Scan and connect to your adapter
6. Data will appear on the dashboard

## Configuration

### ABRP Integration
1. Get your token from ABRP app → Settings → Car Model → Generic → Link to live data
2. In XPCarData: Settings → ABRP → Enable and paste token
3. Set update interval (minimum 5 seconds)

### MQTT / Home Assistant
1. Settings → MQTT → Enable
2. Configure broker address (use Tailscale IP for remote access)
3. Enable Home Assistant Discovery for automatic entity creation
4. Entities appear under "XPCarData {Vehicle ID}" device

### Fleet Statistics
1. Settings → Fleet Statistics → Enable
2. Accept consent dialog (first time only)
3. View aggregated fleet data: SOH distribution, charging patterns, country breakdown

**Privacy:** All data is anonymous and bucketed. No GPS, vehicle IDs, or personal info collected.

## Documentation

- [User Guide](docs/USER_GUIDE.md) - Complete feature documentation
- [Release Notes](docs/RELEASE_NOTES.md) - Version history and changes
- [PID Reference](docs/XPENG_G6_PIDs.md) - OBD-II PID configuration for XPENG G6

## Architecture

```
┌─────────────────────────────────────────────────┐
│   Data Sources                                  │
│   • OBD-II Bluetooth (primary)                 │
│   • CarInfo API (AAOS)                         │
│   • OBD Proxy (external apps)                  │
└──────────────┬──────────────────────────────────┘
               ↓
┌─────────────────────────────────────────────────┐
│   DataSourceManager (Intelligent Routing)       │
└──┬────┬────┬────┬────┬──────────────────────┬──┘
   ↓    ↓    ↓    ↓    ↓                      ↓
  DB  MQTT  ABRP Fleet  Phone UI        Android Auto
            Analytics
```

## Tech Stack

- **Flutter** 3.x - Cross-platform framework
- **Riverpod** - State management
- **Firebase** - Analytics and Firestore for fleet statistics
- **SQLite** - Local database
- **mqtt_client** - MQTT publishing
- **flutter_blue_plus** - Bluetooth OBD connection

## Version History

### v1.2.0 (Current)
- **OpenChargeMap integration** - Auto-lookup charger names from GPS coordinates
- Improved maps integration with correct geo URI handling
- Mock data mode for testing without vehicle connection
- Home location setting for charging session tracking
- Android AI Box compatibility with in-memory storage
- Reliable DC charging detection using HV battery current
- Energy accumulation via power integration

### v1.1.0
- Fleet Statistics with anonymous data sharing
- Charging session history
- In-app updates via GitHub
- Location services for ABRP
- Country detection for fleet insights

### v1.0.x
- Core OBD-II monitoring
- ABRP and MQTT integration
- Home Assistant auto-discovery
- Priority-based PID polling
- Charging detection

## Known Limitations

- **Single BLE Connection**: Cannot use with ABRP's native OBD connection simultaneously (unless adapter supports multiple connections)
- **Vehicle-Specific PIDs**: Configured for XPENG G6; other models may need adjustments
- **CarInfo API**: Only works on Android Automotive OS, not Android Auto projection

## Support

For issues and feature requests: https://github.com/stevelea/xpcardata

---

**Tested on:** XPENG G6 (2023-2024 models)

**Privacy:** Fleet Statistics is opt-in only. No personal data, GPS coordinates, or vehicle IDs are collected.
