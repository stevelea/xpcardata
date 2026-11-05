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

- The server only runs while the app process is alive.
- Binding is IPv4 any-interface; there is no TLS. Tailscale provides the
  encrypted transport, or run it on a trusted LAN only.
- Polling more often than the OBD cycle (5 s) gains nothing — the payload is
  cached between frames.
