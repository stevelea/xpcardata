# XPENG G6 OBD-II PID Reference

## Overview
This document contains all verified OBD-II PIDs for the XPENG G6 (2023+).

## ECU Addresses
The XPENG G6 uses two main ECUs accessible via OBD-II:

| ECU | Request Header | Response Address | PIDs |
|-----|----------------|------------------|------|
| BMS (Battery Management System) | 704 | 784 | 2211xx |
| VCU (Vehicle Control Unit) | 7E0 | 7E8 | 2201xx, 2203xx |

## Initialization Commands
Before querying PIDs, send these AT commands to configure the ELM327 adapter:

```
ATH1        - Show headers
ATSP6       - Set protocol to ISO 15765-4 CAN (11 bit ID, 500 kbaud)
ATS0        - Spaces off
ATM0        - Memory off
ATAT1       - Adaptive timing auto 1
ATFCSM1     - Set flow control mode 1
```

### Switching to BMS (for 2211xx PIDs)
```
ATSH704     - Set header to 704 (BMS)
ATCRA784    - Set CAN receive address to 784
ATFCSH704   - Set flow control header to 704
```

### Switching to VCU (for 2201xx, 2203xx PIDs)
```
ATSH7E0     - Set header to 7E0 (VCU)
ATCRA7E8    - Set CAN receive address to 7E8
ATFCSH7E0   - Set flow control header to 7E0
```

## PID Polling Priority

PIDs are categorized by polling priority to reduce OBD bus traffic:

- **High Priority**: Polled every cycle (5 seconds) - essential real-time data
- **Low Priority**: Polled every 60 cycles (~5 minutes) - slowly changing data

## PID Reference Table

### BMS PIDs (Header: 704)

| PID | Name | Description | Formula | Unit | Priority |
|-----|------|-------------|---------|------|----------|
| 221109 | SOC | State of Charge | [B4:B5]/10 | % | High |
| 22110A | SOH | State of Health | [B4:B5]/10 | % | Low |
| 221101 | HV_V | HV Battery Voltage | [B4:B5]/10 | V | High |
| 221103 | HV_A | HV Battery Current | (B4*256+B5)*0.5-1600 | A | High |
| 221105 | HV_C_V_MAX | Max Cell Voltage | [B4:B5]/1000 | V | Low |
| 221106 | HV_C_V_MIN | Min Cell Voltage | [B4:B5]/1000 | V | Low |
| 221107 | HV_T_MAX | Max Battery Temp | B4-40 | °C | High |
| 221108 | HV_T_MIN | Min Battery Temp | B4-40 | °C | Low |
| 221120 | Cumulative Charge | Battery Pack Cumulative Charging | A<<24+B<<16+C<<8+D | Ah | Low |
| 221121 | Cumulative Discharge | Battery Pack Cumulative Discharging | A<<24+B<<16+C<<8+D | Ah | Low |
| 221122 | CELL_V_AVG | Average Cell Voltage | multi-frame | V | Low |
| 221123 | CELL_T_AVG | Average Cell Temperature | multi-frame | °C | Low |
| 221116 | BMS_1116 | Unknown (~22894) | [B4:B5] | - | Low |
| 221117 | BMS_1117 | Unknown (732) | [B4:B5] | - | Low |
| 221118 | CLTC_RANGE | CLTC Range (China rated, ~15-20% > WLTP) | [B4:B5] | km | Low |
| 22111A | BMS_111A | Unknown (maybe 100.0%?) | [B4:B5]/10 | - | Low |
| 221124 | BMS_HV_V | BMS HV Battery Voltage | [B4:B5] | V | Low |
| 22112C | BMS_112C | Unknown (30) | [B4:B5] | - | Low |
| 22112D | BMS_CHG_STATUS | BMS Charge Status | B4 | 0/2/3 | High |
| 221130 | CHG_LIMIT | Charge Limit Setting | [B4:B5] | % | Low |

### VCU PIDs (Header: 7E0)

