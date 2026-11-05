# Getting XPENG G6 Data into Home Assistant

*Form reply for community questions*

---

There are 3 main options:

1. **Enode API** - Unfortunately, they seem to have stopped providing individual access to their production API, so this is no longer a viable option for most users.

2. **ABRP + OBD-II Scraping** - Connect an OBD-II Bluetooth adapter to ABRP (A Better Route Planner), then scrape the ABRP website for data. Works but is a bit hacky.

3. **XPCarData App (Recommended)** - I've developed an Android app that reads OBD-II data directly and publishes to Home Assistant via MQTT with auto-discovery. It can run on:
   - An Android AI Box in the car (Carlinkit, Ottocast, etc.)
   - Your Android phone

   **Features:**
   - Real-time battery SOC, voltage, current, temperature
   - Charging session detection and history
   - ABRP telemetry integration
   - Home Assistant auto-discovery (sensors appear automatically)
   - 12V battery protection (pauses polling if aux battery is low)

   **GitHub:** https://github.com/stevelea/xpcardata

   Happy to help if you have questions!

---

## Charge-port state (IEC 61851 State B)

The app publishes `charging_status` as `A` (standby) or `C` (charging). State B
("vehicle detected": cable plugged in, not charging) cannot be derived from the
G6's OBD PIDs today — the raw charge-status PIDs latch and stay non-zero after
the cable is unplugged. Raw `bms_chg_status` (22112D) and `charging_flag`
(22031D) sensors are exposed so the behaviour can be measured per car. The
evidence needed and the test for a usable State B signal are in
[CHARGE_PORT_STATE.md](CHARGE_PORT_STATE.md).
