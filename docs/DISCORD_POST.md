# XPCarData - Discord Announcement

## Current Post (v1.1.0)

---

**XPCarData v1.1.0 Released - Major Update with Fleet Statistics!**

Battery monitoring app for XPENG vehicles - get real-time SOC, SOH, voltage, current, temperature, power, and estimated range via OBD-II Bluetooth.

**New in v1.1.0:**
- **Fleet Statistics**: See how your battery compares to other XPENG owners (anonymous, opt-in)
- **Charging History**: Track all your charging sessions with detailed stats
- **In-App Updates**: Check for and install updates directly from the app
- **Location Services**: Optional GPS for enhanced ABRP integration

**Features:**
- ABRP integration - live telemetry for accurate range predictions while driving
- MQTT publishing - send data to Home Assistant for monitoring/automation
- Home Assistant auto-discovery - entities automatically appear in HA
- Background service - keeps collecting data when app is minimized
- Configurable alerts for low battery and high temperature
- Tailscale VPN control - connect/disconnect directly from the app

**Privacy First:**
Fleet Statistics is completely opt-in and anonymous:
- No GPS, no vehicle IDs, no personal info
- Only aggregated stats (SOH ranges, charging patterns)
- Country from IP (code only, IP not stored)

**Note:** Cannot be used simultaneously with ABRP's native OBD-II connection unless your adapter supports multiple BLE connections.

**Use Cases:**

**On the road:** Run on your phone while driving to feed live data to ABRP for better route planning. Dashboard shows Battery SOC and Speed side-by-side with status icons for all connected services.

**Charging monitoring:** Leave an old phone/tablet near or in the car connected to the OBD-II adapter. XPCarData will collect and publish charging data to your home MQTT broker via Tailscale. Track your charging progress from anywhere!

**Fleet insights:** Enable Fleet Statistics to see how your battery health compares to other G6 owners and view charging patterns across the community.

**Download:** https://github.com/stevelea/xpcardata

Tested on XPENG G6. Should work with other XPENG models but may need PID configuration adjustments.

Feedback and issues welcome!

---

## Short Version (for posting)

---

**XPCarData v1.1.0 - Battery Monitoring for XPENG Vehicles**

Real-time battery monitoring app with ABRP, Home Assistant, and Fleet Statistics.

**New in v1.1.0:**
- Fleet Statistics - compare your battery to other owners (anonymous, opt-in)
- Charging History - track all sessions with energy, power, duration
- In-App Updates - check and install updates directly
- Location Services - GPS for enhanced ABRP data

**Features:**
- Live battery data: SOC, SOH, voltage, current, temperature, power, range, odometer
- Side-by-side Battery & Speed dashboard with service status icons
- DC charging monitoring (voltage, current, power)
- OBD-II Bluetooth connection (ELM327 compatible)
- ABRP integration for accurate range predictions
- MQTT publishing for Home Assistant / home automation
- Background service for continuous monitoring
- Tailscale VPN control with real-time status
- Configurable update intervals and alerts
- Ideally suited for Android AI boxes (e.g., Carlinkit), also works on phones and tablets
- Cannot be installed directly on XPENG's built-in infotainment

**Requirements:**
- Android 10+
- OBD-II Bluetooth adapter (ELM327 compatible)
- XPENG G6 verified (other XPENG vehicles may need PID adjustments)

**Privacy:** Fleet Statistics is opt-in only. No GPS, vehicle IDs, or personal data collected.

**Download:** https://github.com/stevelea/xpcardata

---

## Long Version (with more details)

---

**XPCarData v1.1.0 - Battery Monitoring for XPENG Electric Vehicles**

I've been working on a battery monitoring app for my XPENG G6 and wanted to share the latest major update with the community.

**What's New in v1.1.0:**

- **Fleet Statistics**: Anonymous, opt-in feature that lets you see how your battery compares to other XPENG owners. View average SOH across the fleet, charging patterns (AC vs DC usage), and geographic distribution of contributors. All data is anonymized - no GPS, vehicle IDs, or personal info collected.

- **Charging History**: The app now tracks all your charging sessions automatically. View start/end times, energy added, SOC change, charging type (AC/DC), and peak power. Great for tracking your charging patterns over time.

- **In-App Updates**: Check for and install updates directly from the app. No need to manually download APKs from GitHub.

- **Location Services**: Optional GPS tracking to enhance ABRP telemetry with precise location data.

**What it does:**
- Reads real-time battery data via OBD-II Bluetooth adapter
- Displays SOC, SOH, voltage, current, temperature, power, range, speed, odometer
- Side-by-side Battery & Speed display with service status icons
- Sends live telemetry to ABRP for accurate range predictions
- Publishes data to MQTT for Home Assistant integration
- Runs in background for continuous monitoring
- Detects and logs charging sessions with AC/DC type detection
- Real-time VPN status monitoring

**Data displayed:**
- State of Charge (SOC) %
- State of Health (SOH) %
- Guestimated Range (km)
- HV Battery Voltage (V)
- HV Battery Current (A)
- Max/Min Cell Voltage (V)
- Max/Min Battery Temperature (°C)
- Battery Coolant Temperature (°C)
- Motor Coolant Temperature (°C)
- DC Charging Voltage/Current/Power
- Cumulative Charge/Discharge (Ah)
- Speed, Odometer
- Service status: MQTT, ABRP, Proxy, VPN, Internet

**Integrations:**
- **ABRP**: Configurable update interval (5 sec - 5 min, default 1 min)
- **MQTT**: Publish to any broker for Home Assistant, Node-RED, etc.
- **Fleet Statistics**: Anonymous aggregated data across all users

**Privacy:**
Fleet Statistics is designed with privacy first:
- Opt-in only - disabled by default
- Anonymous device ID (hash-based, not traceable)
- Data bucketed (5% increments for SOC/SOH, 10 kW for power)
- Country from IP geolocation (country code only, IP not stored)
- No GPS coordinates, vehicle IDs, or personal information

**Platform:**
- Android 10+
- Ideally suited for Android AI boxes (e.g., Carlinkit), also works on phones and tablets
- Cannot be installed directly on XPENG's built-in infotainment system
- Cannot be used simultaneously with ABRP's native OBD connection (single BLE connection limitation)

**Tested on:**
- XPENG G6 (2023+)

Other XPENG vehicles should work but may need PID configuration adjustments.

**Tips:**
- You may need to allow background running or disable battery optimization in Android settings
- ABRP minimum interval is 5 seconds (API rate limit)
- OBD adapter auto-reconnects every 60 seconds if connection is lost
- Enable Fleet Statistics to contribute to community insights

**Download & Documentation:**
https://github.com/stevelea/xpcardata

Feedback and feature requests welcome!

---
