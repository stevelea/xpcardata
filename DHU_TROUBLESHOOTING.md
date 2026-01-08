# DHU Troubleshooting - CarSOC Not Appearing

## Issue Fixed

**Problem:** CarSOC app not appearing in DHU app list

**Root Cause:** The CarAppService had `category.NAVIGATION` which restricted it to navigation apps only. CarSOC is a monitoring/dashboard app, not navigation.

**Fix Applied:** Removed the category restriction from AndroidManifest.xml (line 79)

## Steps to Get CarSOC Working in DHU

### 1. Rebuild and Reinstall the App

The AndroidManifest.xml was just updated, so you need to rebuild:

```bash
cd /Users/stevelea/CarSOC/carsoc

# Clean build
flutter clean
flutter pub get

# Rebuild and install
flutter run
```

Wait for the app to fully install and launch on your emulator/device.

### 2. Verify App is Running

- You should see the CarSOC home screen on your device
- Verify mock data is updating (battery level, speed, etc.)
- Keep the app running in the foreground or background

### 3. Restart DHU

If DHU was already running, restart it to detect the newly installed app:

**In Android Studio:**
- Stop the DHU session
- Start it again from Tools → Device Manager → DHU

**Or via command line:**
```bash
# Stop existing DHU (Ctrl+C if running in terminal)
# Then restart
~/android-auto-dhu/desktop-head-unit --adb emulator-5554
```

### 4. Look for CarSOC in DHU

Once DHU restarts:
1. You should see the Android Auto home screen
2. Look for the app launcher icon (grid icon)
3. Tap to see all apps
4. **Look for "CarSOC"** in the app list
5. Tap CarSOC to open it

## What You Should See

### Dashboard Screen (GridTemplate)
- Title: "CarSOC - Battery Monitor"
- 6 cards in a grid:
  - Battery Level (e.g., "87.3%")
  - Range (e.g., "324 km")
  - Battery Temp (e.g., "28.5°C")
  - Speed (e.g., "65 km/h")
  - Power (e.g., "45.2 kW")
  - Battery Health (e.g., "95.0%")

### Action Strip (Bottom Right)
- "Refresh" button - refreshes the data
- "Details" button - navigates to detail list

### Detail List Screen
- Full list of all vehicle properties
- Formatted values with units
- Back button to return to dashboard

## Additional Troubleshooting

### Still Not Seeing CarSOC?

#### Check 1: Verify CarAppService is Registered

Run this command to check if the service is properly registered:

```bash
# Using Android Studio terminal or external terminal with adb
adb shell dumpsys package com.example.carsoc | grep -A 5 "CarSOCCarAppService"
```

You should see:
```
Service #0:
  com.example.carsoc/.CarSOCCarAppService
    intent-filter:
      Action: "androidx.car.app.CarAppService"
```

#### Check 2: Verify automotive_app_desc.xml Exists

The file should exist at:
`android/app/src/main/res/xml/automotive_app_desc.xml`

Contents should be:
```xml
<?xml version="1.0" encoding="utf-8"?>
<automotiveApp>
    <uses name="template"/>
</automotiveApp>
```

#### Check 3: Check Logcat for Errors

In Android Studio:
1. Open Logcat (bottom panel)
2. Filter by: `CarSOC` or `CarAppService`
3. Look for any errors related to Android Auto

Common errors:
- "Service not found" - rebuild and reinstall
- "Template validation failed" - check DashboardScreen.kt
- "Host validation failed" - check CarSOCCarAppService.kt

#### Check 4: Enable Unknown Sources (Android Auto App)

If using Android Auto app on a phone (not AAOS):

1. Open Android Auto app
2. Tap hamburger menu → Settings → About
3. Tap version 10 times to enable developer mode
4. Go back to Settings
5. Tap Developer settings
6. Enable "Unknown sources"
7. Enable "Application mode"

#### Check 5: Verify Device Connection

```bash
# Check device is connected
adb devices

# Should show:
# List of devices attached
# emulator-5554   device
```

If device shows "offline" or "unauthorized":
```bash
adb kill-server
adb start-server
adb devices
```

### DHU Shows "App Not Optimized for Driving"

This is **normal during development**. The app will still work. This warning appears because:
- App is not published on Google Play
- App is not signed with production keys
- Developer mode is enabled

You can safely ignore this warning.

### App Crashes When Opening in DHU

Check these files for issues:

1. **CarSOCCarAppService.kt** - Verify `createHostValidator()` and `onCreateSession()`
2. **DashboardScreen.kt** - Check `onGetTemplate()` builds valid GridTemplate
3. **VehicleDataStore.kt** - Ensure it's initialized without errors

View crash logs:
```bash
adb logcat | grep "AndroidRuntime"
```

### Data Not Updating in DHU

1. **Check Flutter app is sending data:**
   - Open the Flutter app on the phone
   - Verify data is updating there
   - Check console for "Updating VehicleDataStore" logs

2. **Check VehicleDataStore.kt:**
   - LiveData should be updating when Flutter sends data via method channel
   - Add logging in MainActivity.kt method channel handler

3. **Force refresh:**
   - Tap the "Refresh" button in DHU
   - Data should update immediately

## Testing Checklist

- [ ] App rebuilt after AndroidManifest.xml change
- [ ] App installed and running on device
- [ ] DHU restarted after app installation
- [ ] CarSOC appears in DHU app list
- [ ] Can open CarSOC in DHU
- [ ] Dashboard shows 6 cards with data
- [ ] Refresh button works
- [ ] Details button navigates to list view
- [ ] Data updates automatically every 2 seconds
- [ ] Can navigate back from details to dashboard

## Success!

Once you see the dashboard in DHU with all 6 cards showing vehicle data, you've successfully integrated Android Auto!

**Next steps:**
- Test navigation between screens
- Test data updates in real-time
- Adjust update frequency in phone app and verify DHU updates accordingly
- Test different mock data scenarios

---

**Note:** All Android Auto code is now properly configured. The category restriction was the only issue preventing the app from appearing in DHU.
