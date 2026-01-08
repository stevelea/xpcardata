# Android Setup Guide

This app requires Android to run (uses Android Auto and CarInfo API).

## Quick Setup

### Option 1: Android Emulator (Recommended for Testing)

1. **Open Android Studio:**
   ```bash
   open -a "Android Studio"
   ```

2. **Create an Android Virtual Device (AVD):**
   - Tools → Device Manager (or AVD Manager)
   - Click "Create Device"
   - Select: **Pixel 5** or **Pixel 6** (recommended)
   - System Image: **API 33** (Android 13) or **API 34** (Android 14)
   - Click "Finish"

3. **Start the emulator:**
   - In Device Manager, click the ▶️ play button next to your device
   - Wait for emulator to fully boot (shows home screen)

4. **Verify Flutter sees it:**
   ```bash
   flutter devices
   ```

   You should see something like:
   ```
   sdk gphone64 arm64 (mobile) • emulator-5554 • android-arm64 • Android 13 (API 33)
   ```

5. **Run the app:**
   ```bash
   flutter run
   ```

   If multiple devices are available:
   ```bash
   flutter run -d emulator-5554
   ```

### Option 2: Physical Android Phone

1. **Enable Developer Mode on your phone:**
   - Go to Settings → About Phone
   - Tap "Build Number" 7 times
   - Go back to Settings → System → Developer Options
   - Enable "USB Debugging"

2. **Connect phone via USB**

3. **Verify connection:**
   ```bash
   flutter devices
   ```

4. **Run the app:**
   ```bash
   flutter run
   ```

## Current Issue

Your Mac doesn't have Android emulators running. The app tried to launch on macOS, but this is an Android-only app.

## What to Do Now

**Choose ONE of these options:**

### A. Create Android Emulator (5 minutes)

1. Open Android Studio
2. Tools → Device Manager
3. Create Virtual Device (Pixel 5, API 33)
4. Start emulator
5. Run: `flutter run`

### B. Connect Android Phone

1. Enable USB Debugging on phone
2. Connect USB cable
3. Run: `flutter run`

### C. List Available Devices First

```bash
# See what devices Flutter detects
flutter devices

# If you see an Android device, run:
flutter run -d <device-id>

# Example:
flutter run -d emulator-5554
```

## Expected Output When Running

Once you run on Android, you'll see:

```bash
flutter run
✓ Built build/app/outputs/flutter-apk/app-debug.apk
Installing build/app/outputs/flutter-apk/app-debug.apk...
Launching lib/main.dart on Android SDK built for arm64 in debug mode...
Running Gradle task 'assembleDebug'...
✓ Built build/app/outputs/flutter-apk/app-debug.apk
Installing build/app/outputs/flutter-apk/app-debug.apk...

Flutter run key commands.
r Hot reload.
R Hot restart.
h List all available interactive commands.
d Detach (terminate "flutter run" but leave application running).
c Clear the screen
q Quit (terminate the application on the device).
```

Then the app will launch on the Android device/emulator and you'll see the CarSOC home screen with mock vehicle data!

## Troubleshooting

**"No devices found"**
- Create an Android emulator (Option A above)
- Or connect a phone (Option B above)

**"adb not found"**
- Make sure Android SDK is installed via Android Studio
- Or run: `flutter doctor` to see what's missing

**Build errors**
```bash
cd /Users/stevelea/CarSOC/carsoc
flutter clean
flutter pub get
flutter run
```

## Why macOS Doesn't Work

This app uses:
- Android Auto (Android-only)
- Android CarInfo API (Android-only)
- Android Car App Library (Android-only)
- Native Kotlin code (Android-only)

It cannot run on macOS, iOS, Windows, or Web.

## Next Steps After Android Setup

Once running on Android:
1. ✅ You'll see the home screen with vehicle data
2. ✅ Mock data will update every 2 seconds
3. ✅ Data is being saved to SQLite
4. ✅ Data is being sent to Android Auto bridge

Then you can test Android Auto with the Desktop Head Unit (DHU) - see [TESTING.md](TESTING.md).
