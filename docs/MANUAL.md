# XPCarData User Manual

**Version 1.3.87** | Battery Monitor for XPENG Electric Vehicles

---

## Table of Contents

1. [Introduction](#introduction)
2. [Installation](#installation)
3. [Quick Start](#quick-start)
4. [Android AI Box Setup](#android-ai-box-setup)
5. [Dashboard Overview](#dashboard-overview)
6. [OBD-II Connection](#obd-ii-connection)
7. [Data Sources](#data-sources)
8. [Integrations](#integrations)
   - [MQTT & Home Assistant](#mqtt--home-assistant)
   - [ABRP Integration](#abrp-integration)
   - [Tailscale VPN](#tailscale-vpn)
9. [Charging Sessions](#charging-sessions)
10. [Fleet Statistics](#fleet-statistics)
11. [Settings Reference](#settings-reference)
12. [Troubleshooting](#troubleshooting)
13. [Privacy & Data](#privacy--data)

---

## Introduction

XPCarData is a comprehensive monitoring app for XPENG electric vehicles (primarily XPENG G6). It provides:

- **Real-time battery monitoring** - SOC, voltage, current, temperature, cell voltages
- **Charging session tracking** - Automatic detection, energy calculation, history
- **Smart home integration** - MQTT publishing with Home Assistant auto-discovery
- **Route planning** - ABRP (A Better Route Planner) telemetry integration
- **Fleet analytics** - Anonymous statistics to compare your vehicle with others
- **12V battery monitoring** - Optional BM300 Pro Bluetooth battery monitor support

---

## Installation

### Download

Download the latest release from GitHub:
**https://github.com/stevelea/xpcardata/releases**

1. Download `XPCarData-vX.X.X.zip`
2. Extract to get the APK file
3. Transfer to your Android device

### Install on Android Device

1. Open the APK file
2. If prompted, enable **"Install from unknown sources"** in Android settings
3. Complete the installation
4. Open XPCarData

### Supported Devices

| Device Type | Compatibility | Notes |
|-------------|---------------|-------|
| Android Phone/Tablet | Full | Android 10+ recommended |
| Android AI Box | Full | See [AI Box Setup](#android-ai-box-setup) |
| XPENG Built-in Screen | Not Supported | Use AI Box instead |

---

## Quick Start

1. **Install the app** on your Android device
2. **Connect OBD-II adapter** to your vehicle's OBD port (under dashboard)
3. **Open the app** and go to Settings > OBD-II Connection
4. **Scan and connect** to your Bluetooth OBD adapter
5. **View real-time data** on the dashboard

The app will automatically:
- Detect your vehicle type and load the correct PID profile
- Start polling vehicle data every 5 seconds
- Track charging sessions when detected
- Reconnect if the Bluetooth connection is lost

---

## Android AI Box Setup

XPCarData is designed to work on **Android AI Boxes** (Carlinkit, Ottocast, etc.) that plug into your car's Android Auto or CarPlay interface.

### Important: 12V Power Requirements

**For charging monitoring to work on an AI Box, the car's 12V system must remain powered.**

Most XPENG vehicles turn off 12V power when the car is locked or after a timeout. To keep the AI box running during charging:

#### Option 1: XPENG App Automation (Recommended)

Use the XPENG mobile app to create an automation rule:

1. Open **XPENG App** > **Vehicle** > **Automation**
2. Create a new rule: **"Keep 12V on Exit 24 Hours"**
3. Configure conditions:
   - **Condition 1**: Enter/Exit Vehicle - Driver Exit
   - **Condition 2**: Door Driver Closed
4. Configure action:
   - **Trunk Power Delay Off**: Cycle & Duration = **Every time 24 hours**
5. Enable the automation

This keeps 12V power active for 24 hours after you exit the vehicle, allowing the AI box to monitor charging sessions.

#### Option 2: Hardwired Power

Some users hardwire the AI box to a always-on 12V circuit. Consult a professional for this option.

### AI Box Storage Limitations

AI boxes have restricted storage access. XPCarData handles this automatically:

| Feature | AI Box Behavior |
|---------|-----------------|
| Charging Sessions | Stored in memory, synced via MQTT |
| Settings | Saved to multiple locations for redundancy |
| Debug Logs | Stored in memory (1000 entries max) |

**Recommended**: Enable MQTT with Home Assistant Discovery for persistent charging history across app restarts.

### AI Box Recommended Settings

1. **Enable MQTT** with Home Assistant Discovery
2. **Enable Tailscale** auto-connect for remote MQTT access
3. **Enable Background Service** to keep the app running
4. **Disable battery optimization** for the app in Android settings

---

## Dashboard Overview

The main dashboard displays real-time vehicle data:

### Top Section
- **Battery SOC** - Large percentage display with color-coded background
- **Speed** - Current vehicle speed (km/h)
- **Data Source** - Shows OBD-II, CarInfo API, or Mock
- **Last Update** - Timestamp of most recent data

### Status Icons
| Icon | Meaning |
|------|---------|
| MQTT (green) | Connected to MQTT broker |
| ABRP (green) | ABRP telemetry active |
| VPN (green) | VPN connection active |
| Internet (green) | Internet connectivity available |

### Metric Cards
- **State of Health (SOH)** - Battery degradation percentage
- **Guestimated Range** - Calculated from SOC × capacity × efficiency
- **Battery Temperature** - Max/Min cell temperatures
- **Voltage / Current / Power** - HV battery electrical data
- **Cell Voltages** - Max/Min individual cell voltages
- **Odometer** - Total distance traveled
- **12V Battery** - Auxiliary battery voltage (OBD + BM300 if enabled)

### Charging Indicator
When charging is detected, a charging card appears showing:
- Charging type (AC/DC)
- Current power (kW)
- Session duration
- Energy added (kWh)

---

## OBD-II Connection

### Supported Adapters

XPCarData works with **ELM327-compatible** Bluetooth OBD-II adapters:
- Classic Bluetooth (SPP profile) adapters
- Most budget ELM327 adapters from Amazon/eBay
- Recommended: Adapters with firmware v1.5 or higher

**Not Supported**: BLE-only adapters, WiFi adapters

### Connection Steps

1. **Plug in adapter** to the OBD-II port (usually under the dashboard, driver side)
2. **Turn on ignition** (accessory mode is sufficient)
3. **Pair via Bluetooth** in Android settings first
4. **Open XPCarData** > Settings > OBD-II Connection
5. **Tap "Scan for Devices"**
6. **Select your adapter** from the list

### Auto-Reconnect

The app automatically:
- Saves the last connected device
- Attempts reconnection on app startup
- Retries every 60 seconds if connection fails
- Uses exponential backoff for retry attempts

### PID Configuration

XPCarData includes a verified PID profile for XPENG G6. PIDs are polled in two priority groups:

| Priority | Interval | PIDs |
|----------|----------|------|
| High | Every 5 seconds | SOC, Voltage, Current, Speed, Charging Status |
| Low | Every 5 minutes | SOH, Odometer, Cell Voltages, Cumulative Energy |

This reduces OBD bus traffic by ~50% while keeping critical data fresh.

---

## Data Sources

XPCarData can receive vehicle data from multiple sources:

| Source | Description | Use Case |
|--------|-------------|----------|
| OBD-II Bluetooth | Direct connection via ELM327 adapter | Primary data source |
| Mock Data | Simulated data for testing | Development/demo |

The app automatically selects the best available source.

---

## Integrations

### MQTT & Home Assistant

Publish vehicle data to any MQTT broker with automatic Home Assistant discovery.

#### Prerequisites

Your MQTT broker must be accessible from the vehicle. Options:
- **Tailscale VPN** (recommended) - Use Tailscale IP address
- **Public IP/DNS** - If broker is publicly accessible
- **Other VPN** - WireGuard, OpenVPN, etc.

#### Configuration

1. Go to **Settings > Connections > MQTT**
2. Enable **MQTT Publishing**
3. Configure:
   - **Broker**: IP address or hostname (e.g., `100.x.x.x` for Tailscale)
   - **Port**: 1883 (standard) or 8883 (TLS)
   - **Vehicle ID**: Unique identifier (e.g., `xpeng_g6`)
   - **Username/Password**: If required
   - **TLS**: Enable for encrypted connections
4. Enable **Home Assistant Discovery**
5. Tap **Connect**

#### Home Assistant Entities

When HA Discovery is enabled, these entities are created automatically:

| Entity | Type | Unit |
|--------|------|------|
| State of Charge | Sensor | % |
| State of Health | Sensor | % |
| Battery Voltage | Sensor | V |
| Battery Current | Sensor | A |
| Battery Temperature | Sensor | °C |
| Power | Sensor | kW |
| Range | Sensor | km |
| Speed | Sensor | km/h |
| Odometer | Sensor | km |
| Charging | Binary Sensor | on/off |

#### MQTT Topics

```
vehicles/{vehicleId}/data        - All vehicle data (JSON)
vehicles/{vehicleId}/status      - Online/offline status
vehicles/{vehicleId}/charging    - Charging session data
```

#### Companion Integration

For advanced charging history in Home Assistant, install:
**[XPENG Charging History Integration](https://github.com/stevelea/ha-xpeng-charging-history)**

Features:
- Persistent charging history storage
- Energy cost calculation
- Statistics dashboard
- Ready-to-use Lovelace cards

---

### ABRP Integration

Send live telemetry to **A Better Route Planner** for accurate trip planning.

#### Setup

1. Open **ABRP app** > Settings > Car Model > Generic > Link to live data
2. Copy the **User Token**
3. In XPCarData: **Settings > Integrations > ABRP**
4. Enable ABRP and paste your token
5. Set update interval (recommended: 30 seconds)

#### Data Sent to ABRP

- SOC, SOH, Speed
- Voltage, Current, Power
- Battery temperature
- Odometer
- GPS location (if enabled)

---

### Tailscale VPN

XPCarData can control Tailscale VPN directly for easy remote access to your home network.

#### Setup

1. Install **Tailscale** from Google Play
2. Sign in and configure your Tailscale network
3. In XPCarData: **Settings > Connections > Tailscale VPN**
4. Tap **Connect** to start the VPN

#### Auto-Connect

Enable **Tailscale Auto-Connect** to automatically establish VPN on app startup.

#### Connectivity Watchdog

The app includes a watchdog service that:
- Checks VPN status every 60 seconds
- Automatically reconnects if disconnected
- Monitors MQTT connection and triggers reconnection

---

## Charging Sessions

XPCarData automatically detects and tracks charging sessions.

### Detection Method

1. **Primary**: Battery current (HV_A) - negative current = charging
   - Requires vehicle stationary (speed < 1 km/h) for 2 samples
   - Filters out regenerative braking
2. **Type Detection**:
   - Power > 11 kW = DC charging
   - Power ≤ 11 kW = AC charging

### Session Data Tracked

| Field | Description |
|-------|-------------|
| Start/End Time | Session timestamps |
| Duration | Total charging time |
| Energy Added | kWh (calculated via power integration) |
| SOC Change | Start % → End % |
| Peak Power | Maximum charging power |
| Charging Type | AC or DC |
| Location | GPS coordinates (if enabled) |
| Charger Name | From OpenChargeMap lookup |

### Viewing History

Go to **Settings > Charging History** to view all sessions.

Sessions are stored:
1. In memory (always works)
2. SQLite database (phones/tablets)
3. MQTT (for Home Assistant persistence)

### Minimum Save Thresholds

Sessions are only saved if:
- Energy added ≥ 0.1 kWh, OR
- SOC gained ≥ 0.5%, OR
- Duration ≥ 1 minute with power

---

## Fleet Statistics

Share anonymous data to see how your vehicle compares to others.

### Enable Fleet Statistics

1. Go to **Settings > Fleet Statistics**
2. Enable **Share Anonymous Fleet Data**
3. Review and accept the consent dialog

### Data Collected (Anonymous)

- Battery health (SOH) percentages
- Charging session statistics
- Battery temperature ranges
- AC vs DC charging distribution
- Country (from IP - country code only)

### Data NOT Collected

- GPS coordinates or routes
- Vehicle identification numbers
- IP addresses (only country code)
- Personal information
- Exact timestamps

### View Fleet Data

Tap **View Fleet Statistics** to see:
- Your SOH vs Fleet Average
- Charging power statistics
- SOH distribution across fleet
- Contributors by country

---

## Settings Reference

### Vehicle Settings
- **Vehicle Model** - Select G6 variant for correct battery capacity
- **Drive Layout** - LHD (Left Hand Drive) or RHD (Right Hand Drive)

### Connection Settings
- **OBD Auto-Connect** - Reconnect on app startup
- **MQTT** - Broker configuration
- **Tailscale** - VPN control and auto-connect
- **ABRP** - Token and interval settings

### App Settings
- **Background Service** - Keep running when minimized
- **Start Minimized** - Launch in background on boot
- **Keep Screen On** - Prevent screen sleep
- **12V Protection** - Pause polling if 12V battery low

### Alert Thresholds
- **Low Battery** - Warning at configurable SOC
- **Critical Battery** - Alert at configurable SOC
- **High Temperature** - Warning at configurable temp

---

## Troubleshooting

### No Data Showing

1. Check OBD-II adapter is connected and ignition is on
2. Verify Bluetooth is enabled and adapter is paired
3. Try pulling down to refresh
4. Check Debug Log for error messages

### OBD Connection Fails

1. Ensure adapter is plugged into OBD port
2. Turn on ignition (accessory mode is sufficient)
3. Forget and re-pair adapter in Bluetooth settings
4. Try a different OBD adapter

### MQTT Not Connecting

1. Verify broker address and port
2. Check VPN connection (if using Tailscale)
3. Verify username/password if required
4. Check firewall allows MQTT traffic (port 1883/8883)

### App Crashes

Crash reports are sent to Firebase Crashlytics automatically. Check:
- Debug Log for recent errors
- GitHub Issues for known problems
- Enable crash reporting in settings

### AI Box Specific Issues

| Problem | Solution |
|---------|----------|
| App stops when car locked | Configure 12V automation (see AI Box Setup) |
| Settings not saved | Enable MQTT for data persistence |
| No charging history | Enable Home Assistant Discovery |

### Debug Log

View diagnostic information:
1. Go to **Settings > About > View Debug Logs**
2. Use **Share Log** to export for troubleshooting

---

## Privacy & Data

### Local Storage

- All vehicle data is stored locally on your device
- Charging history is stored in memory and optionally SQLite

### External Services

Data is only transmitted if you enable each service:

| Service | Data Sent | When |
|---------|-----------|------|
| MQTT | Vehicle telemetry | When connected |
| ABRP | SOC, location, speed | At configured interval |
| Fleet Analytics | Anonymous stats | Periodically |
| Crashlytics | Crash reports | On app crash |

### Fleet Analytics Privacy

- Data is fully anonymized before transmission
- Only country code is derived from IP
- No personal identifiers are collected
- You can opt out at any time

---

## Support

- **GitHub Issues**: https://github.com/stevelea/xpcardata/issues
- **Email**: support@xpcardata.com

---

*XPCarData is an independent project and is not affiliated with XPENG Motors.*
