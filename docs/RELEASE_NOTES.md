# XPCarData Release Notes

## Version 1.0.0 (Build 8) - 2026-01-07

### New Features

- **Real-time Battery Monitoring**: Display live battery SOC, SOH, voltage, current, temperature, and power
- **Multiple Data Sources**: Support for CarInfo API (Android Automotive) and OBD-II Bluetooth adapters
- **ABRP Integration**: Send live telemetry to A Better Route Planner for accurate range predictions
- **MQTT Publishing**: Publish vehicle data to any MQTT broker for home automation and monitoring
- **Verified PID Profiles**: Pre-configured PID settings for XPENG G6 and other vehicles
- **Custom PID Support**: Add and configure custom OBD-II PIDs for any vehicle
- **Alert System**: Configurable alerts for low battery, critical battery, and high temperature conditions
- **Historical Data**: Store and view historical vehicle data with configurable retention
- **Debug Logging**: Comprehensive logging for troubleshooting with share functionality

### Dashboard

- Clean, modern UI with large battery level display
- 2-column metric card layout for better readability
- Full odometer display (not abbreviated)
- Additional PID data displayed in consistent card format
- Pull-to-refresh functionality
- Real-time data source indicator

### OBD-II Features

- Bluetooth device scanning and connection
- Automatic reconnection every 60 seconds on connection loss
- Support for ELM327-compatible adapters
- Configurable PID polling with custom formulas
- Verified profiles for known vehicle configurations

### ABRP Integration

- Proper API authentication with api_key and user token
- Sends: SOC, SOH, speed, voltage, current, power, battery temperature, odometer, charging status
- Configurable update interval (minimum 5 seconds per ABRP recommendation)
- Rate limiting to prevent excessive API calls

### MQTT Features

- Simplified single-topic data publishing (`vehicles/{id}/data`)
- Online/offline status tracking (`vehicles/{id}/status`)
- Alert notifications (`vehicles/{id}/alerts`)
- TLS support for secure connections
- Automatic reconnection with exponential backoff
- Last Will and Testament for offline detection

### Settings

- MQTT broker configuration (host, port, TLS, credentials)
- ABRP token and car model configuration
- Alert threshold customization
- Update frequency adjustment
- Data retention settings
- Export and clear data options
- Start minimized option

### About

- Dynamic version and build number display
- Build date tracking

---

## Version History

### Build 8 (2026-01-07)
- **Tailscale open app fix**: Fixed "Open Tailscale App" button using proper intent with category and component
- **Background service fix**: Added proper initialization check and error handling for MissingPluginException
- **OBD auto-connect improvements**: Now saves OBD address to both SharedPreferences and file-based settings; reads from both on startup with fallback

### Build 7 (2026-01-07)
- **OBD auto-connect fix**: Fixed last OBD device address not being saved/awaited properly for auto-reconnect on startup

### Build 6 (2026-01-07)
- **Exit button**: Power button in app bar to cleanly stop all services and exit
- **Tailscale VPN control**: Connect/disconnect Tailscale VPN directly from settings
- **Auto-connect option**: Automatically connect Tailscale when app starts
- Open Tailscale app from within XPCarData
- Auto-detection of Tailscale installation

### Build 5 (2026-01-07)
- Home Assistant MQTT auto-discovery support
- Charging session detection now only publishes when energy is actually added
- Background service foreground service type fix for Android 13+
- ABRP update interval slider (5 sec - 5 min, default 1 min)
- Improved error handling for background service toggle
- Added author info to About screen

### Build 4 (2026-01-07)
- Background service improvements
- Permission handling enhancements

### Build 3 (2025-01-07)
- ABRP interval configuration
- WidgetsBindingObserver for app lifecycle

### Build 2 (2025-01-07)
- Simplified MQTT to single data topic
- Added dynamic version info to About screen
- Updated build date display
- Incremented build number

### Build 1 (2025-01-06)
- Initial release
- Dashboard redesign with wider 2-column layout
- ABRP authorization fix (added api_key parameter)
- ABRP odometer transmission
- OBD Bluetooth auto-reconnect (60-second retry)
- Removed mock data functionality
- Custom APK naming (XPCarData-release-{version}+{build}.apk)
- App title simplified to "XPCarData"

---

## Known Issues

- Custom APK naming outputs to `build/app/outputs/apk/release/` folder (Flutter copies to flutter-apk with default name)
- OBD connection may require vehicle ignition to be on

## Requirements

- Android 10 (API 29) or higher
- Bluetooth permission for OBD-II connection
- Internet permission for ABRP and MQTT
- For CarInfo API: XPENG Android Automotive OS

## Installation

1. Download `XPCarData-release-1.0.0+8.apk`
2. Enable installation from unknown sources if prompted
3. Install on your XPENG vehicle or Android device

## File Locations

- APK: `build/app/outputs/apk/release/XPCarData-release-1.0.0+8.apk`
- User Guide: `docs/USER_GUIDE.md`
- Release Notes: `docs/RELEASE_NOTES.md`
