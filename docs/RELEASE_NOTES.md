# XPCarData Release Notes

## Version 1.2.0 (Build 93) - 2026-01-12

### Improvements

- **Larger splash screen icon**: App icon now displays at 512x512 on splash screen
  - Scaled versions for all screen densities (mdpi through xxxhdpi)
  - Much more visible during app startup

---

## Version 1.2.0 (Build 92) - 2026-01-12

### Improvements

- **In-app updates now support ZIP files**: GitHub releases can use compressed ZIP files (under 50MB limit)
  - Automatically detects ZIP vs APK assets
  - Downloads ZIP, extracts APK, installs
  - Cleans up ZIP after extraction

- **View Release Notes button**: Added "Notes" button in Settings when update is available
  - Shows version, release date, size, and full release notes

---

## Version 1.2.0 (Build 91) - 2026-01-12

### Improvements

- **Settings auto-save**: Boolean toggle settings now save immediately when changed
  - No need to manually save after toggling MQTT, ABRP, Tailscale, etc.

- **Tailscale auto-connect reliability**: Improved VPN auto-connect on app startup
  - Now wakes Tailscale app first before sending connect intent
  - Verifies VPN actually connected (polls status)
  - Retries up to 3 times if connection doesn't establish
  - Returns actual success/failure instead of just "intent sent"

---

## Version 1.2.0 (Build 90) - 2026-01-12

### Bug Fixes

- **Fixed "Start Minimised" not working on manual launch**: Setting now works both on device boot AND when manually opening the app
  - Previously only worked when device booted with the setting enabled
  - Now respects the setting regardless of how the app is launched
  - App minimizes to background after initialization when setting is enabled

---

## Version 1.2.0 (Build 89) - 2026-01-12

### New Features

- **Start Minimised**: App can now auto-start in the background on device boot
  - Enable in Settings > App Behavior > Start Minimised
  - Launches app on boot and immediately moves to background
  - Useful for AI boxes to start data collection automatically
  - Works with BOOT_COMPLETED and QUICKBOOT_POWERON intents

### Bug Fixes

- Fixed "Start Minimised" setting not working (was stored but never used)

---

## Version 1.2.0 (Build 88) - 2026-01-12

### New Features

- **Fleet Statistics Enhancement**: Added total contributions count
  - Shows both number of contributors and total contributions
  - Better visibility into fleet data participation

- **OpenChargeMap Integration**: Automatic charger name lookup from GPS coordinates
  - When a charging session completes, the app looks up the nearest charger within 100m
  - Charger names from OpenChargeMap are stored with the session
  - Cached for 7 days to reduce API calls

- **Improved Maps Integration**: Fixed geo URI handling for correct location opening
  - Maps now open at the exact charger location instead of searching
  - Works with Google Maps, Waze, and other navigation apps

- **Home Location Setting**: Set your home location for charging session tracking
  - Sessions near home are automatically labeled "Home"
  - Configure in Settings > Location Services

- **Mock Data Mode**: Test the app without a vehicle connection
  - Enable in Settings > Developer > Mock Data
  - Simulates charging sessions and vehicle data

### Bug Fixes

- Fixed maps opening wrong locations (geo URI fix)
- Fixed DC charging detection when BMS status is stale
- Improved energy calculation accuracy via power integration

---

## Version 1.2.0 (Build 65) - 2026-01-11

### Major Features

- **Android AI Box Compatibility**: Full support for Android AI boxes (Carlinkit, Ottocast, etc.)
  - In-memory session storage as primary storage method
  - MQTT-based persistence for cross-session data
  - Handles restricted storage access on AI box devices

- **Reliable Charging Detection**: Completely rewritten charging detection logic
  - Uses HV battery current (batteryCurrent/HV_A) as PRIMARY indicator
  - Negative current = charging, resets to 0 when charging stops
  - Ignores stale BMS_CHG_STATUS, AC_CHG_A, DC_CHG_A values
  - Stationary check (speed < 1 km/h for 2 samples) prevents regen braking false positives
  - AC vs DC determined by power level (>11kW = DC)

- **Energy Accumulation**: Accurate kWh tracking via power integration
  - Integrates power samples over time (kW × hours)
  - Uses HV current × voltage for reliable power calculation
  - SOC-based energy calculation as fallback

### Improvements

- **Database Initialization**: Multi-path fallback for SQLite
  - Tries: Documents directory → Support directory → Default path
  - Creates directories if missing
  - Retry logic with delays

- **Multi-tier Storage**: Cascading storage with automatic fallbacks
  - Priority: In-memory → SQLite → SharedPreferences → File storage
  - Each tier tries independently for maximum compatibility
  - MQTT always publishes for Home Assistant persistence

