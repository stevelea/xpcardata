# Remote view HTTP API

The app embeds a small HTTP server (`lib/services/web_server_service.dart`) that
serves the web UI and a read-only JSON API. Enable it in **Settings → Remote
Access**; the screen lists every reachable address (LAN and Tailscale). Default
port is **8080**.

The API is read-only: there is no endpoint that changes settings, starts polling
or writes to the car. Everything is served from the data the app already has.

## Authentication

If an access token is set in Settings → Remote Access, every `/api/*` request
must carry it, either as a header or as a query parameter:

```bash
curl -H "x-token: $TOKEN" http://192.168.1.50:8080/api/state
curl "http://192.168.1.50:8080/api/state?token=$TOKEN"
```

The browser UI asks for the token once and stores it in `localStorage` under
`xpcd_token`; it never puts the token in a URL. Static files (`/`, `/app.css`,
`/app.js`, `/favicon.svg`) stay public so the page can load before the token is
entered. A missing or wrong token returns `401` with
`{"error":"unauthorized","authRequired":true}`.

With no token configured the API is open to anyone who can reach the port — fine
on a trusted home network, not fine on a shared hotspot. Do not port-forward the
server to the internet; use Tailscale.

## `GET /api/state`

Server info plus the latest vehicle frame. `data` is exactly the payload the app
publishes to MQTT (`VehicleData.toJson`), so every field Home Assistant sees is
here, including every custom PID value and the per-PID raw hex bytes.

```json
{
  "server": {
    "version": "1.4.25",
    "running": true,
    "port": 8080,
    "startedAt": "2026-11-05T12:00:00+11:00",
    "uptimeSeconds": 4212,
    "source": "obd",
    "authRequired": false,
    "serverTime": "2026-11-05T13:10:12+11:00"
  },
  "data": {
    "timestamp": "2026-11-05T13:10:10+11:00",
    "localTime": "2026-11-05 13:10:10",
    "stateOfCharge": 78.4,
    "stateOfHealth": 97.2,
    "batteryCapacity": 87.5,
    "batteryVoltage": 389.5,
    "batteryCurrent": -12.3,
    "batteryTemperature": 24.0,
    "range": 412.0,
    "speed": 0.0,
    "odometer": 12485.6,
    "power": -4.8,
    "chargingStatus": "C",
    "chargingStatusDescription": "AC Charging",
    "isCharging": true,
    "cellVoltages": [3.41, 3.42, "..."],
    "cellTemperatures": [24, 24, "..."],
    "rawBytes": {"SOC": "0A", "AUX_V": "066211030A0B"},
    "AUX_V": 12.6,
    "SOH": 97.2
  },
  "dataAgeSeconds": 3
}
```

Notes:

- `data` is `null` until the first frame arrives (app just started, no adapter).
- `dataAgeSeconds` is the real age of `data`; `null` when there is no data yet.
  Use it to distinguish "parked and idle" from "app lost the car".
- Every PID value is spread in at the top level of `data`; the keys are the PID
  profile names (`SOC`, `HV_A`, `AUX_V`, `CHARGING_HVIL`, …). Community profiles
  contribute their own names.
