# Android Auto Testing with Desktop Head Unit (DHU)

## Overview

The Desktop Head Unit (DHU) is Google's official emulator for testing Android Auto apps on your computer without needing a physical car or head unit.

## Prerequisites

- Android Studio installed
- Android SDK Platform 34 (Android 14.0)
- Android SDK Tools
- Your CarSOC app running on an Android device or emulator
- ADB (Android Debug Bridge) configured

## Step 1: Install Android SDK Platform 34

```bash
# Using Android Studio SDK Manager or command line:
sdkmanager "platforms;android-34"
```

## Step 2: Download Desktop Head Unit

Download the DHU from the official Android Developer site:
https://developer.android.com/training/cars/testing#dhu

Or use the direct link:
https://dl.google.com/android/auto/desktop-head-unit-<VERSION>.zip

**Latest versions (as of 2024):**
- Download from: https://github.com/google/android-auto-desktop-head-unit/releases

Extract the zip file to a convenient location, e.g., `~/android-auto-dhu/`

## Step 3: Enable Developer Mode on Your Device

### If using Android Auto app on your phone:

1. Install the Android Auto app from Google Play Store
2. Open Android Auto app
3. Tap the hamburger menu (three lines) → Settings → About
4. Tap "About Android Auto" version 10 times until "Developer mode enabled" appears
5. Go back to Settings
6. Enable "Developer settings" → "Unknown sources"
7. Enable "Developer settings" → "Application mode"

### If using Android Automotive OS emulator:

Developer mode is automatically enabled.

## Step 4: Connect Your Device

```bash
# Connect via USB and ensure ADB detects it
adb devices

# You should see your device listed like:
# List of devices attached
# emulator-5554   device
```

## Step 5: Run the CarSOC App

Make sure your CarSOC app is running on the connected device:

```bash
cd /Users/stevelea/CarSOC/carsoc
flutter run
```

## Step 6: Start Desktop Head Unit

Navigate to the DHU directory and run:

```bash
cd ~/android-auto-dhu/  # Or wherever you extracted it
./desktop-head-unit
```

**On macOS, you may need to make it executable first:**
```bash
chmod +x desktop-head-unit
```

**Common DHU Command Options:**

```bash
# Default run (auto-detects device)
./desktop-head-unit

# Specify device if you have multiple
./desktop-head-unit --adb <device-id>

# Set specific resolution (1920x1080 is typical car display)
./desktop-head-unit --resolution 1920x1080

# Enable touch input mode
./desktop-head-unit --enable-touch

# Full example
./desktop-head-unit --adb emulator-5554 --resolution 1920x1080 --enable-touch
```

## Step 7: View Your App in DHU

1. DHU window should open showing an Android Auto interface
2. Look for "CarSOC - Battery Monitor" in the app list
3. Tap to open your app
4. You should see the GridTemplate dashboard with 6 vehicle data cards

**Expected Display:**
- Battery Level card (large percentage)
- Range card
- Battery Temp card
- Speed card
- Power card
- Battery Health card

**Action Strip:**
- Refresh button (refreshes the data)
- Details button (navigates to DetailListScreen)

## Step 8: Test Your App

### Test Grid Dashboard:
1. Verify all 6 cards display mock data
2. Tap "Refresh" - data should update
3. Tap "Details" - should navigate to detail list view

### Test Detail List:
1. Verify all vehicle properties are listed
2. Scroll through the list
3. Navigate back to dashboard

### Test Data Updates:
1. Watch the dashboard for 2 seconds
2. Mock data should update (SOC changes, speed varies, etc.)
3. Change update frequency in Settings on phone
4. Verify DHU updates at new frequency

## Troubleshooting

### DHU doesn't detect your app:

1. Check AndroidManifest.xml has CarAppService declared:
   ```xml
   <service
       android:name=".CarAppService"
       android:exported="true">
       <intent-filter>
           <action android:name="androidx.car.app.CarAppService" />
       </intent-filter>
   </service>
   ```

2. Verify automotive_app_desc.xml exists:
   ```xml
   <automotiveApp>
       <uses name="template"/>
   </automotiveApp>
   ```

3. Rebuild and reinstall the app:
   ```bash
   flutter clean
   flutter pub get
   flutter run
   ```

### DHU shows "App is not optimized for driving":

This is normal during development. The app will still work.

### DHU crashes or won't start:

1. Update ADB:
   ```bash
   adb kill-server
   adb start-server
   ```

2. Check device connection:
   ```bash
   adb devices
   ```

3. Try specifying device explicitly:
   ```bash
   ./desktop-head-unit --adb emulator-5554
   ```

### App doesn't receive vehicle data updates:

1. Verify VehicleDataStore is being updated from Flutter
2. Check method channel is working:
   ```bash
   flutter logs | grep "car_app"
   ```

3. Add logging in MainActivity.kt to verify method calls

### DHU display is too small/large:

Adjust resolution:
```bash
./desktop-head-unit --resolution 1280x720   # Smaller
./desktop-head-unit --resolution 1920x1080  # Standard
./desktop-head-unit --resolution 2560x1440  # Larger
```

## Current Implementation Status

✅ **Working:**
- DashboardScreen with GridTemplate (6 cards)
- DetailListScreen with ListTemplate
- VehicleDataStore (LiveData updates)
- Method channel bridge (Flutter → Android)
- Mock data generation (2-second updates)
- Action strip (Refresh, Details buttons)

❌ **Not Yet Implemented:**
- Background service for continuous updates
- Alert notifications in DHU
- Navigation integration
- Multiple screens/routes

## Next Steps After DHU Testing

1. **Verify data flow:**
   - Phone app generates mock data
   - Data sent via method channel to Android
   - VehicleDataStore updates LiveData
   - DHU dashboard reflects changes

2. **Test performance:**
   - Measure update latency
   - Check for dropped frames
   - Verify smooth transitions

3. **Enhance UI:**
   - Add custom icons (replace CarIcon.APP_ICON)
   - Improve card layouts
   - Add color coding (green/orange/red for battery levels)

4. **Test on real AAOS device** (when available):
   - CarInfo API will actually work
   - Test with real vehicle data
   - Verify in actual car environment

## Useful DHU Keyboard Shortcuts

- **Arrow keys** - Navigate menus
- **Enter** - Select item
- **Escape** - Back button
- **M** - Toggle microphone (for voice commands)
- **N** - Night mode toggle
- **D** - Day mode
- **P** - Park mode (enables all features)
- **R** - Drive mode (restricts some features)

## References

- [Android Auto Testing Guide](https://developer.android.com/training/cars/testing)
- [Desktop Head Unit Documentation](https://developer.android.com/training/cars/testing#dhu)
- [Car App Library Templates](https://developer.android.com/training/cars/apps#templates)
- [CarSOC Implementation Plan](~/.claude/plans/compiled-popping-knuth.md)

---

**Note:** DHU testing simulates the Android Auto experience but doesn't provide real vehicle data. CarInfo API will only work on actual Android Automotive OS devices. For now, DHU will display the mock data generated by MockDataService.
