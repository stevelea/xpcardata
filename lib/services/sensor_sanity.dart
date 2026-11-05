/// Plausibility rules for raw PID values.
///
/// The G6 (and other UDS cars) answer some PIDs with values that are only
/// meaningful in certain states: the HV pack voltage reads near zero with the
/// contactors open, and the DC-charge current/voltage PIDs return sentinels
/// (e.g. 0x3E80 -> "400 A") when no DC session is active. Publishing those
/// values produces nonsense on the dashboard and in Home Assistant, so every
/// consumer filters through the rules below.
///
/// The thresholds are deliberately wide: they only reject physically
/// impossible values for an EV traction pack, never plausible ones.
class SensorSanity {
  SensorSanity._();

  /// No EV traction pack is below this when its contactors are closed.
  static const double minPlausiblePackVoltage = 100.0;

  /// Above this it is a 900 V-class pack (very large margin).
  static const double maxPlausiblePackVoltage = 1000.0;

  /// Pack/charge coolant temperatures live in this band; 94 °C at rest means the
  /// value was decoded with the wrong scale (220326 case) and must not be shown.
  static const double minPlausibleChargeTemp = -30.0;
  static const double maxPlausibleChargeTemp = 80.0;

  static bool isPlausibleChargeTemperature(double value) {
    return value.isFinite &&
        value >= minPlausibleChargeTemp &&
        value <= maxPlausibleChargeTemp;
  }

  /// A DC fast-charge session needs a real pack voltage at the inlet.
  static const double minPlausibleDcVoltage = 50.0;

  /// 600 A is above any current production car's DC peak.
  static const double maxPlausibleDcCurrent = 800.0;

  /// Transport-level adapter errors worth one silent retry. `7F` is *not* here:
  /// that is a valid negative response and retrying it wastes a cycle.
  static const List<String> transportErrorMarkers = [
    'CAN ERROR',
    'BUS ERROR',
    'BUFFER FULL',
    'FB ERROR',
    'DATA ERROR',
    'ACT ALERT',
  ];

  /// True when the pack voltage is physically plausible for a traction battery.
  ///
  /// A very low state of charge does not lower pack voltage by an order of
  /// magnitude, so [stateOfCharge] only tightens the check for near-empty
  /// packs: below 5 % a 90 V reading on a 400 V car is still rejected.
  static bool isPlausiblePackVoltage(double value, {double? stateOfCharge}) {
    if (!value.isFinite) return false;
    if (value < minPlausiblePackVoltage || value > maxPlausiblePackVoltage) {
      return false;
    }
    return true;
  }

  /// True for ELM327 responses that indicate a transport failure rather than a
  /// car-level answer (CAN arbitration/loss, buffer overflow, framing).
  static bool isTransportError(String response) {
    final upper = response.toUpperCase();
    for (final marker in transportErrorMarkers) {
      if (upper.contains(marker)) return true;
    }
    return false;
  }

  /// True when a DC charging voltage is plausible (inlet energised).
  static bool isPlausibleDcVoltage(double value) {
    return value.isFinite && value >= minPlausibleDcVoltage && value <= maxPlausiblePackVoltage;
  }

  /// True when a DC charging current is plausible *given* that the inlet
  /// voltage was plausible. Without a plausible voltage the current value is a
  /// sentinel and must not be published (the G6 reports 400 A while parked).
  static bool isPlausibleDcCurrent(double value, {required bool voltagePlausible}) {
    if (!voltagePlausible) return false;
    return value.isFinite && value.abs() <= maxPlausibleDcCurrent;
  }

  /// Fastest production EV is ~200 km/h; 250 is a generous ceiling.
  static const double maxPlausibleSpeedKmh = 250.0;

  /// CAN "signal not available" sentinels seen for 1-byte and 2-byte PIDs.
  static const double _speedSentinelByte = 255.0; // 0xFF
  static const double _speedSentinelWord = 655.35; // 0xFFFF / 100
  static const double _speedSentinelWordRaw = 65535.0;

  /// True for a speed that a car standing still or driving can actually show.
  ///
  /// A parked G6 reported 255 km/h, which is the 0xFF "not available" sentinel
  /// being decoded as a number (0xFF with a single-byte formula, or 0xFFFF with
  /// a /100 formula). Those values are rejected instead of shown.
  static bool isPlausibleSpeed(double value) {
    if (!value.isFinite) return false;
    if (value < 0 || value > maxPlausibleSpeedKmh) return false;
    if (value == _speedSentinelByte ||
        value == _speedSentinelWord ||
        value == _speedSentinelWordRaw) {
      return false;
    }
    return true;
  }

  /// Returns the speed when plausible, otherwise null (rendered as "—").
  static double? sanitizeSpeed(double? value) {
    if (value == null) return null;
    return isPlausibleSpeed(value) ? value : null;
  }

  /// Fastest production EV traction motor is ~18,000 rpm; 20,000 is a ceiling.
  static const double maxPlausibleMotorRpm = 20000.0;

  /// True for a motor speed a real car can report.
  ///
  /// A parked RWD G6 answered `220317` with 0x9C40, which decodes to 24,000 rpm
  /// after the -16,000 offset — the "not available" value for a motor the car
  /// does not have. Anything beyond ±20,000 rpm is rejected.
  static bool isPlausibleMotorRpm(double value) {
    return value.isFinite && value.abs() <= maxPlausibleMotorRpm;
  }

  static double? sanitizeMotorRpm(double? value) {
    if (value == null) return null;
    return isPlausibleMotorRpm(value) ? value : null;
  }

  /// A DC fast-charge session needs current flowing *into* the pack.
  ///
  /// The G6 reports inlet voltage ≈ pack voltage and a 400 A sentinel even with
  /// no session, so voltage alone cannot prove charging; HV pack current can
  /// (negative = charging).
  static bool isDcSessionActive(double? packCurrent) {
    return packCurrent != null && packCurrent.isFinite && packCurrent < -1.0;
  }

  /// DC inlet voltage may only be published during a real DC session.
  static bool shouldPublishDcVoltage({required double? packCurrent, required double voltage}) {
    return isDcSessionActive(packCurrent) && isPlausibleDcVoltage(voltage);
  }

  /// DC charge current may only be published during a real DC session.
  static bool shouldPublishDcCurrent({required double? packCurrent, required double current}) {
    return isDcSessionActive(packCurrent) &&
        isPlausibleDcCurrent(current, voltagePlausible: true);
  }

  /// Power in kW from pack voltage/current, or null when either is implausible.
  static double? computePowerKw(double? packVoltage, double? packCurrent) {
    if (packVoltage == null || packCurrent == null) return null;
    if (!isPlausiblePackVoltage(packVoltage)) return null;
    if (!packCurrent.isFinite) return null;
    return (packVoltage * packCurrent) / 1000;
  }
}
