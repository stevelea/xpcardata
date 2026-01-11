# CLAUDE.md - Project Context for Claude Code

This file provides context for Claude Code (AI assistant) when working on this codebase.

## Project Overview

**XPCarData** is a Flutter-based Android app for monitoring XPENG electric vehicle battery and charging data via OBD-II Bluetooth. The app integrates with ABRP, MQTT/Home Assistant, and provides anonymous fleet statistics.

## Key Architecture

### Data Flow
```
OBD-II Bluetooth / CarInfo API → DataSourceManager → Services (MQTT, ABRP, Fleet) → UI
```

### Core Services (lib/services/)

- **data_source_manager.dart**: Central hub that routes vehicle data to all consumers
- **obd_service.dart**: Bluetooth OBD-II communication with ELM327 adapters
- **carinfo_api_service.dart**: Android Automotive CarInfo API integration
- **charging_session_service.dart**: Detects and tracks charging sessions
- **open_charge_map_service.dart**: Looks up charger names from GPS coordinates
- **mqtt_service.dart**: Publishes data to MQTT brokers with Home Assistant discovery
- **abrp_service.dart**: Sends telemetry to A Better Route Planner
- **fleet_analytics_service.dart**: Anonymous fleet statistics via Firebase

### Key Files

- **lib/main.dart**: App entry point, initializes services
- **lib/screens/dashboard_screen.dart**: Main UI showing vehicle metrics
- **lib/screens/settings_screen.dart**: Configuration and About section
- **lib/services/github_update_service.dart**: In-app update checking (contains version constants)
- **lib/build_info.dart**: Auto-generated build timestamp

## Build Information

- **Current Version**: 1.2.0 (Build 87)
- **Flutter Version**: 3.x
- **Min Android SDK**: 29 (Android 10)
- **Target**: Android phones, tablets, and AI boxes (Carlinkit, etc.)

### Build Commands

```bash
# Build release APK
cd carsoc && flutter build apk --release

# Build with specific naming
flutter build apk --release && mv build/app/outputs/apk/release/app-release.apk XPCarData-V1.2.0-build87.apk
```

### Pre-build Script

The `pre_build.sh` script updates `lib/build_info.dart` with current timestamp before each build.

## Version Updates Checklist

When updating version/build numbers:

1. **lib/services/github_update_service.dart** - Update `appVersion` and `appBuildNumber` constants
2. **lib/screens/settings_screen.dart** - Update features list in About section
3. **lib/build_info.dart** - Auto-updated by pre_build.sh
4. **README.md** - Update version badge and version history
5. **docs/RELEASE_NOTES.md** - Add new version entry
6. **docs/USER_GUIDE.md** - Update any changed features

## Charging Detection Logic

The app uses HV battery current as the PRIMARY charging indicator:

1. **Negative HV current** = charging (XPENG convention)
2. **Stationary check** (speed < 1 km/h for 2 samples) filters out regen braking
3. **AC vs DC**: Power > 11kW = DC, otherwise AC
4. **BMS_CHG_STATUS is unreliable** - doesn't reset after charging stops

## OpenChargeMap Integration

- API Key stored in `open_charge_map_service.dart`
- Searches within 100m radius for nearest charger
- 7-day cache to reduce API calls
- Home location check before API lookup

## Android AI Box Compatibility

AI boxes have restricted storage access. The app uses multi-tier storage:
1. In-memory (always works)
2. SQLite database
3. SharedPreferences
4. File storage
5. MQTT persistence to Home Assistant

## Common Issues

- **OBD connection lost**: Auto-reconnect with exponential backoff
- **Stale PIDs**: BMS_CHG_STATUS, DC_CHG_A/V don't reset - use HV current instead
- **Rate limiting**: GitHub API limits 60/hour without token

## GitHub Repository

- **URL**: https://github.com/stevelea/xpcardata
- **Push only docs and APK zip** - Source code not published
- **Use HTTPS** for pushing (not SSH)

## Testing

- **Mock data mode**: Enable in Settings > Developer to test without vehicle
- **Debug log**: Settings > Debug Log shows all service activity
