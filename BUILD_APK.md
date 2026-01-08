# Building CarSOC APK for Real Device

This guide explains how to build an APK file that you can install on a real Android device.

---

## Quick Build (Debug APK)

The fastest way to get an APK for testing on a real device:

```bash
cd /Users/stevelea/CarSOC/carsoc

# Build debug APK
flutter build apk --debug

# The APK will be at:
# build/app/outputs/flutter-apk/app-debug.apk
```

**Install on device:**
```bash
# Via USB
adb install build/app/outputs/flutter-apk/app-debug.apk

# Or copy the APK to your device and install manually
```

---

## Release APK (Recommended for Real Testing)

For better performance and testing persistence features (database, settings), build a release APK:

```bash
cd /Users/stevelea/CarSOC/carsoc

# Build release APK
flutter build apk --release

# The APK will be at:
# build/app/outputs/flutter-apk/app-release.apk
```

**Size:** ~30-50 MB (release build is optimized)

---

## Installation Methods

### Method 1: USB Installation (Recommended)

1. Enable USB debugging on your Android device:
   - Settings → About phone → Tap "Build number" 7 times
   - Settings → Developer options → Enable "USB debugging"

2. Connect device via USB

3. Install APK:
   ```bash
   adb install build/app/outputs/flutter-apk/app-release.apk

   # If app is already installed, use -r to reinstall:
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```

### Method 2: Direct File Transfer

1. Copy APK to your device:
   ```bash
   # Copy to Downloads folder
   adb push build/app/outputs/flutter-apk/app-release.apk /sdcard/Download/CarSOC.apk
   ```

2. On your device:
   - Open Files app → Downloads
   - Tap CarSOC.apk
   - Allow installation from unknown sources if prompted
   - Tap "Install"

### Method 3: Cloud Transfer

1. Upload APK to cloud storage (Google Drive, Dropbox, etc.)
2. Download on your device
3. Install as in Method 2

---

## Build Options

### Fat APK (All Architectures)

Default build includes all CPU architectures (arm64-v8a, armeabi-v7a, x86_64):

```bash
flutter build apk --release
```

**Size:** ~50 MB

### Split APKs (Smaller Size)

Build separate APKs for each architecture:

```bash
flutter build apk --release --split-per-abi
```

This creates 3 APKs in `build/app/outputs/flutter-apk/`:
- `app-armeabi-v7a-release.apk` (~18 MB) - Older 32-bit ARM devices
- `app-arm64-v8a-release.apk` (~20 MB) - Modern 64-bit ARM devices (most common)
- `app-x86_64-release.apk` (~22 MB) - Intel-based devices (rare)

**Most devices use arm64-v8a.**

### Profile Build (Performance Testing)

For testing with performance profiling enabled:

```bash
flutter build apk --profile
```

---

## What Works on Real Device

On a real Android device, these features will work that don't on emulator:

✅ **Database Persistence (sqflite)**
- Vehicle data saved between app restarts
- Historical data storage
- Alert history

✅ **Settings Persistence (shared_preferences)**
- MQTT configuration saved
- Update frequency saved
- Alert thresholds saved
- Settings persist across app restarts

✅ **Better Performance**
- Faster startup
- Smoother animations
- More reliable plugin registration

✅ **Android Auto (if device supports it)**
- Real Android Auto projection to car
- Better DHU testing (connect phone to car or head unit)

---

## Testing on Real Device

### First Launch Checklist

1. **Grant Permissions:**
   - Internet (for MQTT) - auto-granted
   - Notifications - may prompt on first alert
   - Foreground service - may prompt

2. **Verify Mock Data:**
   - App should show vehicle data updating every 2 seconds
   - Battery level, speed, temperature should change

3. **Test Settings Persistence:**
   - Go to Settings
   - Change update frequency to 5 seconds
   - Tap Save
   - Close app completely
   - Reopen app
   - Go to Settings
   - **Verify:** Update frequency is still 5 seconds ✅

4. **Test MQTT Publishing:**
   ```bash
   # On your computer
   mosquitto_sub -h mqtt.eclipseprojects.io -t "vehicles/TEST_VEHICLE_001/data" -v
   ```
   - You should see data from your phone publishing

5. **Test Android Auto (if available):**
   - Connect phone to car or Android Auto head unit
   - Look for "CarSOC - Battery Monitor" in apps
   - Open and verify dashboard displays

---

## Troubleshooting

### Build Fails

**Error: "Gradle build failed"**
```bash
# Clean and rebuild
flutter clean
flutter pub get
flutter build apk --release
```

**Error: "SDK license not accepted"**
```bash
flutter doctor --android-licenses
# Accept all licenses
```

### Installation Fails

**Error: "App not installed"**
- Check you have enough storage space
- Uninstall old version first:
  ```bash
  adb uninstall com.example.carsoc
  ```
- Then reinstall

**Error: "Installation blocked"**
- Settings → Security → Enable "Install from unknown sources"
- Or use USB installation with ADB

### App Crashes on Launch

**Check logs:**
```bash
adb logcat | grep "CarSOC\|AndroidRuntime"
```

Common issues:
- Missing permissions in AndroidManifest (already configured)
- Plugin initialization errors (should be handled with try-catch)

---

## APK Signing (Optional)

The debug APK is signed with a debug key automatically. For production distribution, you'd need to create a keystore and sign the APK, but for personal testing, the release APK is sufficient.

To create a signed release APK (for Google Play Store):

1. Create keystore:
   ```bash
   keytool -genkey -v -keystore ~/CarSOC-release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias carsoc
   ```

2. Create `android/key.properties`:
   ```properties
   storePassword=<your-password>
   keyPassword=<your-password>
   keyAlias=carsoc
   storeFile=/Users/stevelea/CarSOC-release-key.jks
   ```

3. Update `android/app/build.gradle.kts` to reference key.properties

4. Build signed APK:
   ```bash
   flutter build apk --release
   ```

**Note:** This is only needed for publishing to Play Store, not for personal testing.

---

## File Locations

After building, APKs are located in:
```
build/app/outputs/flutter-apk/
├── app-debug.apk           (debug build)
├── app-release.apk         (release build - fat APK)
├── app-armeabi-v7a-release.apk  (if split-per-abi)
├── app-arm64-v8a-release.apk    (if split-per-abi)
└── app-x86_64-release.apk       (if split-per-abi)
```

---

## Next Steps After Installation

1. **Verify all features work:**
   - Mock data updates
   - Settings persistence ✅ (will now work!)
   - MQTT publishing
   - Database storage ✅ (will now work!)

2. **Test in car (if available):**
   - Connect phone to Android Auto
   - Launch CarSOC on car display
   - Verify dashboard shows vehicle data

3. **Performance testing:**
   - Monitor battery usage
   - Check memory usage
   - Verify no crashes over time

4. **Prepare for CarInfo API testing (future):**
   - If you get access to an Android Automotive OS device
   - CarInfo API will provide real vehicle data
   - Mock data will automatically be replaced

---

## Build Time

Expected build times:
- Debug APK: ~2-3 minutes
- Release APK: ~5-10 minutes (includes optimization)
- Clean build: Add 1-2 minutes

---

## Summary

**Quick command to build and install:**
```bash
# Build release APK
flutter build apk --release

# Install on connected device
adb install -r build/app/outputs/flutter-apk/app-release.apk

# Or for arm64 devices only (smaller size):
flutter build apk --release --split-per-abi
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

**APK Location:**
`build/app/outputs/flutter-apk/app-release.apk`

**Ready to test!** 🚀