| PID | Name | Description | Formula | Unit | Priority |
|-----|------|-------------|---------|------|----------|
| 220104 | Speed | Vehicle Speed | [B4:B5]/100 | km/h | High |
| 220101 | ODOMETER | Odometer | [B5:B6] | km | Low |
| 220102 | AUX_V | 12V Auxiliary Battery Voltage | [B4:B5]/100 | V | Low |
| 220313 | RANGE_EST | Estimated Range | B4 | km | Low |
| 22031A | HV_PWR | HV Battery Power | ([B4:B5]-20000)/10 | kW | High |
| 220317 | MOTOR_RPM | Motor RPM | [B4:B5] | RPM | Low |
| 220319 | MOTOR_TORQUE | Motor Torque | ([B4:B5]-20000)/10 | Nm | Low |
| 22031D | CHARGING | Charging Status | B4 | 0/1 | High |
| 22031E | DC_CHG_STATUS | DC Charge Status | B4 | 0-4 | High |
| 22031F | DC_CHG_A | DC Fast Charge Current | [B4:B5]/10-1200 | A | High |
| 220320 | DC_CHG_V | DC Fast Charge Voltage | [B4:B5] | V | High |
| 220321 | AC_CHG_A | AC Charge Current | [B4:B5]*2 | A | High |
| 220322 | AC_CHG_V | AC Charge Voltage | B4*3 | V | High |
| 220325 | INV_T | Inverter Temperature | B4/2-40 | °C | Low |
| 220327 | MOTOR_T | Motor Coolant Temp | B4/2-40 | °C | Low |
| 220328 | COOLANT_T | Battery Coolant Temp | B4/2-40 | °C | Low |

## BMS Charge Status Values (22112D)

| Value | Meaning |
|-------|---------|
| 0 | Not charging |
| 2 | DC charging |
| 3 | AC charging |
| 4 | DC charging (high power) |

## DC Charge Status Values (22031E)

| Value | Meaning |
|-------|---------|
| 0 | Unplugged |
| 1 | Initializing |
| 2 | Charging |
| 3 | Complete |
| 4 | Stopped |

## Formula Notation

- `B4`, `B5`, `B6` etc. = Byte position in response (0-indexed from data start)
- `[B4:B5]` = 16-bit value from bytes B4 and B5 (B4*256 + B5)
- `A<<24+B<<16+C<<8+D` = 32-bit value from 4 bytes (for cumulative values)
- `multi-frame` = Requires multi-frame response parsing

## Detailed PID Descriptions

### Battery State (BMS - Header 704)
| PID | Notes |
|-----|-------|
| 221109 (SOC) | Display SOC percentage, divide raw by 10 |
| 22110A (SOH) | Battery health percentage, divide raw by 10 |
| 221101 (HV_V) | Pack voltage in decivolts, typically ~350-420V |
| 221103 (HV_A) | Pack current - NEGATIVE = charging, POSITIVE = discharging |

### Cell Monitoring (BMS - Header 704)
| PID | Notes |
|-----|-------|
| 221105 (HV_C_V_MAX) | Highest cell voltage in the pack |
| 221106 (HV_C_V_MIN) | Lowest cell voltage in the pack |
| 221107 (HV_T_MAX) | Hottest cell/module temperature |
| 221108 (HV_T_MIN) | Coldest cell/module temperature |
| 221122 (CELL_V_AVG) | Multi-frame response with all ~150 cell voltages |
| 221123 (CELL_T_AVG) | Multi-frame response with all temperature sensors |

### Charging Detection

The app uses multiple indicators to detect charging:

1. **HV_A (221103)**: Primary indicator - negative current means charging
   - Must be stationary (speed=0) for 2 consecutive samples to filter out regen braking
   - Current < -50A typically indicates DC charging
   - Current < -0.5A but > -50A typically indicates AC charging

2. **BMS_CHG_STATUS (22112D)**: Direct charge status from BMS
   - 2 = DC charging, 3 = AC charging

3. **CHARGING (22031D)**: VCU charging status flag

