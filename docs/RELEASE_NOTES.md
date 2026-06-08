# XPCarData Release Notes

## Version 1.4.20 - 2026-06-06

### Bug fix

- **Hide broken Charge Limit reading**: PID `221130` with formula `[B4:B5]-10` was producing obviously wrong values on the G6 (1710%, 2100%). Until we have a confirmed correct formula from a debug log, the Charge Limit tile is hidden from the home screen and the `charge_limit` HA sensor is removed from discovery. PID is still polled so the raw hex bytes flow through `value_json.rawBytes.CHG_LIMIT` for analysis. On reconnect to MQTT after upgrading, the orphan `charge_limit` HA entity is automatically cleared.

---

## Version 1.4.19 - 2026-05-23

### New Home Assistant entities for v4 PIDs

v1.4.18 added new XPENG G6 PIDs to the polling but the values only landed in the raw `vehicles/<id>/data` MQTT payload — no HA discovery entries were declared so they didn't appear automatically as HA sensors. v1.4.19 adds discovery for:

- **12V Battery** (`AUX_V`)
- **VCU SoC** (`VCU_SOC`)
- **Accelerator Pedal** (`ACCEL_PEDAL`)
- **Brake Pressure** (`BRAKE_PRESSURE`)
- **Front/Rear Motor RPM** (`FRONT_MOTOR_RPM`, `REAR_MOTOR_RPM`)
- **Front/Rear Motor Torque Request** (`FRONT_MOTOR_TORQUE_REQ`, `REAR_MOTOR_TORQUE_REQ`)
- **Motor Coolant Temp** (`MOTOR_T`)
- **Battery Coolant Temp** (`COOLANT_T`)
- **Fast Charge Temp 1/2** (`FAST_CHG_T1`, `FAST_CHG_T2`)
- **Slow Charge Temp 1/2/3** (`SLOW_CHG_T1`, `SLOW_CHG_T2`, `SLOW_CHG_T3`)
- **DC Charge Voltage / Current** (`DC_CHG_V`, `DC_CHG_A`) — useful during DC fast charging sessions

These appear automatically in HA on next MQTT (re)connection after upgrading. Most are low-priority sensors that update every ~5 minutes (cached value published on intermediate cycles).

---

## Version 1.4.18 - 2026-05-23

### XPENG G6 PID profile overhaul (v4)

Corrected the G6 PID profile against community WiCAN definitions. The previous v3 profile had several PIDs on the wrong ECU and several others labelled as the wrong signal. v4 fixes them all. **On first launch after upgrading, the app will auto-migrate** to the new profile.

If v4 misbehaves on your specific G6 firmware variant, **Settings → Vehicle → "Use legacy v3 PIDs"** toggle reverts to the old profile without needing an APK reinstall.

#### Notable changes vs v3
- **Odometer (`220101`)** moved from VCU to BMS, formula changed from `[B5:B6]` to `[B4:B6]` (3 bytes). Fixes issue #11 where the VCU response was being misread as `0x6201 = 25089 km` instead of the actual odometer.
- **12V Auxiliary voltage (`220102`)** moved from VCU to BMS.
- **`22031E`** was labelled `DC_CHG_STATUS` (formula `B4`); is actually `VCU_SOC` (formula `[B4:B5]/10`). Charging detection unchanged — uses HV current, not this PID.
- **`22031A`** was labelled `HV_PWR`; is actually `REAR_MOTOR_TORQUE_REQ` (`[B4:B5]/4-500`). The reported `power` value is now always computed from `HV voltage × HV current` at the OBD service level, which was always the more accurate path.
- **`220321`** was labelled `AC_CHG_A`; is actually `BRAKE_PRESSURE` (`[B4:B5]/5`). The AC charging UI panel was being triggered by this whenever brake was pressed — that spurious trigger is gone. DC charging UI still works (`DC_CHG_A` was correct).
- **`220322`** was labelled `AC_CHG_V`; is actually `FAST_CHG_T1` (`B4-40`).
- **`220325`** was labelled `INV_T`; is actually `SLOW_CHG_T2` (`B4-40`).
- **`220313`** was labelled `RANGE_EST`; is actually `ACCEL_PEDAL` (`B4/2`).
- **`220319`** `MOTOR_TORQUE` renamed `FRONT_MOTOR_TORQUE_REQ`, formula corrected to `[B4:B5]/4-500`.
- **`220317`** motor RPM now applies the G6-specific `-16000` offset.
- **New PIDs**: `220323` fast charging temp 2, `220324` slow charging temp 1, `220326` slow charging temp 3 (all `B4-40`).

---

## Version 1.4.17 - 2026-05-23

### New Features

