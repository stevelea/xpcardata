# CarSOC Testing Guide

This guide explains how to test the CarSOC app in different configurations.

## Quick Start - Mock Data Testing (Recommended First)

The easiest way to test the app is with mock data. The app automatically uses mock data when CarInfo API is unavailable.

### 1. Run the App

```bash
flutter run
```

The app will:
- ✅ Automatically detect that CarInfo API is unavailable (not on AAOS device)
- ✅ Fall back to Mock Data source
- ✅ Start generating realistic vehicle data every 2 seconds
- ✅ Save data to local SQLite database
- ✅ Display data on the phone screen

### 2. What You'll See

**Phone Screen:**
- Data Source indicator showing "Mock Data (Testing)" in orange
- Large battery level display (SOC %)
- Grid of metrics: Range, Speed, Battery Temp, Power, Battery Health, Voltage
- Data updates automatically every 2 seconds

**Simulated Behavior:**
- Battery SOC drains when "driving" (speed > 0)
- Battery SOC increases when "charging"
- Speed varies realistically
- Temperature changes based on usage
- Random transitions between driving/charging states

### 3. Test the Data Flow

The mock data flows through the entire system:

```
Mock Service → DataSourceManager → Database
                                 → Phone UI
                                 → Android Auto (via method channel)
                                 → MQTT (if configured)
```

---

## Testing Android Auto UI

### Option A: Desktop Head Unit (DHU) - Recommended

The Android Auto Desktop Head Unit lets you test the car display on your computer.

#### Prerequisites

1. **Android SDK Platform Tools** (already installed with Flutter)
2. **Desktop Head Unit (DHU)**

#### Install DHU

```bash
# Check if SDK is installed
which sdkmanager

# Install Android Auto DHU
sdkmanager --install "platforms;android-34"

# Download DHU (if not already installed)
# Visit: https://developer.android.com/training/cars/testing
```

#### Run DHU

1. **Start the DHU:**
   ```bash
   cd $ANDROID_SDK_ROOT/extras/google/auto
   ./desktop-head-unit
   ```

2. **Connect your Android phone to computer via USB**

3. **Enable Developer Mode in Android Auto app:**
   - Open Android Auto app on phone
   - Tap version number 10 times
   - Enable "Developer settings"
   - Enable "Unknown sources"

4. **Run the CarSOC app:**
   ```bash
   flutter run
   ```

5. **Open Android Auto on DHU:**
   - The DHU window should show the car display
   - Look for CarSOC app in the app launcher
   - Tap to open

#### What You'll See on DHU

**Dashboard Screen:**
- 6 cards in grid layout
- Battery SOC with color coding (green/yellow/red)
- Range, Temperature, Speed, Power, Battery Health
- "Refresh" and "Details" buttons

**Detail Screen:**
- Complete list of all vehicle properties
- Organized sections (Battery Info, Vehicle Info)
- Back button to return to dashboard

#### Testing Tips

- Data updates automatically via LiveData
- Pull-to-refresh works on phone UI
- Android Auto UI refreshes when new data arrives
- Test color coding by waiting for battery to drain below 60% and 30%

### Option B: Real Car Testing

If you have an Android Automotive OS (AAOS) vehicle or head unit:

1. **Build APK:**
   ```bash
   flutter build apk --release
   ```

2. **Install on AAOS device:**
   ```bash
   adb install build/app/outputs/flutter-apk/app-release.apk
   ```

3. **Grant Permissions:**
   - Car permissions (CAR_INFO, CAR_ENERGY, CAR_SPEED)
   - Storage permission

4. **Launch:**
   - Find CarSOC in the AAOS app drawer
   - Grant car permissions when prompted
   - App will use real CarInfo API data

---

## Testing MQTT Publishing

Test cloud data publishing to an MQTT broker.

### 1. Use Public Test Broker

For testing, you can use Eclipse's public MQTT broker:

**Broker:** `mqtt.eclipseprojects.io`
**Port:** `1883` (no TLS)
**No authentication required**

### 2. Configure MQTT (TODO: Settings UI not yet implemented)

For now, you can modify the MQTT default settings in `lib/providers/mqtt_provider.dart`:

```dart
factory MqttSettings.defaultSettings() {
  return const MqttSettings(
    broker: 'mqtt.eclipseprojects.io',
    port: 1883,
    vehicleId: 'test_vehicle_001',  // Change this to unique ID
    useTLS: false,
  );
}
```

### 3. Connect to MQTT

The app automatically attempts MQTT connection on startup (once settings UI is implemented).

### 4. Monitor MQTT Messages

Use an MQTT client to subscribe and view published messages:

**Using mosquitto_sub (command line):**
```bash
# Install mosquitto tools
brew install mosquitto  # macOS
# or: apt-get install mosquitto-clients  # Linux

# Subscribe to all topics for your vehicle
mosquitto_sub -h mqtt.eclipseprojects.io -t "vehicles/test_vehicle_001/#" -v
```

