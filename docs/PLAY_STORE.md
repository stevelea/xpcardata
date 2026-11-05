# Publishing XPCarData on Google Play

Status: **not published**. Issue #15 asked for a Play Store release because some
users cannot install APKs from unknown sources. This document is the checklist of
what has to change before an upload will be accepted, and what already supports it.

Everything below is a decision for the maintainer — the repository keeps shipping
sideload/GitHub releases either way, and none of these steps are applied yet.

## 1. Blockers that must be fixed before the first upload

### 1.1 `applicationId` is `com.example.carsoc`

Google Play rejects application IDs starting with `com.example.`. Two options:

| Option | What it means | Cost |
|--------|---------------|------|
| **A. New ID for the Play edition** (recommended, e.g. `com.stevelea.xpcardata`) | Play build is a separate app from the sideload build. | Nobody migrates automatically; users start fresh. Sideload users are unaffected. |
| **B. Rename the existing app** | One identity for both channels. | Every existing installation stops receiving updates (Android sees a different package); equivalent to a forced reinstall for the whole user base. |

Either way the Android `namespace` and `applicationId` in
`android/app/build.gradle.kts` and the Kotlin package directory
(`android/app/src/main/kotlin/com/example/carsoc/`) must match the new ID.

### 1.2 Self-updating is not allowed on Play

The manifest declares `android.permission.REQUEST_INSTALL_PACKAGES`
(`android/app/src/main/AndroidManifest.xml`) because the GitHub build installs its
own APK updates. Google Play policy only grants that permission for apps whose
core purpose is installing packages, so the Play artifact must drop it and update
through the store instead.

Runtime side is already handled: build with

```bash
flutter build appbundle --release --dart-define=PLAY_BUILD=true
```

which sets `kPlayBuild` (`lib/services/github_update_service.dart`) and replaces
every "Download & Install" action with a "Play Store Update" explanation. The
update *check* still works, so the app can tell users a new version exists.

For the manifest side, when the Play build gets its own flavor, add
`android/app/src/play/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <uses-permission
        android:name="android.permission.REQUEST_INSTALL_PACKAGES"
        tools:node="remove" />
</manifest>
```

and build with `--flavor play`. Do not add a flavor without also adding it to
`build_local.sh` / CI, because Gradle requires `--flavor` once any flavor exists.

### 1.3 `targetSdk` is 34

Play raises the minimum target API level every year. At the time of writing,
builds must target API 35+; plan for `targetSdk = 36` together with
`compileSdk = 36` (already set). Check the current requirement before uploading.

### 1.4 Play App Signing

The upload bundle is signed with the release keystore (`android/key.properties`,
gitignored). Enrol in Play App Signing so Google holds the distribution key; the
local keystore becomes the *upload* key. Keep an off-repo backup of both — losing
the upload key means a support request to Google, not a lost app.

## 2. Store listing data

| Item | Notes |
|------|-------|
| Privacy policy URL | **Required.** The app collects location (optional), OBD/vehicle data, and anonymous fleet statistics via Firebase. `docs/USER_GUIDE.md` documents each toggle; the policy must match those defaults. |
| Data safety form | Declare: vehicle telemetry (not shared with third parties by default), approximate/precise location only when the location service is enabled, crash logs (Firebase Crashlytics), anonymous usage statistics (can be disabled in Settings → Integrations → Fleet Statistics). |
| Content rating | Utility/vehicle tool; no user-generated content, no ads. |
| Screenshots | Phone (dashboard, live data, charging history) and tablet if the large-screen layouts are supported (they are — the dashboard scales). |
| Listing text | Feature the peer integrations: MQTT/Home Assistant, ABRP, remote web view, XPENG G6/G9/P7/P5/X9/G3i profiles. |
| Feature graphic | 1024×500 PNG. |

## 3. Build and upload

```bash
cd carsoc
export HOME=$PWD/.home PUB_CACHE=$PWD/.pub_cache
./.flutter_sdk/bin/flutter build appbundle --release --dart-define=PLAY_BUILD=true
# -> build/app/outputs/bundle/release/app-release.aab
```

Verify before upload:

1. `bundletool build-apks --bundle=app-release.aab --output=x.apks` and install
   on a device: the Updates card must show "Play Store Update", not
   "Download & Install".
2. `flutter analyze` and `flutter test` are clean.
3. The release is uploaded to the **internal testing** track first, then closed
   testing, then production.

## 4. What stays on GitHub

Sideload/GitHub releases remain the primary channel: they have the in-app
updater, which Play does not allow. Keep publishing the same version there so the
two channels stay in step; the version constants (`appVersion` in
`lib/services/github_update_service.dart` and `version:` in `pubspec.yaml`) are
shared by both builds.