- **Custom battery capacity (issue #7)**: vehicle picker now has a "Other / Custom" entry. When selected the user enters their pack's usable kWh, which is then used for range estimation, charging-session energy math, and MQTT publishing. Lets non-XPENG community-profile users (Kia, Hyundai, etc.) get correct numbers instead of the 87.5 kWh fallback.
- **Custom PIDs included in backup (issue #8)**: backup/restore now includes the `obd_pids` setting (community-profile and user-added PIDs). On AI boxes the restore also writes directly to the `obd_pids.json` file fallback so PIDs survive a fresh install even if SharedPreferences is unreliable. Backup file format version bumped to v2 — v1 backups still import.
- **Raw bytes per PID over MQTT (issue #9)**: each polled PID now publishes its cleaned hex byte string (with multi-frame and CAN-header prefixes stripped) under `value_json.rawBytes.<PID_NAME>`. HA template sensors can now extract individual bytes for multi-signal PIDs (e.g. Hyundai/Kia 220101 which packs 20 signals into one response) without re-implementing ELM327 parsing in Jinja.

---

## Version 1.4.16 - 2026-05-23

### Bug Fixes

- **OBD parser multi-frame fix (issue #5)**: Multi-frame ISO-TP responses (used by Kia/Hyundai PID `220101` and any other vehicle returning long PID payloads) now parse correctly. The parser previously ignored the per-frame `0:` / `1:` / `2:` sequence prefixes added by ELM327, which left a stray nibble in the byte stream and shifted every subsequent byte by half a position. Bytes now align with the formula's `B0`, `B1`, ... indices as intended.
- **`last_collected` no longer advances when the car isn't responding (issue #4)**: When the OBD adapter is connected but every PID returns NaN / empty (car asleep, gateway timeout, etc.), the app no longer publishes a `VehicleData` message stamped with `DateTime.now()`. Home Assistant's `last_collected` attribute now reflects the time of the last *actual* successful poll, so users can tell whether SOC / range / etc. are live or stale.

---

## Version 1.3.1 - 2026-01-13

### New Features

- **12V Battery Protection**: Monitors auxiliary battery voltage to prevent depletion
  - Configurable voltage threshold (11.0V - 13.0V, default 12.5V)
  - Automatically pauses OBD polling when 12V drops below threshold
  - Resumes polling when voltage recovers (with 0.3V hysteresis)
  - Enable/disable in Settings > App > 12V Battery Protection

- **Tablet-Optimized Settings**: Settings screen now scales properly for tablets
  - 3-column layout on tablets (vs 2 on phones)
  - Proportionally sized icons and spacing

### Improvements

- AUX_V (12V voltage) PID now polled every 5 seconds (was 5 minutes) for faster protection response

---

## Version 1.3.0 - 2026-01-12

### New Features

- **Backup & Restore**: Export and import app settings and charging history
  - Save backup to Downloads folder as JSON file
  - Copy backup to clipboard for easy sharing
  - Import from file picker
  - Includes all settings, API keys, and charging session history

- **Reorganized Settings**: Settings screen now uses category tiles for easier navigation
  - **Connections**: MQTT, Tailscale VPN, OBD Proxy, Data Sources
  - **Integrations**: ABRP, Fleet Statistics
  - **Vehicle**: Model selection, Location services, Home location, LHD/RHD layout
  - **Data**: Backup/Restore, Data Management, Data Usage statistics
  - **App**: Behavior settings, Alert thresholds, Updates
  - **About**: Version info, Debug mode, Mock data

### Improvements

- Cleaner settings organization with dedicated sub-screens
- Settings tiles optimized for various screen sizes
- Each setting category is now self-contained and easier to find

---

## Version 1.2.2 - 2026-01-12

### Bug Fixes

- **Fixed GitHub update repository**: Now correctly checks `stevelea/xpcardata` for updates
  - Previously was pointing to wrong repository

---

## Version 1.2.1 - 2026-01-12

### Improvements

- **Switched to semantic versioning**: Now using patch versions (1.2.1, 1.2.2, etc.) instead of build numbers
  - In-app update checker now correctly detects new releases
  - Cleaner version display throughout the app

- **Larger splash screen icon**: App icon now displays at 512x512 on splash screen
  - Scaled versions for all screen densities (mdpi through xxxhdpi)
  - Much more visible during app startup

- **In-app updates support ZIP files**: GitHub releases use compressed ZIP files (under 50MB limit)
  - Automatically detects ZIP vs APK assets
  - Downloads ZIP, extracts APK, installs, cleans up

- **Settings auto-save**: Boolean toggle settings now save immediately when changed

- **Tailscale auto-connect reliability**: Improved VPN auto-connect on app startup
  - Wakes Tailscale app first, verifies VPN connected, retries up to 3x

- **Start Minimised fix**: Setting now works on both device boot and manual app launch

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
