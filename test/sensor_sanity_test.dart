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

  group('speed sentinels', () {
    test('rejects the 255 km/h sentinel seen on a parked car', () {
      expect(SensorSanity.isPlausibleSpeed(255), isFalse);
      expect(SensorSanity.sanitizeSpeed(255), isNull);
    });

    test('rejects 0xFFFF-derived sentinels', () {
      expect(SensorSanity.isPlausibleSpeed(655.35), isFalse);
      expect(SensorSanity.isPlausibleSpeed(65535), isFalse);
    });

    test('accepts real speeds', () {
      expect(SensorSanity.isPlausibleSpeed(0), isTrue);
      expect(SensorSanity.isPlausibleSpeed(49.5), isTrue);
      expect(SensorSanity.isPlausibleSpeed(180), isTrue);
      expect(SensorSanity.sanitizeSpeed(112), 112);
    });

    test('rejects negative, too fast and non-finite speeds', () {
      expect(SensorSanity.isPlausibleSpeed(-1), isFalse);
      expect(SensorSanity.isPlausibleSpeed(251), isFalse);
      expect(SensorSanity.isPlausibleSpeed(double.nan), isFalse);
      expect(SensorSanity.sanitizeSpeed(null), isNull);
    });
  });

  group('charge temperature band', () {
    test('rejects the 94 °C mis-scaled reading', () {
      expect(SensorSanity.isPlausibleChargeTemperature(94), isFalse);
    });

    test('accepts normal charge temperatures', () {
      expect(SensorSanity.isPlausibleChargeTemperature(26), isTrue);
      expect(SensorSanity.isPlausibleChargeTemperature(-10), isTrue);
      expect(SensorSanity.isPlausibleChargeTemperature(80), isTrue);
    });

    test('rejects out-of-band and non-finite values', () {
      expect(SensorSanity.isPlausibleChargeTemperature(80.1), isFalse);
      expect(SensorSanity.isPlausibleChargeTemperature(-30.1), isFalse);
      expect(SensorSanity.isPlausibleChargeTemperature(double.nan), isFalse);
    });
  });

  group('motor speed sentinels', () {
    test('rejects the 24,000 rpm front-motor sentinel from a parked RWD car', () {
      // 0x9C40 = 40000, minus the -16000 offset => 24000 rpm at standstill.
      expect(SensorSanity.isPlausibleMotorRpm(24000), isFalse);
      expect(SensorSanity.sanitizeMotorRpm(24000), isNull);
    });

    test('accepts real motor speeds including reverse', () {
      expect(SensorSanity.isPlausibleMotorRpm(0), isTrue);
      expect(SensorSanity.isPlausibleMotorRpm(9000), isTrue);
      expect(SensorSanity.isPlausibleMotorRpm(-19500), isTrue);
    });

    test('rejects beyond ±20,000 rpm and non-finite values', () {
      expect(SensorSanity.isPlausibleMotorRpm(20001), isFalse);
      expect(SensorSanity.isPlausibleMotorRpm(-20001), isFalse);
      expect(SensorSanity.isPlausibleMotorRpm(double.nan), isFalse);
    });
  });

  group('DC session detection', () {
    test('requires current flowing into the pack', () {
      expect(SensorSanity.isDcSessionActive(-45.0), isTrue);
      expect(SensorSanity.isDcSessionActive(-0.5), isFalse);
      expect(SensorSanity.isDcSessionActive(0.5), isFalse);
      expect(SensorSanity.isDcSessionActive(null), isFalse);
    });

    test('does not publish inlet voltage at pack voltage while idle', () {
      // The log showed 586 V at the DC inlet with the pack at 0.5 A discharge.
      expect(
        SensorSanity.shouldPublishDcVoltage(packCurrent: 0.5, voltage: 586),
        isFalse,
      );
      expect(
        SensorSanity.shouldPublishDcVoltage(packCurrent: -45.0, voltage: 586),
        isTrue,
      );
      expect(
        SensorSanity.shouldPublishDcVoltage(packCurrent: -45.0, voltage: 18),
        isFalse,
      );
    });

    test('does not publish the 400 A sentinel while idle', () {
      expect(
        SensorSanity.shouldPublishDcCurrent(packCurrent: 0.5, current: 400.5),
        isFalse,
      );
      expect(
        SensorSanity.shouldPublishDcCurrent(packCurrent: -150.0, current: 150),
        isTrue,
      );
      expect(
        SensorSanity.shouldPublishDcCurrent(packCurrent: -150.0, current: 900),
        isFalse,
      );
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
