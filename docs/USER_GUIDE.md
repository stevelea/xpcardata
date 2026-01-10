# XPCarData User Guide

## Overview

XPCarData is a battery monitoring app designed for XPENG electric vehicles. It displays real-time battery status, vehicle metrics, and can integrate with external services like ABRP (A Better Route Planner), MQTT brokers, Home Assistant, and Graylog for remote debugging.

## Getting Started

### Installation

1. Download the latest APK file: `XPCarData-v1.0.7-build32.apk`
2. Enable "Install from unknown sources" in your Android settings if prompted
3. Install the APK on your Android device

**Note:** This app cannot be installed directly on XPENG's built-in infotainment system. It is ideally suited for Android AI Boxes (e.g., Carlinkit) but will also work on Android phones or tablets.

### First Launch

When you first open XPCarData, the app will automatically attempt to connect to available data sources:

- **CarInfo API** (Primary): Used on XPENG's Android Automotive OS
- **OBD-II Bluetooth**: For connecting via an OBD-II adapter

## Main Dashboard

The home screen displays:

- **Battery & Range Cards**: Side-by-side display showing:
  - **Battery**: Current State of Charge (SOC) percentage with color-coded background
  - **Guestimated Range**: Calculated driving range in kilometers (SOC × battery capacity × efficiency)
- **Data Source & Timestamp**: Shows the active data source (CarInfo API or OBD-II) and when data was last updated
- **Service Status Icons**: Visual indicators for connected services:
  - **MQTT**: Green when connected to MQTT broker
  - **ABRP**: Green when ABRP telemetry is enabled
  - **Proxy**: Green when OBD Proxy service is running
  - **VPN**: Green when VPN (e.g., Tailscale) is active
- **Metric Cards**:
  - State of Health (SOH)
  - Battery Temperature (Max/Min)
  - Voltage (HV Battery and Cell Max/Min)
  - Current
  - Power (kW)
  - Speed
  - Odometer
  - DC Charging data (when charging)
  - Coolant temperatures
- **Additional Data**: Any extra PIDs configured will appear below the main metrics

Pull down to refresh the data manually.

## Settings

Access settings by tapping the gear icon in the top-right corner.

### OBD-II Connection

If using an OBD-II Bluetooth adapter:

1. Go to **Settings > OBD-II Connection**
2. Ensure Bluetooth is enabled on your device
3. Tap **Scan for Devices** to find your OBD adapter
4. Select your adapter from the list to connect
5. The app will automatically retry connection with exponential backoff if disconnected

### OBD PID Configuration

Configure which PIDs (Parameter IDs) to read from your vehicle:

1. Go to **Settings > OBD PID Configuration**
2. Select a **Verified Profile** if your vehicle is listed (e.g., XPENG G6)
3. Or add **Custom PIDs** manually if you know the specific codes for your vehicle

#### PID Priority System

PIDs are categorized by polling priority to reduce OBD bus traffic:

- **High Priority**: Polled every cycle (5 seconds) - essential real-time data like SOC, voltage, current, speed, and charging status
- **Low Priority**: Polled every ~5 minutes - slowly changing data like SOH, odometer, cell voltages, cumulative charge/discharge

This reduces OBD bus traffic by approximately 50% while keeping critical data fresh. Cached values from low-priority PIDs are used between polls.

### Vehicle Model Selection

Configure your vehicle model for accurate battery capacity:

1. Go to **Settings > Vehicle**
2. Select your XPENG G6 variant:
   - **24LR**: 2024 Long Range / AWD (87.5 kWh)
   - **24SR**: 2024 Standard Range (66.0 kWh)
   - **25LR**: 2025 Long Range / AWD (80.8 kWh)
   - **25SR**: 2025 Standard Range (68.5 kWh)

This affects the "Guestimated Range" calculation on the dashboard.

### ABRP Integration

To send live telemetry to A Better Route Planner:

1. Get your ABRP user token from the ABRP app:
   - Open ABRP > Settings > Car Model > Generic > Link to live data
   - Copy the token shown
