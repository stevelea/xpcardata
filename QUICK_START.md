# CarSOC - Quick Start Guide

**EV Battery Monitor for Android Auto**

---

## Installation on Real Device

### Option 1: Automated Build & Install
```bash
cd /Users/stevelea/CarSOC/carsoc
./build_apk.sh
```
Follow the prompts to build and install.

### Option 2: Manual Build
```bash
cd /Users/stevelea/CarSOC/carsoc
export PATH="$PATH:/Users/stevelea/flutter/bin"

# Build release APK
flutter build apk --release

# Install on device
adb install build/app/outputs/flutter-apk/app-release.apk
```

### Option 3: Transfer APK Manually
1. Build APK (see Option 2)
2. Copy `build/app/outputs/flutter-apk/app-release.apk` to your device
3. Open file and tap "Install"

**APK Location:** `build/app/outputs/flutter-apk/app-release.apk`

---

## First Launch

1. **Open CarSOC** on your device
2. Grant permissions if prompted
3. You'll see the home screen with vehicle metrics
4. Data updates every 2 seconds (default)

---

## Features

### Home Screen
- **Battery Level** - Large display showing state of charge (%)
- **6 Metric Cards:**
  - Range (km)
  - Speed (km/h)
  - Battery Temperature (°C)
  - Power (kW)
  - Battery Health (%)
  - Voltage (V)
- Pull down to refresh

### Settings Screen
Tap the ⚙️ icon in top right to access settings:

#### MQTT Configuration
- **Enable MQTT Publishing** - Toggle on to send data to cloud
- **Broker Address** - Default: mqtt.eclipseprojects.io
- **Port** - Default: 1883 (8883 for TLS)
- **Vehicle ID** - Identifier for your vehicle
- **Username/Password** - Optional authentication
- **Use TLS/SSL** - Secure connection
- **Test Connection** - Verify MQTT setup

#### Alert Thresholds
- **Low Battery Warning** - Default: 20%
- **Critical Battery Alert** - Default: 10%
- **High Temperature Alert** - Default: 45°C

#### Data Management
- **Data Retention Period** - Keep data for 7-365 days
- **Clear All Data** - Delete all vehicle data and alerts

#### App Behavior
- **Update Frequency** - 1 second to 10 minutes (default: 2 seconds)
- **Start Minimised** - App starts in background

---

## Android Auto Integration

### Setup
1. **On your phone:**
   - Install Android Auto app from Play Store
   - Open Android Auto → Settings → About
   - Tap version 10 times to enable developer mode
   - Enable "Unknown sources" in Developer settings

2. **In your car:**
   - Connect phone via USB
   - Android Auto should launch automatically
   - Or tap Android Auto icon on car display

3. **Launch CarSOC:**
   - On car display, tap app launcher
   - Look for "CarSOC - Battery Monitor"
   - Tap to open

### Android Auto Dashboard
- **Grid view** with 6 metric cards
- **Refresh button** - Update data
- **Details button** - View full list of metrics
- Data updates automatically based on your settings

---

## MQTT Cloud Publishing

### Enable MQTT
1. Go to Settings → MQTT Configuration
2. Toggle "Enable MQTT Publishing" ON
3. Configure broker settings (or use defaults)
4. Tap "Test Connection" to verify
5. Tap Save icon

### Monitor Data
From any computer:
```bash
mosquitto_sub -h mqtt.eclipseprojects.io -t "vehicles/TEST_VEHICLE_001/data" -v
```

You'll see JSON messages like:
```json
{"stateOfCharge":87.3,"batteryVoltage":385.2,"range":324.5,...}
```

### Change Vehicle ID
- Settings → MQTT Configuration → Vehicle ID
- Change "TEST_VEHICLE_001" to your preferred ID
- Topic will be: `vehicles/YOUR_VEHICLE_ID/data`

---

## Changing Update Frequency

1. Go to Settings → App Behavior
2. Move "Update Frequency" slider
   - Left: Faster updates (1 second minimum)
   - Right: Slower updates (10 minutes maximum)