### Bug Fixes

- Fixed charging detection not working when BMS_CHG_STATUS is stale
- Fixed AC charging being detected as DC (BMS showed wrong type)
- Fixed charging not stopping when cable unplugged (stale charger PIDs)
- Fixed energy calculation using unreliable AC/DC charger values

### Known Issues

- **Stale PIDs**: BMS_CHG_STATUS, AC_CHG_A/V, DC_CHG_A/V do not reset after charging
  - Mitigated by using HV battery current as primary indicator

---

## Version 1.1.0 (Build 35) - 2026-01-10

### Major Features

- **Firebase Analytics Integration**: Optional anonymous fleet statistics collection
  - Aggregated battery health, charging patterns, and efficiency data across all users
  - Privacy-preserving: all data anonymized and bucketed
  - Opt-in with explicit consent dialog
  - Country detection via IP geolocation (country code only, no IP stored)

- **Fleet Statistics Screen**: New screen showing aggregated data from contributing users
  - Average SOH comparison with your vehicle
  - Charging statistics (AC vs DC usage, average power)
  - SOH distribution across the fleet
  - Country distribution of contributors

- **Charging Session History**: Track and view all charging sessions
  - Start/end time, energy added, SOC change
  - Charging type (AC/DC), peak power
  - Accessible from Settings > Charging History

- **GitHub-Based App Updates**: Check for and install updates directly from the app
  - Settings > Updates > Check for Updates
  - Optional GitHub token for higher API rate limits

- **Location Services**: Optional GPS location tracking
  - Enrich ABRP data with location for better route planning
  - Location data only sent to enabled services (ABRP, MQTT)

### Improvements

- **OBD-II WiFi Proxy Support**: Full proxy implementation for external app data sharing
- **Enhanced Connectivity Detection**: Real-time internet status via DNS lookup
- **Improved Charging Detection**: Multiple indicators for reliable AC/DC detection

### Privacy

All Fleet Analytics data is:
- **Anonymous**: Hash-based device ID, no traceability
- **Bucketed**: Values rounded to intervals (5% for SOC/SOH, 10 kW for power)
- **Opt-in**: Disabled by default, requires explicit consent
- **No PII**: No GPS coordinates, vehicle IDs, or personal information collected

---

## Version 1.0.8 (Build 34) - 2026-01-10

### Features

- Firebase Analytics setup and integration
- Fleet Statistics foundation

---

## Version 1.0.7 (Build 32) - 2026-01-10

### New Features

- **Dashboard Charging History**: Recent charging sessions now displayed directly on the dashboard with quick access to full history
- **Internet Status Indicator**: New connectivity indicator shows real-time internet status via DNS lookup
- **PID Priority Indicators**: Low-priority PIDs now show a grey dot indicator to distinguish from real-time data

### UI Improvements

- **Consolidated Power Card**: Voltage, Current, and Power now displayed in a single compact card (V / A / kW format)
- **Swapped Speed and Range**: Speed is now displayed prominently with SOC; Guestimated Range moved to metrics grid
- **Cleaner Service Icons**: Status indicator backgrounds are now white/light for better visibility
- **Updated Tagline**: App description changed to "Data Monitor for EVs"

### Bug Fixes

- **Fixed charging end detection**: Now requires 2 consecutive non-charging samples to confirm charging stopped (prevents false stops)
- **Fixed GitHub token dialog**: Token input dialog now properly scrollable and accessible
- **Removed Graylog feature**: Graylog log streaming removed from app

---

## Version 1.0.6 (Build 31) - 2026-01-10

### Bug Fixes

- **Fixed charging indicator on dashboard**: Now correctly detects charging using negative current (XPENG convention: negative = charging into battery)
- **Fixed BMS_CHG_STATUS value 4**: Added support for high-power DC charging status (value 4)
- **Fixed GitHub rate limiting**: Added optional GitHub token support in Settings to avoid rate limit errors when checking for updates

### Improvements

- **Better DC charging power display**: Now uses DC charger power (DC_CHG_A × DC_CHG_V) for more accurate kW reading during DC fast charging
- **Multiple charging detection methods**: Dashboard charging indicator now checks battery current, CHARGING PID, and BMS_CHG_STATUS

---

## Version 1.0.5 (Build 30) - 2026-01-10

### New Features

- **Priority-Based PID Polling**: PIDs are now categorized as high or low priority
  - High priority PIDs (SOC, voltage, current, speed, charging status) poll every 5 seconds
  - Low priority PIDs (SOH, odometer, cell data, cumulative charge) poll every ~5 minutes
  - Reduces OBD bus traffic by ~50% while keeping critical data fresh
  - Cached values from low-priority PIDs are used between polls

