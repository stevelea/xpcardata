import 'package:flutter_test/flutter_test.dart';

import 'package:carsoc/services/sensor_sanity.dart';

/// Regression tests for the live-car log from a parked XPENG G6:
///  * `221101` answered 9.7 V (contactors open) and was published as pack voltage;
///  * `22031F`/`220320` answered 400 A / 18 V with no DC session and were
///    published as DC charging;
///  * VCU requests intermittently returned `CAN ERROR`.
void main() {
  group('pack voltage plausibility', () {
    test('rejects the 9.7 V contactor-open reading from the log', () {
      expect(SensorSanity.isPlausiblePackVoltage(9.7), isFalse);
    });

    test('accepts real pack voltages for 400 V and 800 V cars', () {
      expect(SensorSanity.isPlausiblePackVoltage(389.5), isTrue);
      expect(SensorSanity.isPlausiblePackVoltage(690.0), isTrue);
    });

    test('rejects non-finite and out-of-range values', () {
      expect(SensorSanity.isPlausiblePackVoltage(double.nan), isFalse);
      expect(SensorSanity.isPlausiblePackVoltage(double.infinity), isFalse);
      expect(SensorSanity.isPlausiblePackVoltage(99.9), isFalse);
      expect(SensorSanity.isPlausiblePackVoltage(1001), isFalse);
    });
  });

  group('transport errors', () {
    test('detects CAN/BUS errors and buffer overflows', () {
      expect(SensorSanity.isTransportError('CAN ERROR\r\n>'), isTrue);
      expect(SensorSanity.isTransportError('BUS ERROR\r\n>'), isTrue);
      expect(SensorSanity.isTransportError('BUFFER FULL'), isTrue);
      expect(SensorSanity.isTransportError('can error'), isTrue);
    });

    test('does not treat valid answers or 7F negative responses as transport errors', () {
      expect(SensorSanity.isTransportError('784056211090283\r\n>'), isFalse);
      expect(SensorSanity.isTransportError('7E8 03 7F 22 31\r\n>'), isFalse);
      expect(SensorSanity.isTransportError('NO DATA'), isFalse);
    });
  });

  group('DC charging sentinels', () {
    test('rejects the 18 V inlet reading from the log', () {
      expect(SensorSanity.isPlausibleDcVoltage(18), isFalse);
      expect(SensorSanity.isPlausibleDcVoltage(0), isFalse);
    });

    test('accepts a real DC session voltage', () {
      expect(SensorSanity.isPlausibleDcVoltage(400), isTrue);
      expect(SensorSanity.isPlausibleDcVoltage(50), isTrue);
    });

    test('rejects DC current when the inlet voltage was not plausible', () {
      // The log's 400 A sentinel with the inlet at 18 V.
      expect(SensorSanity.isPlausibleDcCurrent(400, voltagePlausible: false), isFalse);
      // Real DC session.
      expect(SensorSanity.isPlausibleDcCurrent(180, voltagePlausible: true), isTrue);
      // Above any production car's peak.
      expect(SensorSanity.isPlausibleDcCurrent(900, voltagePlausible: true), isFalse);
    });
  });

  group('power calculation', () {
    test('computes kW from plausible values', () {
      expect(SensorSanity.computePowerKw(389.5, -12.3)!, closeTo(-4.79, 0.01));
    });

    test('returns null for the implausible pack voltage', () {
      expect(SensorSanity.computePowerKw(9.7, -12.3), isNull);
      expect(SensorSanity.computePowerKw(null, -12.3), isNull);
      expect(SensorSanity.computePowerKw(389.5, null), isNull);
    });
  });
}