2. In XPCarData, go to **Settings > ABRP**
3. Enable ABRP integration
4. Paste your token
5. Optionally set your car model identifier
6. Adjust the update interval (minimum 5 seconds, recommended 30 seconds)

Data sent to ABRP includes: SOC, SOH, speed, voltage, current, power, battery temperature, and odometer.

### MQTT Publishing

To publish vehicle data to an MQTT broker:

**Prerequisites - Remote Access:**

To connect to your home MQTT broker from your vehicle, you'll need a way to access your home network remotely. Use your Tailscale address, public/published address, or any VPN solution you prefer to expose your MQTT broker.

**Recommended options:**
- **Tailscale** (recommended): Install Tailscale on your Android device and home server. Use your Tailscale IP (e.g., `100.x.x.x`) as the broker address. XPCarData can control Tailscale directly - see [Tailscale VPN Control](#tailscale-vpn-control) below.
- **Public DNS/IP**: Use a dynamic DNS service or static IP if your broker is publicly accessible
- **Other VPN solutions**: WireGuard, OpenVPN, ZeroTier, etc.
- **AI Box**: This app can also run on an Android AI Box (e.g., Carlinkit) connected to your vehicle's head unit

**Configuration:**

1. Go to **Settings > MQTT**
2. Enable MQTT publishing
3. Configure:
   - **Broker**: Your MQTT server address (e.g., `100.x.x.x` for Tailscale, your public address, or `mqtt.example.com`)
   - **Port**: Usually 1883 (unencrypted) or 8883 (TLS)
   - **TLS**: Enable for secure connections
   - **Username/Password**: If your broker requires authentication
   - **Vehicle ID**: Unique identifier for your vehicle

**MQTT Topics:**
- `vehicles/{vehicleId}/data` - All vehicle data (JSON)
- `vehicles/{vehicleId}/status` - Online/offline status
- `vehicles/{vehicleId}/alerts` - Alert notifications

### Home Assistant Integration

XPCarData supports automatic Home Assistant discovery via MQTT. When enabled, the app will automatically create sensor entities in Home Assistant.

**To enable:**
1. Go to **Settings > MQTT**
2. Enable **MQTT Publishing**
3. Enable **Home Assistant Discovery**
4. Save settings

**Entities created:**
- **State of Charge** - Battery percentage (%)
- **State of Health** - Battery health (%)
- **Battery Voltage** - HV battery voltage (V)
- **Battery Current** - Current flow (A)
- **Battery Temperature** - Battery temp (°C)
- **Power** - Instantaneous power (kW)
- **Range** - Estimated range (km)
- **Speed** - Vehicle speed (km/h)
- **Odometer** - Total distance (km)
- **Battery Capacity** - Usable capacity (kWh)
- **Charging** - Binary sensor for charging status

All entities are grouped under a single device called "XPCarData {Vehicle ID}" in Home Assistant.

**Requirements:**
- Home Assistant with MQTT integration configured
- MQTT broker accessible from both Home Assistant and your vehicle/device
- Discovery prefix must be `homeassistant` (default)

### Tailscale VPN Control

If you have Tailscale installed, XPCarData can connect and disconnect the VPN directly from settings, making it easy to establish a secure connection to your home network for MQTT.

**To use:**
1. Install and configure Tailscale on your Android device (sign in and set up your network)
2. Go to **Settings > Tailscale VPN**
3. If Tailscale is detected, you'll see Connect/Disconnect buttons
4. Tap **Connect** to start the VPN connection
5. Tap **Disconnect** to stop the VPN
6. Tap **Open Tailscale App** to view connection status or configure Tailscale

**Requirements:**
- Tailscale app must be installed from Google Play Store
- You must have logged in and configured Tailscale at least once
- Tailscale should be running in the background for the most reliable operation

**Note:** XPCarData uses Android intents to control Tailscale. The Tailscale app must be running (or have recently run) in the background for the connect/disconnect commands to work reliably.

**VPN Status Detection:**
The app automatically detects whether any VPN is active using Android's ConnectivityManager API. The VPN status icon on the dashboard will show green when a VPN connection (Tailscale or any other VPN) is active. Status is checked every 10 seconds.

### Alert Thresholds

Configure alerts for battery conditions:

- **Low Battery**: Warning when SOC drops below threshold (default: 20%)
- **Critical Battery**: Alert when SOC is critically low (default: 10%)
- **High Temperature**: Warning when battery temperature exceeds limit (default: 45°C)

### Data Management

- **Update Frequency**: How often to poll for new data (default: 5 seconds)
- **Data Retention**: How long to keep historical data (default: 30 days)
- **Export Data**: Export vehicle data logs for analysis
- **Clear Data**: Delete all stored vehicle data

### App Behavior

- **Start Minimized**: Launch the app in the background on device startup
- **Run in Background**: Keep collecting data when the app is minimized

**Note:** You may need to allow "Run in background" or disable battery optimization for this app in your Android battery/app settings, depending on your Android version. The app will prompt for these permissions when you enable background service, but some devices require manual configuration in system settings.

## Charging Detection

XPCarData automatically detects when your vehicle is charging:

### Detection Method

1. **Primary**: HV Battery Current (HV_A) - negative current indicates charging
   - Requires vehicle to be stationary (speed=0) for 2 consecutive samples
   - This filters out regenerative braking which also shows negative current

2. **Secondary**: BMS Charge Status, VCU Charging Status, DC Charge Status PIDs

### AC vs DC Detection

- **DC Charging**: Current magnitude >= 50A, or BMS status = 2
- **AC Charging**: Current magnitude < 50A, or BMS status = 3

### Charging Sessions

The app automatically tracks charging sessions including:
- Start/end time
- Energy added (kWh)
- SOC change
- Charging type (AC/DC)
- Peak power

View charging history in **Settings > Charging History**.

## Troubleshooting

### No Data Showing

1. Check that your data source is connected (CarInfo API or OBD-II)
2. For OBD-II: Ensure Bluetooth is enabled and the adapter is paired
3. Try pulling down to refresh
4. Check the Debug Log in Settings for error messages

### OBD Connection Issues

1. Ensure your OBD-II adapter is plugged into the vehicle's OBD port
2. Turn on the vehicle's ignition (accessory mode is usually sufficient)
3. Check that Bluetooth is enabled on your device
4. Try forgetting and re-pairing the OBD adapter in Bluetooth settings
5. The app will automatically retry with exponential backoff if connection is lost

### Bluetooth Auto-Reconnect

The app saves the last connected OBD device address in multiple locations for reliability:
- Dedicated text file
- JSON settings file
- SharedPreferences

On startup, it will automatically attempt to reconnect to the last known device.

### ABRP Not Updating

1. Verify your ABRP token is correct
2. Check that ABRP is enabled in settings
3. ABRP updates are rate-limited to minimum 5-second intervals
4. Check the Debug Log for ABRP-related messages

### Data Looks Incorrect

1. Verify you have the correct PID configuration for your vehicle
2. Check that the PID formulas match your vehicle's specifications
3. Some PIDs may not be supported by all vehicle variants
4. The app automatically migrates to the latest PID profile version when formulas are updated

### Check for Updates

The app can check for updates from GitHub releases:
1. Go to **Settings > Updates**
2. Tap **Check for Updates**
3. If an update is available, you can download and install it directly

**GitHub Rate Limiting:** If you see "rate limit exceeded" errors, you can add a GitHub personal access token:
1. Go to **Settings > Updates > GitHub Token**
2. Create a token at github.com → Settings → Developer settings → Personal access tokens
3. Generate a new token (no scopes needed)
4. Paste the token in the app

This increases the API limit from 60 to 5000 requests per hour.

## Debug Log

Access the debug log via **Settings > Debug Log** to view:

- Connection events
- Data source changes
- PID polling (high/low priority)
- ABRP transmission status
- Charging detection events
- Error messages

Use **Share Log** to export the log for troubleshooting.

## Privacy & Data

- Vehicle data is stored locally on your device
- Data is only transmitted to external services (ABRP, MQTT, Graylog) if you explicitly enable and configure them
- No data is collected by the app developers

## Support

For issues and feature requests, please contact the developer or submit an issue on the project repository.
