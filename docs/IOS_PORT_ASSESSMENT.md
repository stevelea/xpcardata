# iOS Build Assessment for XPCarData

*Last Updated: 2026-01-13*

## Summary

Building an iOS version is **technically feasible but requires significant native development work**. The main blocker is Bluetooth - iOS uses Core Bluetooth framework which is completely different from Android's Bluetooth APIs.

**iOS Readiness: ~35% Complete**

---

## What Already Works on iOS

These components are platform-agnostic Dart code with iOS-compatible plugins:

| Component | Status |
|-----------|--------|
| MQTT/Home Assistant integration | ✓ Ready |
| ABRP telemetry | ✓ Ready |
| Fleet analytics (Firebase) | ✓ Ready |
| SQLite database (sqflite_darwin) | ✓ Ready |
| Hive storage | ✓ Ready |
| Shared preferences | ✓ Ready |
| Location (geolocator_apple) | ✓ Ready |
| Background service foundation | ✓ Ready |
| Core Flutter UI | ✓ Ready |

---

## Critical Blockers

### 1. Bluetooth Communication (MAJOR)

**Problem:** The app uses custom Android Bluetooth APIs via method channels (525 lines Kotlin + 180 lines BluetoothHelper). iOS requires completely different Core Bluetooth framework.

**Required Work:**
- Write new Swift implementation (~600-800 lines)
- Core Bluetooth peripheral discovery
- SPP/RFCOMM equivalent (BLE Serial)
- Connection management and reconnection
- Proper iOS background Bluetooth modes

**Effort:** 15-20 hours

### 2. Android-Only Plugins

| Plugin | Usage | iOS Alternative |
|--------|-------|-----------------|
| `flutter_automotive` | Android Automotive OS CarInfo API | **None** - disable on iOS |
| `android_intent_plus` | Tailscale VPN control via intents | **Limited** - URL schemes only |

### 3. Platform Channels Needing iOS Implementation

| Channel | Function | iOS Status |
|---------|----------|------------|
| `com.example.carsoc/bluetooth` | OBD communication | Needs Swift implementation |
| `com.example.carsoc/update` | APK installation | No equivalent (use TestFlight) |
| `com.example.carsoc/vpn_status` | VPN detection | Partial support possible |
| `com.example.carsoc/package_manager` | Package detection | Limited iOS equivalent |

---

## Features That Won't Work on iOS

| Feature | Reason |
|---------|--------|
| Android Auto UI | iOS uses CarPlay (separate implementation) |
| Direct APK updates | iOS requires App Store/TestFlight |
| Tailscale intent control | iOS doesn't have broadcast intents |
| Boot startup | iOS doesn't support auto-start on boot |
| AAOS CarInfo API | Android Automotive only |

---

## Recommended Approach

### Option A: Minimal iOS Port (Recommended)
**Goal:** OBD monitoring on iPhone with cloud integrations
**Effort:** 80-100 hours

**Phase 1: Foundation (30-40 hours)**
1. Create iOS Bluetooth wrapper in Swift using Core Bluetooth
2. Add method channel bridge to existing `native_bluetooth_service.dart`
3. Configure Info.plist with Bluetooth/Location permissions
4. Disable `CarInfoService` and `TailscaleService` on iOS

**Phase 2: Testing & Polish (30-40 hours)**
1. Test with ELM327 adapters on iOS devices
2. Adapt background service for iOS restrictions
3. Handle iOS-specific edge cases
4. UI refinements for iOS design patterns

**Phase 3: Distribution (10-20 hours)**
1. TestFlight setup for beta testing
2. App Store submission (if desired)
3. Remove in-app update feature (not allowed on iOS)

### Option B: Full Feature Parity with CarPlay
**Goal:** Complete iOS experience including car display
**Effort:** 150-200+ hours (adds CarPlay implementation)

---

## iOS Configuration Required

### Info.plist Additions
```xml
<!-- Bluetooth -->
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Connect to OBD-II adapter for vehicle data</string>
<key>NSBluetoothCentralUsageDescription</key>
<string>Connect to OBD-II adapter for vehicle data</string>

<!-- Location -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>Track charging locations</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Track charging locations in background</string>

<!-- Background Modes -->
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
  <string>fetch</string>
</array>
```

### Xcode Capabilities
- Background Modes (Bluetooth Central, Background Fetch)
- App Groups (if sharing data)

---

## Key Technical Challenges

### 1. ELM327 Bluetooth Compatibility
- Most ELM327 adapters use Bluetooth Classic (SPP profile)
- iOS only supports Bluetooth Low Energy (BLE) natively
- **Solution:** Use BLE-capable ELM327 adapters (OBDLink MX+, Vgate iCar Pro BLE, etc.)
- May need to support both protocols

### 2. iOS Background Restrictions
- iOS aggressively suspends background apps
- Bluetooth connections can be maintained with proper background modes
- May need to handle reconnection on app resume

### 3. App Store Approval
- Must use TestFlight/App Store (no sideloading)
- Review process may flag Bluetooth usage
- Need proper privacy policy

---

## Files to Create for iOS

| File | Description |
|------|-------------|
| `ios/Runner/BluetoothManager.swift` | Core Bluetooth wrapper |
| `ios/Runner/BluetoothMethodChannel.swift` | Flutter method channel bridge |
| Update `ios/Runner/AppDelegate.swift` | Register method channels |
| Update `ios/Runner/Info.plist` | Add permissions |

---

## Verification Plan

1. **Bluetooth Connection Test**
   - Connect to BLE ELM327 adapter
   - Send AT commands and receive responses
   - Verify PID queries work

2. **Background Mode Test**
   - App maintains connection when backgrounded
   - Reconnects properly on resume

3. **Integration Test**
   - Full data flow: OBD → App → MQTT/ABRP
   - Charging detection works
   - All cloud integrations functional

---

## Recommendation

**Start with Option A (Minimal iOS Port)** - this gets the core OBD monitoring functionality working on iOS with reasonable effort. CarPlay support can be added later as a separate project.

The biggest unknown is Bluetooth - I recommend prototyping the Core Bluetooth implementation first to validate that your ELM327 adapters work with iOS before committing to the full port.
