# WiCAN Setup for XPENG G6

This guide explains how to configure a WiCAN OBD-II adapter for use with the XPENG G6.

## What is WiCAN?

WiCAN is an open-source OBD-II to WiFi/BLE adapter that can read vehicle data and publish it via MQTT. It's particularly useful for:
- Home Assistant integration
- Real-time vehicle monitoring
- Custom dashboards

## Vehicle Profiles

The XPENG G6 uses **two ECUs** with different CAN headers, so there are two profile files:

| File | ECU | Header | PIDs |
|------|-----|--------|------|
| `wican_xpeng_g6_profile.json` | BMS (Battery Management) | 704 | 2211xx |
| `wican_xpeng_g6_vcu.json` | VCU (Vehicle Control) | 7E0 | 2201xx, 2203xx |

**Note:** WiCAN can only use one header at a time, so you may need to choose which ECU to monitor or switch between profiles.

## Profile Format

WiCAN profiles use this JSON structure:

```json
{
  "car_model": "XPENG: G6",
  "init": "ATSP6;ATSH704;ATCRA784;ATFCSH704;ATFCSM1;",
  "pids": [
    {
      "pid": "221109",
      "parameters": {
        "SOC": "[B4:B5]/10"
      }
    }
  ]
}
```

### Fields

- **car_model**: Vehicle identifier (format: "Manufacturer: Model")
- **init**: Semicolon-separated AT commands for ELM327 initialization
- **pids**: Array of PID objects
  - **pid**: The OBD-II PID code (hex string)
  - **parameters**: Key-value pairs mapping WiCAN parameter names to expressions

### Expression Syntax

- `B4` - Single byte at position 4
- `[B4:B5]` - Two-byte value (B4*256 + B5)
- Math operations: `+`, `-`, `*`, `/`
- Example: `"[B4:B5]/10"` divides the 16-bit value by 10

## BMS Profile (wican_xpeng_g6_profile.json)

Monitors battery management data:

| PID | Parameter | Formula | Description |
|-----|-----------|---------|-------------|
| 221109 | SOC | [B4:B5]/10 | State of Charge (%) |
| 22110A | SOH | [B4:B5]/10 | State of Health (%) |
| 221101 | HV_V | [B4:B5]/10 | Battery Voltage (V) |
| 221103 | HV_A | [B4:B5]*0.5-1600 | Battery Current (A) |
| 221107 | BATT_TEMP | B4-40 | Battery Temperature (°C) |
| 221105 | HV_C_V_MAX | [B4:B5]/1000 | Max Cell Voltage (V) |
| 221106 | HV_C_V_MIN | [B4:B5]/1000 | Min Cell Voltage (V) |
| 22112D | CHARGING | B4 | Charge Status (0/2/3) |

**Init command:** `ATSP6;ATSH704;ATCRA784;ATFCSH704;ATFCSM1;`

## VCU Profile (wican_xpeng_g6_vcu.json)

Monitors vehicle control data:

| PID | Parameter | Formula | Description |
|-----|-----------|---------|-------------|
| 220104 | SPEED | [B4:B5]/100 | Vehicle Speed (km/h) |
| 220101 | ODOMETER | [B5:B6] | Odometer (km) |
| 220102 | AUX_BATT_V | B4/10 | 12V Battery (V) |
| 220313 | RANGE | B4 | Estimated Range (km) |
| 22031A | HV_W | ([B4:B5]-20000)/10*1000 | Battery Power (W) |
| 22031D | CHARGER_CONNECTED | B4 | Charging Flag (0/1) |
| 220325 | INV_TEMP | B4/2-40 | Inverter Temp (°C) |
| 220327 | MOTOR_TEMP | B4/2-40 | Motor Temp (°C) |
| 220328 | COOLANT_TMP | B4/2-40 | Coolant Temp (°C) |

**Init command:** `ATSP6;ATSH7E0;ATCRA7E8;ATFCSH7E0;ATFCSM1;`

## Installation

1. **Access WiCAN Web Interface**
   - Connect to your WiCAN's WiFi AP or network
   - Navigate to the configuration page

2. **Import Profile**
   - Go to Automate settings
   - Import the JSON profile file
   - Or manually enter the car_model, init, and pids

3. **Configure MQTT**
   - Set your MQTT broker address
   - Enable Home Assistant discovery if desired

4. **Connect to Vehicle**
   - Plug WiCAN into the OBD-II port (under dashboard, driver side)
   - Power on the vehicle
   - WiCAN will start polling automatically

## Important Notes

### Current Sign Convention
- **Negative current (HV_A)** = Battery is **charging**
- **Positive current** = Battery is **discharging**

### Charge Status Values (22112D)
| Value | Meaning |
|-------|---------|
| 0 | Not charging |
| 2 | DC charging |
| 3 | AC charging |

### Protocol Settings
The XPENG G6 uses:
- Protocol: ISO 15765-4 CAN (ATSP6)
- Baud rate: 500 kbaud
- ID format: 11-bit

## Home Assistant Integration

With MQTT discovery enabled, entities will appear automatically using the parameter names (SOC, HV_V, SPEED, etc.).

## Troubleshooting

### No Data Received
1. Verify vehicle is powered on (at least accessory mode)
2. Check WiCAN is connected to network
3. Verify the init command matches the ECU you're querying

### Choosing BMS vs VCU
- **BMS profile**: Best for monitoring battery health, SOC, charging
- **VCU profile**: Best for monitoring speed, range, temperatures

You cannot query both ECUs simultaneously with a single profile due to different header requirements.

## Related Files

- `XPENG_G6_PIDs.md` - Complete PID reference documentation
- `wican_xpeng_g6_profile.json` - BMS ECU profile (Header 704)
- `wican_xpeng_g6_vcu.json` - VCU ECU profile (Header 7E0)

## Compatibility

Tested with:
- XPENG G6 2023-2024 models
- WiCAN firmware v2.x and v3.x