3. Tap Save icon
4. **On real device:** Settings persist after app restart ✅
5. Return to home screen - data updates at new frequency

**Note:** Faster updates = more battery usage. Recommend 2-5 seconds for normal use.

---

## Testing Features

### What Works on Real Device (vs Emulator)
✅ **Database** - Data persists between app restarts
✅ **Settings** - All settings save and reload
✅ **Performance** - Faster, smoother UI
✅ **Plugins** - sqflite and shared_preferences work properly

### Testing Checklist
- [ ] Mock data updates every 2 seconds
- [ ] Change update frequency, verify it applies
- [ ] Close app completely, reopen, settings still saved
- [ ] Enable MQTT, verify data publishes
- [ ] Test Android Auto connection (if available)
- [ ] Check battery usage (Settings → Battery)

---

## Current Data Source

CarSOC automatically selects the best available data source:

1. **CarInfo API** (Android Automotive OS only)
   - Direct vehicle data from car's computer
   - Only works on cars with Android Automotive built-in
   - Currently: Not available (requires AAOS device)

2. **OBD-II Bluetooth** (Future feature)
   - External OBD-II adapter via Bluetooth
   - Works on any car with OBD-II port
   - Currently: Disabled (dependency issues)

3. **Mock Data** ✅ Currently Active
   - Simulates realistic vehicle data
   - For testing and development
   - Updates show how real data would look

**You're currently using Mock Data**, which is perfect for testing all features.

---

## Troubleshooting

### App Won't Install
- Check storage space (need ~100 MB free)
- Enable "Install from unknown sources" in Settings
- Uninstall old version first: `adb uninstall com.example.carsoc`

### App Crashes on Launch
```bash
# Check logs
adb logcat | grep "CarSOC"
```
- Ensure Android version is 10+ (API 29+)
- Clear app data: Settings → Apps → CarSOC → Clear data

### Settings Not Saving
- This only happens on emulator, real device is fine
- Verify you're on a real device, not emulator
- Check app permissions in Android settings

### MQTT Not Publishing
1. Enable MQTT in Settings
2. Check internet connection
3. Test with "Test Connection" button
4. Verify broker address is correct
5. Check firewall if using custom broker

### Android Auto Not Showing App
1. Enable developer mode in Android Auto app
2. Enable "Unknown sources"
3. Rebuild app after enabling
4. Disconnect and reconnect USB

---

## Performance Tips

### Battery Optimization
- Use update frequency of 5 seconds or more for normal use
- Disable MQTT when not needed (saves network battery)
- Enable "Start Minimised" to reduce UI overhead

### Data Usage
- MQTT uses minimal data (~1 KB per update)
- At 2-second updates: ~1.8 MB per hour
- At 5-second updates: ~720 KB per hour

### Storage
- Database grows over time
- Set data retention to 30 days for balance
- Use "Clear All Data" if storage is low

---

## Version Info

**Version:** 1.0.0
**Platform:** Android 10+ (API 29+)
**APK Size:** ~50 MB (release), ~60 MB (debug)
**Min Storage:** 100 MB
**Permissions:** Internet, Foreground Service, Notifications

---

## Support & Documentation

- **[BUILD_APK.md](BUILD_APK.md)** - Build instructions
- **[ANDROID_AUTO_TESTING.md](ANDROID_AUTO_TESTING.md)** - Android Auto setup
- **[TESTING_SUMMARY.md](TESTING_SUMMARY.md)** - Test results
- **[PROJECT_STATUS.md](PROJECT_STATUS.md)** - Complete project overview

---

## What's Next?

### Planned Features
- Real CarInfo API integration (when AAOS device available)
- Alert notifications for low battery
- Historical data charts
- Trip tracking and analytics
- Multiple vehicle profiles

### Contributing
This is a personal project. Feel free to:
- Report bugs
- Suggest features
- Fork and modify for your needs

---

**Enjoy monitoring your EV battery with CarSOC!** 🚗🔋📱
