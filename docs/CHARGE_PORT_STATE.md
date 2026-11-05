# Charge-Port State (IEC 61851) — What the OBD Data Supports

*Companion note for GitHub issue #3 ("expose State B / vehicle detected")*

## What the app publishes today

`charging_status` (and the matching `charging_status_description` /
`isCharging` binary sensor) is computed in `lib/models/vehicle_data.dart` from
the HV battery current — not from any charge-status PID:

| State | Condition |
|-------|-----------|
| `C` — charging | `speed < 1 km/h` **and** `HV_A < -0.5 A` (or `power < -0.5 kW`) |
| `A` — standby | everything else |

State `B` ("vehicle detected": cable connected, vehicle not drawing power) is
**not** inferred, because the OBD data available today cannot distinguish it
from "cable unplugged". This is deliberate: a guess would be wrong for every
user whose car is parked after a charge.

## Why State B is not inferable

The two PIDs that could plausibly carry a connector state are:

| PID | Key | Documented values (`docs/XPENG_G6_PIDs.md`) |
|-----|-----|---------------------------------------------|
| `22112D` | `BMS_CHG_STATUS` | 0 = not charging, 2 = DC charging, 3 = AC charging, 4 = DC high power |
| `22031D` | `CHARGING_HVIL` (v4) / `CHARGING` (v3, mock) | 0 = not charging, 1 = charging (WiCAN calls it `CHARGER_CONNECTED`) |

Three problems block a State B heuristic:

1. **No documented "connected but idle" value.** Neither PID is documented with
   a state that means "cable present, no charging". `BMS_CHG_STATUS` only
   reports *charging* flavours (`2/3/4`), never "plugged".
2. **The PIDs latch.** Both are known to keep their last value after the cable
   is unplugged — see the comments in `charging_session_service.dart` and the
   "Known Stale PIDs" section of the repo `CLAUDE.md`. A non-zero raw value
   while not charging is therefore ambiguous between State B and a stale
   reading from hours ago.
3. **Freshness does not help.** Both PIDs are high priority and re-read every
   poll cycle (~5 s), so any value in a payload *was* read this cycle. The ECU
   is what is stale, not the app's cache. There is no per-PID timestamp in the
   payload (`timestamp`/`lowPriorityLastUpdated` cover the whole sample, not
   each PID), and even a valid per-PID timestamp could not tell a live-but-idle
   cable from a latched value.

Two more dead ends, for completeness:

- `22031E` was labelled `DC_CHG_STATUS` in v3 but is actually the VCU-side SoC
  (`[B4:B5]/10`, see the v4 note in `lib/models/local_vehicle_profiles.dart`).
  It is already exposed as the `vcu_soc` sensor.
- `DC_CHG_V` / `DC_CHG_A` are also stale after a DC session and say nothing
  about an AC cable.

## Raw values now exposed for evidence

These read the same `vehicles/<id>/data` payload as every other sensor
(attributes: `priority`, `last_collected`, `data_source`):

| HA object_id | Payload key | Source PID | Notes |
|--------------|-------------|------------|-------|
| `bms_chg_status` | `BMS_CHG_STATUS` | `22112D` | raw 0/2/3/4 as reported by the BMS |
| `charging_flag` | `CHARGING_HVIL` (falls back to `CHARGING`) | `22031D` | raw 0/1 flag; v4/WiCAN disagree on whether it means connected or charging |
| `charging_status` | `chargingStatus` | derived | `A` / `C` only (see above) |
| `dc_chg_voltage`, `dc_chg_current` | `DC_CHG_V`, `DC_CHG_A` | `220320`, `22031F` | already existed |
| `current`, `power`, `speed` | `batteryCurrent`, `power`, `speed` | `221103`, computed, `220104` | the actual charging evidence |

## How to capture the evidence that would prove State B

Snapshots must be taken in **each** of these states, waiting at least 30 s
(several poll cycles) after each physical change:

1. Cable **unplugged**, car awake (ignition on accessory) — the reference `A`.
2. Cable **plugged in, not charging** (charge limit already reached, scheduled
   departure, or charging paused in the car/app) — the candidate `B`.
3. **Actively AC charging** for a couple of minutes — `C`.
4. **Charging stopped from the app/charger with the cable still plugged**.
5. Cable **unplugged again**, still awake.

Record, for each step: `timestamp`, `chargingStatus`, `isCharging`,
`batteryCurrent`, `power`, `speed`, `BMS_CHG_STATUS`, `CHARGING_HVIL`,
`DC_CHG_V`, `DC_CHG_A`. From a machine on the broker:

```bash
mosquitto_sub -h <broker> -t 'vehicles/<vehicleId>/data' -v
```

or use **Settings → Debug Log** in the app, which logs the raw PID values.

### Test for a usable State B signal

A raw value can drive State B only if **all** of these hold:

- it is `0` (or another fixed value) in step 1 (unplugged);
- it has a **different, stable** value in step 2 (plugged, idle);
- it returns to the step-1 value within one poll cycle of unplugging in step 5
  (i.e. it does **not** latch like `BMS_CHG_STATUS` does today);
- the value in step 2 is distinct from the step-3/4 charging value.

If a PID passes that test, `charge_port_state` can be added as
`B` when stationary + not charging + that raw value, `C` when charging, else
`A`, gated on the sample being recent. Until then the app keeps publishing
`A`/`C` and the raw values, and no heuristic is shipped.

## Note for OCPP integrations

State B is the *EVSE's* control-pilot view of the connector. If the OCPP side
talks to the wallbox/charger, read the CP state from the charger itself — the
car's BMS only knows what it is doing, not whether a cable is attached and idle.