- `rawBytes` maps a PID name to its cleaned hex string (community/WiCAN profiles
  use WiCAN's byte layout, so profile `B` offsets apply directly).
- `cellVoltages` / `cellTemperatures` only appear when those PIDs were read.

## `GET /api/sessions?limit=20`

Recent charging sessions, newest first, including the active one
(`isActive: true`, `endTime: null`). `limit` is clamped to 1–200.

Field names match `ChargingSession.toJson`: `id`, `startTime`, `endTime`,
`energyAddedAh`, `energyAddedKwh`, `startSoc`, `endSoc`, `socGained`,
`durationSeconds`, `chargingType` (`ac`/`dc`/`unknown`), `maxPowerKw`,
`chargingCost`, `locationName`, `consumptionKwhPer100km`,
`distanceSinceLastCharge`, `latitude`, `longitude`, `chargingCurve`.

## `GET /api/logs?limit=200`

Debug log tail, oldest first. `limit` is clamped to 1–2000. This is the same
buffer shown in Settings → Debug Log.

## `GET /api/settings`

Read-only, redacted view of the app's settings — the same sections as
**Settings → Connections / App** on the phone, minus anything secret.

Values are read through the app's own ordering: **Hive first, then
SharedPreferences** (AI boxes cannot open the prefs channel at all). Older
builds read SharedPreferences only, which showed an empty broker while the app
showed the configured one.

```json
{
  "settingsAvailable": true,
  "vehicle": {"model": "G6_24LR", "customCapacityKwh": null},
  "behavior": {"updateFrequencySeconds": 2, "startMinimised": false,
               "stayInBackground": true, "keepAliveEnabled": true,
               "backgroundServiceEnabled": true, "autoUpdateCheck": true,
               "locationEnabled": true},
  "alerts": {"lowBatteryPercent": 20.0, "criticalBatteryPercent": 10.0,
             "highTemperatureCelsius": 45.0, "auxBatteryProtection": true,
             "auxBatteryThresholdVolts": 12.0},
  "mqtt": {"enabled": true, "broker": "homeassistant.local", "port": 8883,
           "username": "xpeng", "passwordSet": true, "tls": true,
           "vehicleId": "g6-steve", "homeAssistantDiscovery": true,
           "reconnectIntervalSeconds": 0},
  "tailscale": {"installed": true, "vpnActive": false,
                "autoConnect": true, "autoReconnect": true},
  "obdProxy": {"enabled": true, "port": 35000, "clientConnected": false},
  "bm300": {"enabled": false, "connected": false},
  "abrp": {"enabled": false, "tokenConfigured": true},
  "remoteAccess": {"enabled": true, "running": true, "port": 8080,
                   "tokenRequired": false},
  "app": {"version": "1.4.26"}
}
```

Notes:

- `port` defaults to 8883 (TLS) like the app does; `reconnectIntervalSeconds: 0`
  means auto-reconnect is disabled.
- `settingsAvailable: false` means neither Hive nor SharedPreferences answered —
  the values are defaults, and the web UI says so.
- There is deliberately **no** MQTT password, ABRP token, backup credential or
  web token value — only booleans such as `passwordSet`, `tokenConfigured` and
  `tokenRequired`.

## `GET /api/fleet`

Anonymous fleet aggregates (the app's Fleet Stats page). The response says
whether the user opted in:

```json
{"enabled": false, "stats": null}
```

```json
{
  "enabled": true,
  "stats": {
    "totalContributors": 120,
    "totalContributions": 8400,
    "avgSoh": 96.4,
    "avgChargingPowerAc": 7.2,
    "avgChargingPowerDc": 84.0,
    "sohDistribution": {"90-100": 80, "80-90": 30},
    "chargingTypeDistribution": {"ac": 5000, "dc": 3400},
    "countryDistribution": {"AU": 40, "DE": 35},
    "lastUpdated": "2026-11-05T12:00:00+11:00"
  }
}
```

`stats: null` with `enabled: true` means opted in but no aggregate available yet
(offline, or the Firestore query timed out after 8 s). No personal data is
involved: this is the same aggregate the app displays.

## `GET /api/manual`

The bundled manual (`docs/MANUAL.md`) as markdown text, so the browser can render
the same help the app shows:

```json
{"manual": "# XPCarData Manual\n\n## Overview\n..."}
```

## `GET /api/health`

Liveness probe, no vehicle data required:

```json
{"ok": true, "running": true, "port": 8080, "version": "1.4.25", "authRequired": false}
```

## Using it from Home Assistant or a script

`/api/state` is a normal REST sensor source. With a token:

```yaml
sensor:
  - platform: rest
    name: XPCarData web state
    resource: http://192.168.1.50:8080/api/state
    headers:
      x-token: !secret xpcardata_web_token
    value_template: "{{ value_json.data.stateOfCharge }}"
    json_attributes_path: "$.data"
    json_attributes:
      - batteryVoltage
      - power
      - chargingStatus
    scan_interval: 30
```

Or poll from a shell:

```bash
while true; do
  curl -s -H "x-token: $TOKEN" http://192.168.1.50:8080/api/state \
    | jq -r '.data | "SOC \(.stateOfCharge)%  \(.power) kW  \(.chargingStatusDescription)"'
  sleep 5
done
```

## Limits

- `/api/settings` and `/api/fleet` mirror the app's pages; they are read-only and
  the server has no endpoint that changes a setting.
- The server only runs while the app process is alive.
- Binding is IPv4 any-interface; there is no TLS. Tailscale provides the
  encrypted transport, or run it on a trusted LAN only.
- Polling more often than the OBD cycle (5 s) gains nothing — the payload is
  cached between frames.
