# XPCarData - Discord Announcement

## Current Post

---

**XPCarData v1.0.0 Released**

Battery monitoring app for XPENG vehicles - get real-time SOC, SOH, voltage, current, temperature, and power data via OBD-II Bluetooth.

**Features:**
- ABRP integration - live telemetry for accurate range predictions while driving
- MQTT publishing - send data to Home Assistant for monitoring/automation
- Home Assistant auto-discovery - entities automatically appear in HA
- Background service - keeps collecting data when app is minimized
- Configurable alerts for low battery and high temperature

**Note:** Cannot be used simultaneously with ABRP's native OBD-II connection unless your adapter supports multiple BLE connections.

**Use Cases:**

**On the road:** Run on your phone while driving to feed live data to ABRP for better route planning. Data can also be sent to Home Assistant via MQTT at the same time, or use MQTT exclusively if you prefer ABRP's native OBD connection.

**Charging monitoring:** Leave an old phone/tablet near or in the car connected to the OBD-II adapter ( for example AI box powered by car 12v ) . Use the XPeng app's "Enable 12V" feature or an X-Combo to wake the car and turn on 12V power - XPCarData will then collect and publish charging data to your home MQTT broker via Tailscale. Track your charging progress from anywhere!

**Smart charging:** The MQTT data may help with EVCC or other smart charger setups that need real-time SOC data from the vehicle.

**Download:** https://github.com/stevelea/xpcardata

Tested on XPENG G6. Should work with other XPENG models but may need PID configuration adjustments.

Feedback and issues welcome!

---

## Short Version (for posting)

---

**XPCarData - Battery Monitoring for XPENG Vehicles**

Real-time battery monitoring app with ABRP and Home Assistant integration.

**Features:**
- Live battery data: SOC, SOH, voltage, current, temperature, power, odometer
- OBD-II Bluetooth connection (ELM327 compatible)
- ABRP integration for accurate range predictions
- MQTT publishing for Home Assistant / home automation
- Background service for continuous monitoring
- Configurable update intervals and alerts
- Works on Android phones, tablets, or AI boxes (e.g., Carlinkit)

**Requirements:**
- Android 10+
- OBD-II Bluetooth adapter (ELM327 compatible)
- XPENG G6 verified (other XPENG vehicles may need PID adjustments)

**MQTT Setup:**
Use your Tailscale address, public/published address, or any VPN solution you prefer to expose your MQTT broker. Tailscale is recommended but you can use whatever solution works for you.

**Note:** You may need to allow "Run in background" in Android battery/app settings depending on your Android version.

**Download:** https://github.com/stevelea/xpcardata

---

## Long Version (with more details)

---

**XPCarData v1.0.0 - Battery Monitoring for XPENG Electric Vehicles**

I've been working on a battery monitoring app for my XPENG G6 and wanted to share it with the community.

**What it does:**
- Reads real-time battery data via OBD-II Bluetooth adapter
- Displays SOC, SOH, voltage, current, temperature, power, speed, odometer
- Sends live telemetry to ABRP for accurate range predictions
- Publishes data to MQTT for Home Assistant integration
- Runs in background for continuous monitoring
- Detects and logs charging sessions

**Data displayed:**
- State of Charge (SOC) %
- State of Health (SOH) %
- HV Battery Voltage (V)
- HV Battery Current (A)
- Max/Min Cell Voltage (V)
- Max/Min Battery Temperature (C)
- Battery Coolant Temperature (C)
- Motor Coolant Temperature (C)
- DC Charging Voltage/Current
- Cumulative Charge/Discharge (Ah)
- Speed, Odometer

**Integrations:**
- **ABRP**: Configurable update interval (5 sec - 5 min, default 1 min to avoid rate limiting)
- **MQTT**: Publish to any broker for Home Assistant, Node-RED, etc.

**MQTT Remote Access:**
To connect to your home MQTT broker from your vehicle, use:
- Tailscale (recommended) - Use your Tailscale IP (100.x.x.x)
- Public DNS/IP with dynamic DNS
- WireGuard, OpenVPN, ZeroTier, or other VPN solutions

**Platform:**
- Android 10+
- Works on phones, tablets, or Android AI boxes (e.g., Carlinkit)
- Cannot be used simultaneously with ABRP's native OBD connection (single BLE connection limitation)

**Tested on:**
- XPENG G6 (2023+)

Other XPENG vehicles should work but may need PID configuration adjustments.

**Tips:**
- You may need to allow background running or disable battery optimization in Android settings
- ABRP minimum interval is 5 seconds (API rate limit)
- OBD adapter auto-reconnects every 60 seconds if connection is lost

**Download & Documentation:**
https://github.com/stevelea/xpcardata

Feedback and feature requests welcome!

---
