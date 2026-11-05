import 'package:flutter_test/flutter_test.dart';

import 'package:carsoc/models/obd_pid_config.dart';
import 'package:carsoc/models/vehicle_profile.dart';
import 'package:carsoc/models/wican_response_parser.dart';
import 'package:carsoc/services/vehicle_profile_service.dart';

/// Regression tests for issue #12: WiCAN community profiles index their `B`
/// offsets against WiCAN firmware's response buffer, which keeps ISO-TP framing
/// and consecutive-frame sequence bytes. XPCarData must build the same buffer or
/// every multi-frame community PID is shifted.
///
/// Hyundai/Kia `220102` (32 cell voltages) is the reference case from the issue:
/// cells are indexed `B10..B15`, `B17..B23`, `B25..B31`, `B33..B39`, `B41..B45`,
/// with the sequence bytes 21/22/23/24 landing at B16/B24/B32/B40.
const _kia220102 = '7EC 10 20 62 01 02 FF FF FF\r'
    '7EC 21 FF C2 C2 C2 C2 C2 C2\r'
    '7EC 22 C2 C2 C2 C2 C2 C2 C2\r'
    '7EC 23 C2 C2 C2 C2 C2 C2 C2\r'
    '7EC 24 C2 C2 C2 C2 C2 C2 C2\r'
    '7EC 25 C2 C2 C2 C2 C2 FF FF';

void main() {
  group('WiCanResponseParser byte layout', () {
    test('keeps ISO-TP framing and sequence bytes exactly like WiCAN', () {
      final bytes = WiCanResponseParser.extractBytes(_kia220102);

      expect(bytes.length, 48);
      // First frame: PCI type 1, length 0x20, service 0x62, PID echo 01 02.
      expect(bytes.sublist(0, 5), [0x10, 0x20, 0x62, 0x01, 0x02]);
      // Consecutive-frame sequence bytes stay in the buffer at multiples of 8.
      expect(bytes[8], 0x21);
      expect(bytes[16], 0x22);
      expect(bytes[24], 0x23);
      expect(bytes[32], 0x24);
      expect(bytes[40], 0x25);
    });

    test('WiCAN expression offsets resolve against that buffer', () {
      // First cell in the profile is B10 (0xC2 = 194), scaled by /50.
      expect(WiCanResponseParser.parse(_kia220102, 'B10/50'), closeTo(3.88, 0.0001));
      // B16 is a sequence byte, not a cell: the profile must skip it.
      expect(WiCanResponseParser.parse(_kia220102, 'B16'), 34);
      expect(WiCanResponseParser.parse(_kia220102, 'B17/50'), closeTo(3.88, 0.0001));
      expect(WiCanResponseParser.parse(_kia220102, 'B45/50'), closeTo(3.88, 0.0001));
      // Byte ranges stay big-endian over the same buffer.
      expect(WiCanResponseParser.parse(_kia220102, '[B10:B11]/50'),
          closeTo((0xC2 << 8 | 0xC2) / 50.0, 0.0001));
    });

    test('single-frame responses keep WiCAN indexing (B0 = PCI length)', () {
      const singleFrame = '7EC 06 62 11 03 0A 0B 00 00';
      expect(WiCanResponseParser.parse(singleFrame, 'B4'), 0x0A);
      expect(WiCanResponseParser.parse(singleFrame, '[B4:B5]/10'), 257.1);
    });

    test('error and negative responses are rejected as NaN', () {
      expect(WiCanResponseParser.parse('NO DATA', 'B10/50').isNaN, isTrue);
      expect(WiCanResponseParser.parse('7EC 03 7F 22 31\r>', 'B10/50').isNaN, isTrue);
    });
  });

  group('Built-in parser stays unchanged', () {
    test('parseWithFormula still strips the CAN ID and indexes data at B4', () {
      const singleFrame = '7EC 06 62 11 03 0A 0B 00 00';
      expect(OBDPIDConfig.parseWithFormula(singleFrame, 'B4'), 0x0A);
      expect(OBDPIDConfig.parseWithFormula(singleFrame, '[B4:B5]/10'), 257.1);
    });
  });

  group('WiCAN profile conversion', () {
    final profile = VehicleProfile.fromJson({
      'car_model': 'Kia: EV6 77kWh',
      'pids': [
        {
          'pid': '220102',
          'pid_init': 'ATSH7E4',
          'parameters': [
            {'name': 'HV_C_V_001', 'expression': 'B10/50', 'unit': 'V', 'class': 'battery', 'min': '0', 'max': '10'},
            {'name': 'HV_C_V_002', 'expression': 'B11/50', 'unit': 'V', 'class': 'battery', 'min': '0', 'max': '10'},
          ],
        },
      ],
    });

    test('applies the per-PID ECU header from pid_init', () {
      final pids = VehicleProfileService().convertProfileToPIDs(profile);
      expect(pids, hasLength(2));
      expect(pids.first.header, '7E4');
    });

    test('community PIDs parse multi-frame responses with WiCAN indexing', () {
      final pids = VehicleProfileService().convertProfileToPIDs(profile);
      expect(pids.first.parser(_kia220102), closeTo(3.88, 0.0001));
      expect(pids[1].parser(_kia220102), closeTo(3.88, 0.0001));
    });
  });
}