- **Improved Charging Detection**: Now uses HV battery current (HV_A) as primary indicator
  - Negative current = charging (matches dashboard display)
  - Requires 2 consecutive stationary samples to filter out regenerative braking
  - AC vs DC detection based on current magnitude (<50A = AC, >=50A = DC)

- **Dashboard UI Updates**:
  - Range label changed to "Guestimated Range" to clarify it's a calculated estimate
  - Calculated from SOC × battery capacity × efficiency

### Bug Fixes

- **Fixed package_info_plus failure**: Replaced with hardcoded version constants for AAOS compatibility
- **Fixed About section**: Now correctly displays version, build number, and build date
- **Fixed PID formula migration**: Automatic migration to latest PID profile version (v3)

---

## Version 1.0.4 (Build 29) - 2026-01-10

### Bug Fixes

- **Fixed AC charging formula**: AC_CHG_A now uses `[B4:B5]*2` (was `/10`)
- **Fixed AC charging voltage formula**: AC_CHG_V now uses `B4*3` (was `/10`)
- **PID profile migration**: Automatic refresh of PID formulas when profile version changes
- **Bluetooth auto-reconnect**: Improved address storage with dedicated text file fallback

---

## Version 1.0.3 (Build 28) - 2026-01-09

### New Features

- **OBD Proxy Service**: Proxy OBD data to external applications

### Bug Fixes

- **Bluetooth reconnection**: Fixed auto-reconnect not working on app restart
- **Settings persistence**: Improved reliability of OBD address storage

---

## Version 1.0.0 (Build 25) - 2026-01-08

### New Features

- **Real-time Battery Monitoring**: Display live battery SOC, SOH, voltage, current, temperature, and power
- **Multiple Data Sources**: Support for CarInfo API (Android Automotive) and OBD-II Bluetooth adapters
- **ABRP Integration**: Send live telemetry to A Better Route Planner for accurate range predictions
- **MQTT Publishing**: Publish vehicle data to any MQTT broker for home automation and monitoring
- **Home Assistant Discovery**: Automatic entity creation in Home Assistant via MQTT
- **Verified PID Profiles**: Pre-configured PID settings for XPENG G6 and other vehicles
- **Custom PID Support**: Add and configure custom OBD-II PIDs for any vehicle
- **Alert System**: Configurable alerts for low battery, critical battery, and high temperature conditions
- **Historical Data**: Store and view historical vehicle data with configurable retention
- **Debug Logging**: Comprehensive logging for troubleshooting with share functionality
- **VPN Status Detection**: Real-time VPN connection status via Android ConnectivityManager API
- **Tailscale VPN Control**: Connect/disconnect Tailscale directly from app settings

### Dashboard

- **Side-by-side Battery and Range**: Battery SOC and estimated range displayed prominently in colored cards
- Human-readable timestamp showing when data was last updated
- **Service Status Icons**: Visual indicators for MQTT, ABRP, OBD Proxy, and VPN connection status
- Clean, modern UI with large battery level display
- 2-column metric card layout for better readability
- Full odometer display (not abbreviated)
- Additional PID data displayed in consistent card format
- Pull-to-refresh functionality
- Real-time data source indicator

### OBD-II Features

- Bluetooth device scanning and connection
- Automatic reconnection with exponential backoff on connection loss
- Support for ELM327-compatible adapters
- Configurable PID polling with custom formulas
- Verified profiles for known vehicle configurations
- Automatic ECU header switching (BMS: 704, VCU: 7E0)

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

---

## Known Issues

- Custom APK naming outputs to `build/app/outputs/apk/release/` folder
- OBD connection may require vehicle ignition to be on
- Some PIDs may return negative response if not supported in current vehicle state

## Requirements

- Android 10 (API 29) or higher
- Bluetooth permission for OBD-II connection
- Internet permission for ABRP, MQTT, and Fleet Analytics
- For CarInfo API: XPENG Android Automotive OS

## Installation

1. Download the latest APK (e.g., `XPCarData-release-1.2.0+64.apk`)
2. Enable installation from unknown sources if prompted
3. Install on your Android device (AI Box, phone, or tablet)

**Note:** Cannot be installed directly on XPENG's built-in infotainment system. Ideally suited for Android AI boxes (e.g., Carlinkit, Ottocast).

## File Locations

- APK: `build/app/outputs/apk/release/XPCarData-release-{version}+{build}.apk`
- User Guide: `docs/USER_GUIDE.md`
- Release Notes: `docs/RELEASE_NOTES.md`
- PID Reference: `docs/XPENG_G6_PIDs.md`
