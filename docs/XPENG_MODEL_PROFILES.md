# XPENG model profiles (G6 / G9 / P7 / P5 / X9 / G3i)

`lib/models/local_vehicle_profiles.dart` ships one verified profile and four
derived ones. This page records where each definition comes from and what is
still unverified, so a user who sees a wrong number knows which claim to doubt.

## Where the PIDs come from

| Source | What it contributes |
|--------|---------------------|
| The XPENG G6 v4 profile in this repo | The verified reference: every PID, header, byte offset and unit. Corrected against community WiCAN definitions and the reverse-engineered Car Scanner profile (see below) — odometer moved to the BMS with a 3-byte formula, `22031A` is rear motor torque (not HV power), `22031E` is VCU-side SoC (not DC charge status), `220317` applies the G6 motor-speed offset. |
| Car Scanner `2.1.50`, profile 838 — "P5 / P7 / G6 / G9 / X9", `Brands = ["XPeng"]`, description `[G6 support is experimental]` | 292 UDS `0x22` definitions on two ECUs (`7E0` VCU, 704 BMS), reverse-engineered in `/Volumes/projects/carscanner`. Confirms the G6 v4 corrections (e.g. `22031E` = Battery SoC `/10`, `220319/22031A` = front/rear torque request `raw/4 − 500`, `220322-220326` = fast/slow charging temperatures `raw − 40`) **and** supplies the only per-platform difference Car Scanner makes: motor speed offset. |

Car Scanner uses **one** profile for all five models, so there is no separate
per-model PID list to import. XPCarData therefore exposes the four extra models
as *derived* profiles:

| Profile | Motor-speed offset (`220317`/`220318`) | Basis |
|---------|----------------------------------------|-------|
| XPENG G6 | `[B4:B5]-16000` | Verified (G6 v4 profile). |
| XPENG G9 | `[B4:B5]-16000` | 800 V platform, shares the G6 offset in Car Scanner. |
| XPENG X9 | `[B4:B5]-16000` | 800 V platform; Car Scanner does not distinguish X9 from G6/G9. |
| XPENG P7 | `[B4:B5]-5000` | 400 V platform; Car Scanner uses `-5000` for P5/P7. |
| XPENG P5 | `[B4:B5]-5000` | 400 V platform; Car Scanner uses `-5000` for P5/P7. |
| XPENG G3i (2021+, LFP) | — | Separate, user-verified profile contributed upstream (PR #16). |

Every other PID is identical to the G6 v4 set: same requests, same headers
(BMS `704`→`784`, VCU `7E0`→`7E8`), same byte formulas.

**These four derived profiles are experimental.** They are honest for the shared
UDS request set, but nobody has confirmed on a real G9/P7/P5/X9 that every PID
returns the same layout as on the G6. Treat the first drive as a verification
run, not as production data.

## What to check first on a non-G6 car

Open **Settings → Debug Log** (or MQTT `rawBytes`) and check, in this order:

1. **SOC / HV voltage / HV current** (`221109`, `221101`, `221103`) — sane
   percentages and ~350–420 V on 400 V cars, ~600–700 V on 800 V cars.
2. **Motor speed** (`220317`/`220318`) — 0 while parked. A large constant offset
   while stationary means the platform offset is wrong; try the other family's
   value in a local profile and report it.
3. **Odometer** (`220101`, BMS `[B4:B6]`) — matches the car's display.
4. **Cell voltages** (`221122`) — plausible 3.0–4.2 V per cell, and the count
   matches the pack.

If a PID mismatches, capture the `[OBD Traffic]` TX/RX lines for that PID and
open an issue with the car model, firmware version and the raw response.

## Battery capacity is a separate setting

Capacity is **not** part of the PID profile. Choose it in
**Settings → Vehicle → Vehicle model**:

- G6: `2024 LR/AWD`, `2024 SR`, `2025 LR/AWD`, `2025 SR`
- G9: `AWD Long Range (93 kWh)`, `RWD Long Range (93 kWh)`, `RWD Standard Range (75 kWh)`
- P7: `RWD Long Range (82.7 kWh)`
- G3i: `460 RWD Standard Range (55 kWh)`
- P5 / X9: no preset yet — pick **Other / Custom** and enter the usable kWh
  from the car's manual. Adding a preset requires a verified usable-capacity
  figure, not a gross pack size.

Capacity feeds charging-session energy math, range estimates and the MQTT
`batteryCapacity` field, so a wrong value shows up as wrong kWh added — not as
wrong PID readings.
