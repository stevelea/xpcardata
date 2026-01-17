# WiCAN Setup for XPENG G6

This guide explains how to configure a WiCAN OBD-II adapter for use with the XPENG G6.

## What is WiCAN?

WiCAN is an open-source OBD-II to WiFi/BLE adapter that can read vehicle data and publish it via MQTT. It's particularly useful for:
- Home Assistant integration
- Real-time vehicle monitoring
- Custom dashboards

## Vehicle Profile

The file `wican_xpeng_g6_profile.json` contains a complete WiCAN configuration for the XPENG G6.

## ECU Information

The XPENG G6 uses two main ECUs:

| ECU | Header | Response | PIDs |
|-----|--------|----------|------|
| BMS (Battery Management) | 704 | 784 | 2211xx |
| VCU (Vehicle Control) | 7E0 | 7E8 | 2201xx, 2203xx |

## Key PIDs

### High Priority (5 second interval)
| PID | Name | Unit | Description |
|-----|------|------|-------------|
| 221109 | SOC | % | State of Charge |
| 221101 | HV Voltage | V | Battery pack voltage |
| 221103 | HV Current | A | Battery current (neg=charging) |
| 221107 | Battery Temp Max | °C | Maximum battery temperature |
| 220104 | Speed | km/h | Vehicle speed |
| 22031A | HV Power | kW | Battery power |

### Medium Priority (30-60 second interval)
| PID | Name | Unit | Description |
|-----|------|------|-------------|
| 220102 | 12V Battery | V | Auxiliary battery voltage |
| 220313 | Range Estimate | km | Estimated range |
| 22112D | Charge Status | - | 0=No, 2=DC, 3=AC |

### Low Priority (5 minute interval)
| PID | Name | Unit | Description |
|-----|------|------|-------------|
| 22110A | SOH | % | State of Health |
| 220101 | Odometer | km | Total distance |
| 221120 | Cumulative Charge | Ah | Lifetime charging |

## Installation

1. **Upload Profile to WiCAN**
   - Connect to your WiCAN's web interface
   - Navigate to the PID configuration section
   - Import `wican_xpeng_g6_profile.json`

2. **Configure MQTT (Optional)**
   - Set your MQTT broker address
   - Configure Home Assistant discovery prefix (default: `homeassistant`)
   - Set device name and ID

3. **Connect to Vehicle**
   - Plug WiCAN into the OBD-II port (under dashboard, driver side)
   - Power on the vehicle
   - WiCAN will start polling PIDs automatically

## Important Notes

### Current Sign Convention
- **Negative current** = Battery is **charging**
- **Positive current** = Battery is **discharging**

### Charging Detection
To reliably detect charging (not regenerative braking):
- HV Current < -0.5A **AND**
- Vehicle Speed = 0

### Protocol Settings
The XPENG G6 uses:
- Protocol: ISO 15765-4 CAN
- Baud rate: 500 kbaud
- ID format: 11-bit

### Initialization Commands
```
ATH1      - Show headers
ATSP6     - Protocol 6 (CAN 500kbaud, 11-bit)
ATS0      - Spaces off
ATM0      - Memory off
ATAT1     - Adaptive timing
ATFCSM1   - Flow control mode 1
```

## Home Assistant Integration

With MQTT discovery enabled, entities will appear automatically:
- `sensor.xpeng_g6_soc` - Battery percentage
- `sensor.xpeng_g6_hv_voltage` - Pack voltage
- `sensor.xpeng_g6_hv_current` - Battery current
- `sensor.xpeng_g6_speed` - Vehicle speed
- `sensor.xpeng_g6_battery_temp_max` - Max battery temp
- `sensor.xpeng_g6_12v_battery` - 12V battery voltage
- And more...

## Troubleshooting

### No Data Received
1. Verify vehicle is powered on (at least accessory mode)
2. Check WiCAN is connected to your WiFi
3. Verify OBD port connection is secure

### Incorrect Values
1. Check the formula/math expression for the PID
2. Verify the correct header is set (704 for BMS, 7E0 for VCU)
3. Some PIDs require multi-frame responses

### Charging Not Detected
1. Ensure speed is 0 before checking current
2. Use HV Current (221103) as primary indicator
3. BMS Charge Status (22112D) can remain stale when cable is plugged in but not charging

## Related Files

- `XPENG_G6_PIDs.md` - Complete PID reference documentation
- `wican_xpeng_g6_profile.json` - WiCAN JSON configuration file

## Compatibility

Tested with:
- XPENG G6 2023-2024 models
- WiCAN firmware v2.x and v3.x
- Home Assistant 2024.x+