4. **DC_CHG_STATUS (22031E)**: DC charging connection status

### Charging (VCU - Header 7E0)
| PID | Notes |
|-----|-------|
| 22031D (CHARGING) | 0 = Not charging, 1 = Charging |
| 22031E (DC_CHG_STATUS) | DC charging gun connection status |
| 22031F (DC_CHG_A) | DC fast charging current (CCS/GB/T) |
| 220320 (DC_CHG_V) | DC fast charging voltage |
| 220321 (AC_CHG_A) | AC charging current (Type 2 / home charging) - Formula: [B4:B5]*2 |
| 220322 (AC_CHG_V) | AC charging voltage - Formula: B4*3 |

### Thermal Management (VCU - Header 7E0)
| PID | Notes |
|-----|-------|
| 220327 (MOTOR_T) | Motor/drivetrain coolant temperature |
| 220328 (COOLANT_T) | Battery pack coolant temperature |
| 220325 (INV_T) | Inverter temperature |

### Drivetrain (VCU - Header 7E0)
| PID | Notes |
|-----|-------|
| 220104 (Speed) | Vehicle speed in km/h (raw value / 100) |
| 220317 (MOTOR_RPM) | Electric motor rotational speed |
| 220319 (MOTOR_TORQUE) | Motor torque output |
| 22031A (HV_PWR) | Instantaneous battery power (positive = discharge, negative = regen/charge) |

### Trip/Lifetime Data
| PID | ECU | Notes |
|-----|-----|-------|
| 220101 (ODOMETER) | VCU | Total distance traveled |
| 221120 (Cumulative Charge) | BMS | Total Ah charged into battery (lifetime) |
| 221121 (Cumulative Discharge) | BMS | Total Ah discharged from battery (lifetime) |

### Other (VCU - Header 7E0)
| PID | Notes |
|-----|-------|
| 220102 (AUX_V) | 12V accessory battery voltage |
| 220313 (RANGE_EST) | Vehicle's estimated remaining range |

## Response Examples

### BMS Response (Header 784)
Query: `221109` (SOC) with ATSH704
Response: `784 06 62 11 09 02 C6 00`
- Header: `784` (BMS response)
- Length: `06` (6 bytes follow)
- Service: `62` (positive response to service 22)
- PID: `11 09`
- Data: `02 C6` = 710 decimal, /10 = 71.0%

### VCU Response (Header 7E8)
Query: `220104` (Speed) with ATSH7E0
Response: `7E8 05 62 01 04 2B C4`
- Header: `7E8` (VCU response)
- Length: `05` (5 bytes follow)
- Service: `62` (positive response to service 22)
- PID: `01 04`
- Data: `2B C4` = 11204 decimal, /100 = 112.04 km/h

### Multi-Frame Response
Query: `221122` (Cell Voltages) with ATSH704
Response: Multiple frames with flow control required
- First frame starts with `10 xx` (multi-frame indicator)
- Continuation frames start with `21`, `22`, `23`, etc.

## Notes

1. **ECU Switching**: The app automatically switches headers when querying PIDs from different ECUs. BMS PIDs (2211xx) use header 704, VCU PIDs (2201xx, 2203xx) use header 7E0.
2. **PID Ordering**: PIDs are ordered BMS first, then VCU to minimize header switches.
3. **Current Sign Convention**: NEGATIVE current = charging, POSITIVE = discharging (matches dashboard display)
4. **Power Sign Convention**: Positive power = discharging (driving), Negative = charging/regen
5. **Temperature Offset**: Most temps use -40°C offset (raw 0 = -40°C)
6. **Charging Detection**: Requires speed=0 for 2 consecutive samples to distinguish from regenerative braking
7. **Priority-Based Polling**: Low priority PIDs (SOH, cell data, odometer) are polled every ~5 minutes to reduce OBD traffic

## Compatibility
- Verified on: XPENG G6 2023-2024 models
- OBD adapter: ELM327 v1.5+ compatible
- Protocol: CAN 11-bit 500kbaud (ISO 15765-4)
