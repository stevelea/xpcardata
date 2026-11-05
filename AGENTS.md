# XPCarData (CarSOC) — project map

Android Flutter app that reads an EV over OBD-II (ELM327 / WiCAN) and publishes
to MQTT / Home Assistant, ABRP, Firebase fleet stats — plus a built-in web UI for
remote viewing. Currently **v1.4.26**.

## Layout

```
carsoc/                    <- Flutter app (this repo root)
  lib/main.dart            entry point; inits services then runApp
  lib/models/              VehicleData, PID configs, profiles, WiCAN parser
  lib/providers/           Riverpod providers; owns DataSourceManager
  lib/screens/             UI (home dashboard, live data, charging history, settings/*)
  lib/services/            OBD, MQTT, ABRP, charging sessions, web server, updater
  assets/web/              embedded web UI served by WebServerService
  test/                    64 unit + integration tests (flutter_test)
  android/                 Kotlin shell (MainActivity channels), Gradle config
  docs/                    release notes, user guide, PID refs, API docs
```

Key services: `data_source_manager.dart` (routing), `obd_service.dart` (ELM327 +
PID polling), `mqtt_service.dart` (HA discovery + JSON payload), `web_server_service.dart`
(remote view: `/api/state`, `/api/sessions`, `/api/logs`, `/api/settings`,
`/api/fleet`, `/api/manual`), `charging_session_service.dart`,
`github_update_service.dart` (version constants).

## Commands (this machine's working recipe)

The app builds from a bundled Flutter SDK and pinned HOME/PUB_CACHE dirs:

```bash
cd /Volumes/UgreenEXT/CarSOC/carsoc
export HOME=$PWD/.home PUB_CACHE=$PWD/.pub_cache GRADLE_USER_HOME=$PWD/.gradle_home
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"  # see gotcha 1
export ANDROID_HOME=$HOME/Library/Android/sdk ANDROID_SDK_ROOT=$ANDROID_HOME

# build needs two extra env vars on this machine (see gotchas 2 and 10)
printf '#!/bin/sh\nexit 1\n' > /tmp/shims/mdfind; chmod +x /tmp/shims/mdfind
PATH=/tmp/shims:$PATH GRADLE_OPTS="-Duser.home=$PWD/.home" \
  ./.flutter_sdk/bin/flutter build apk --debug

./.flutter_sdk/bin/flutter analyze          # baseline ~146 issues, 0 errors
./.flutter_sdk/bin/flutter test             # 64 tests, all pass
```

## Gotchas

1. **JAVA_HOME**: use `/Applications/Android Studio.app/Contents/jbr/Contents/Home`
   (verify with `ls .../bin/java`). Wrong paths fail late during Gradle.
2. **`mdfind` hangs** on this machine, and `flutter build` calls it for Android
   Studio detection (`flutter_tools/lib/src/android/android_studio.dart`). The
   build stalls *before* Gradle with no output. Workaround: shim it on PATH:
   `printf '#!/bin/sh\nexit 1\n' > /tmp/shims/mdfind && chmod +x /tmp/shims/mdfind`,
   then `PATH=/tmp/shims:$PATH flutter build apk`. `analyze`/`test` are unaffected.
3. **Only one Flutter build at a time** — a second invocation waits on
   `.flutter_sdk/bin/cache/lockfile`, and a killed build can leave the lock holder
   behind. Check `pgrep -fl flutter_tools.snapshot` and kill strays before retrying.
4. **Version bumps** touch three files: `pubspec.yaml` (`version:`),
   `lib/services/github_update_service.dart` (`appVersion`), and
   `docs/RELEASE_NOTES.md` + `README.md` history.
5. **Signing**: since v1.4.23 the APK is signed with a permanent keystore
   (`android/key.properties`, gitignored). Devices on ≤ v1.4.22 need one uninstall
   before updating (`signing_key` differs); the app explains this in the updater.
6. **AI boxes** (Carlinkit/Ottocast) break sqflite, SharedPreferences,
   path_provider and external storage — persistence has fallbacks (Hive → prefs →
   in-memory). Never assume a settings write succeeded; wrap and log.
7. **Git remote is SSH** (`git@github.com:stevelea/xpcardata.git`) and pushes
   work with the local key. `gh` API calls (releases/issues) fail because its
   token is invalid and cannot reach the keychain from the sandbox — use git for
   publishing and hand `gh` steps to the user. Always `git fetch` +
   `git pull --rebase origin main` before pushing (others push to `main`), never
   force-push, never move an existing tag.
8. **PID parsing has two layouts**: built-in profiles index `B4`-style after the
   CAN ID/ISO-TP strip (`OBDPIDConfig.parseWithFormula`); WiCAN community profiles
   index against WiCAN's own buffer (`WiCanResponseParser`, keep framing/sequence
   bytes, `useWiCanLayout: true`). Do not merge the two.
9. **Charging detection**: HV current < -0.5 A while stationary (two samples).
   `BMS_CHG_STATUS` / `CHARGING` latch after unplug — never use them as the
   primary signal.
10. **Debug keystore**: Gradle creates `~/.android/debug.keystore` using Java's
    `user.home`, which ignores `$HOME` — the sandbox then refuses the write
    (`Unable to create debug keystore in /Users/<you>/.android`). Pass
    `GRADLE_OPTS="-Duser.home=$PWD/.home"` so the keystore lands inside the
    workspace. Release builds use `android/key.properties` instead.
11. **Implausible-PID gates** (`lib/services/sensor_sanity.dart`): a parked G6
    answers `221101` with 9.7 V (contactors open) and `22031F`/`220320` with
    400 A / 18 V sentinels. Those must never reach MQTT/UI — the gates reject
    them and power is only computed from plausible values. Do not loosen them
    without a car capture proving the value is real.


## Docs worth reading before changing behavior

- `docs/XPENG_G6_PIDs.md` — PID table, formulas, stale-PID warnings
- `docs/WEB_API.md` — remote view HTTP API contract
- `docs/XPENG_MODEL_PROFILES.md` — which models are verified vs derived
- `docs/PLAY_STORE.md` — what a Play submission still needs
- `docs/CHARGE_PORT_STATE.md` — why IEC 61851 State B is not inferred yet
- `CLAUDE.md` — product/architecture notes (kept in sync with this file)
