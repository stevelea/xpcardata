# XPCarData User Guide

## Overview

XPCarData is a battery monitoring app designed for XPENG electric vehicles. It displays real-time battery status, vehicle metrics, and can integrate with external services like ABRP (A Better Route Planner) and MQTT brokers.

## Getting Started

### Installation

1. Download the APK file: `XPCarData-release-1.0.0+2.apk`
2. Enable "Install from unknown sources" in your Android settings if prompted
3. Install the APK on your XPENG vehicle's infotainment system or Android device

### First Launch

When you first open XPCarData, the app will automatically attempt to connect to available data sources:

- **CarInfo API** (Primary): Used on XPENG's Android Automotive OS
- **OBD-II Bluetooth**: For connecting via an OBD-II adapter

## Main Dashboard

The home screen displays:

- **Battery Level**: Large display showing current State of Charge (SOC) percentage
- **Data Source**: Indicates whether data is coming from CarInfo API or OBD-II
- **Metric Cards**:
  - State of Health (SOH)
  - Battery Temperature
  - Voltage
  - Current
  - Power (kW)
  - Speed
  - Odometer
  - Range (if available)
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
5. The app will automatically retry connection every 60 seconds if disconnected

### OBD PID Configuration

Configure which PIDs (Parameter IDs) to read from your vehicle:

1. Go to **Settings > OBD PID Configuration**
2. Select a **Verified Profile** if your vehicle is listed (e.g., XPENG G6)
3. Or add **Custom PIDs** manually if you know the specific codes for your vehicle

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

### Alert Thresholds

Configure alerts for battery conditions:

- **Low Battery**: Warning when SOC drops below threshold (default: 20%)
- **Critical Battery**: Alert when SOC is critically low (default: 10%)
- **High Temperature**: Warning when battery temperature exceeds limit (default: 45°C)

### Data Management

- **Update Frequency**: How often to poll for new data (default: 2 seconds)
- **Data Retention**: How long to keep historical data (default: 30 days)
- **Export Data**: Export vehicle data logs for analysis
- **Clear Data**: Delete all stored vehicle data

### App Behavior

- **Start Minimized**: Launch the app in the background on device startup
- **Run in Background**: Keep collecting data when the app is minimized

**Note:** You may need to allow "Run in background" or disable battery optimization for this app in your Android battery/app settings, depending on your Android version. The app will prompt for these permissions when you enable background service, but some devices require manual configuration in system settings.

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
5. The app will automatically retry every 60 seconds if connection is lost

### ABRP Not Updating

1. Verify your ABRP token is correct
2. Check that ABRP is enabled in settings
3. ABRP updates are rate-limited to minimum 5-second intervals
4. Check the Debug Log for ABRP-related messages

### Data Looks Incorrect

1. Verify you have the correct PID configuration for your vehicle
2. Check that the PID formulas match your vehicle's specifications
3. Some PIDs may not be supported by all vehicle variants

## Debug Log

Access the debug log via **Settings > Debug Log** to view:

- Connection events
- Data source changes
- ABRP transmission status
- Error messages

Use **Share Log** to export the log for troubleshooting.

## Privacy & Data

- Vehicle data is stored locally on your device
- Data is only transmitted to external services (ABRP, MQTT) if you explicitly enable and configure them
- No data is collected by the app developers

## Support

For issues and feature requests, please contact the developer or submit an issue on the project repository.