**Using MQTT Explorer (GUI):**
1. Download: http://mqtt-explorer.com/
2. Connect to `mqtt.eclipseprojects.io:1883`
3. Subscribe to `vehicles/test_vehicle_001/#`

### 5. Expected MQTT Topics

```
vehicles/{vehicleId}/status          - Online/offline status (retained)
vehicles/{vehicleId}/data/current    - Latest vehicle data (retained)
vehicles/{vehicleId}/data/battery    - Battery-specific metrics
vehicles/{vehicleId}/alerts          - Alert notifications
```

### 6. Sample Published Message

```json
{
  "timestamp": "2024-01-03T10:30:00.000Z",
  "stateOfCharge": 75.5,
  "stateOfHealth": 95.2,
  "batteryCapacity": 64.0,
  "batteryVoltage": 385.3,
  "batteryCurrent": -25.5,
  "batteryTemperature": 28.5,
  "range": 320.0,
  "speed": 65.0,
  "odometer": 15234.5,
  "power": 22.5
}
```

---

## Testing Database Persistence

### 1. Verify Data Storage

```bash
# Connect to running app
flutter run

# Then in another terminal:
adb shell

# Navigate to app database
cd /data/data/com.example.carsoc/databases/
ls -la
# You should see: vehicle_data.db

# View database contents (requires sqlite3)
sqlite3 vehicle_data.db
sqlite> SELECT COUNT(*) FROM vehicle_data;
sqlite> SELECT * FROM vehicle_data ORDER BY timestamp DESC LIMIT 5;
sqlite> .exit
```

### 2. Expected Behavior

- **vehicle_data** table: New row every 2 seconds (from mock data)
- **alerts** table: Alerts generated when:
  - SOC < 20% (warning)
  - SOC < 10% (critical)
  - Temperature > 40°C (warning)
  - Temperature > 45°C (critical)
  - SOH < 85% (info)

---

## Debugging Tips

### Check Logs

```bash
# View Flutter logs
flutter logs

# View Android logcat (more verbose)
adb logcat | grep -E "CarSOC|FlutterActivity|VehicleDataStore"
```

### Common Issues

**1. "No vehicle data available"**
- Check if DataSourceManager initialized: Look for logs
- Verify mock data service is running
- Check database connection

**2. Android Auto not showing app**
- Ensure DHU is running
- Check Developer mode is enabled in Android Auto app
- Verify "Unknown sources" is enabled
- Check AndroidManifest.xml has CarAppService declared

**3. MQTT not connecting**
- Check internet connection
- Verify broker address is correct
- Check firewall settings
- Try public test broker first

**4. Build errors**
- Run `flutter clean`
- Run `flutter pub get`
- Check Android SDK version (min API 28)

---

## Performance Testing

### Check Update Frequency

Mock data generates every 2 seconds. Verify:
- Phone UI updates smoothly
- Database writes don't cause lag
- MQTT publishes don't block UI
- Android Auto refreshes automatically

### Memory Usage

```bash
# Monitor app memory usage
adb shell dumpsys meminfo com.example.carsoc

# Watch for memory leaks over time
# Run app for 5-10 minutes and check memory stays stable
```

### Battery Usage

Mock data polling can drain battery. In production:
- Reduce polling frequency when idle
- Use foreground service notification
- Implement battery optimization exclusion

---

## Next Steps

After confirming basic functionality with mock data:

1. ✅ **Test Android Auto UI** with DHU
2. ✅ **Configure MQTT** and verify cloud publishing
3. ✅ **Test on real device** (optional)
4. 🔧 **Implement Settings UI** to configure MQTT and data sources
5. 🔧 **Add Charts** for historical data visualization
6. 🔧 **Implement OBD-II** support for real vehicle data
7. 🔧 **Test with real CarInfo API** on AAOS device

---

## Expected Test Results

### ✅ Successful Test Checklist

- [ ] App launches without errors
- [ ] Data source shows "Mock Data (Testing)"
- [ ] Battery level displays and updates every 2 seconds
- [ ] All metrics (Range, Speed, Temp, Power, SOH, Voltage) show values
- [ ] Pull-to-refresh works
- [ ] Data persists to SQLite database
- [ ] MQTT publishes successfully (if configured)
- [ ] Android Auto displays dashboard (DHU testing)
- [ ] Android Auto shows detail list (DHU testing)
- [ ] No memory leaks after 10 minutes
- [ ] No crashes or ANRs

---

## Troubleshooting Resources

- **Flutter Docs:** https://flutter.dev/docs
- **Android Auto Guide:** https://developer.android.com/training/cars
- **CarInfo API:** https://developer.android.com/reference/android/car/VehiclePropertyIds
- **MQTT:** https://mqtt.org/
- **Riverpod:** https://riverpod.dev/

---

Happy Testing! 🚗⚡
