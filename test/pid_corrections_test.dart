import 'package:flutter_test/flutter_test.dart';

import 'package:carsoc/models/local_vehicle_profiles.dart';
import 'package:carsoc/models/obd_pid_config.dart';
import 'package:carsoc/models/pid_corrections.dart';

/// `220326` (SLOW_CHG_T3) was configured as `B4-40`, which decoded the car's
/// 0x86 as 94 °C while the same byte at 220327 (MOTOR_T, `B4/2-40`) read 27 °C on
/// an idle car whose other charge temperatures were 26-27 °C. The fix must apply
/// to the G6 v4 profile and to profiles already persisted on a device, without
/// touching the G3i or community profiles.
void main() {
  OBDPIDConfig slowChgT3(String formula, {String header = '7E0'}) => OBDPIDConfig(
        name: 'SLOW_CHG_T3',
        pid: '220326',
        description: 'Slow Charging Temperature 3',
        type: OBDPIDType.custom,
        header: header,
        formula: formula,
        parser: (r) => OBDPIDConfig.parseWithFormula(r, formula),
      );

  OBDPIDConfig speed({String header = '7E0'}) => OBDPIDConfig(
        name: 'Speed',
        pid: '220104',
        description: 'Vehicle Speed',
        type: OBDPIDType.speed,
        header: header,
        formula: '[B4:B5]/100',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/100'),
      );

  group('G6 v4 profile', () {
    test('220326 is a 0.5 °C/LSB sensor: 0x86 decodes to 27 °C, not 94 °C', () {
      final pid = LocalVehicleProfiles.xpengG6Profile.pids
          .firstWhere((p) => p.pid == '220326');
      expect(pid.formula, 'B4/2-40');

      // The exact frame from the field log: 62 03 26 86.
      expect(pid.parser('7E80462032686'), 27.0);
    });

    test('neighbouring charge temperatures still use 1 °C/LSB', () {
      final t1 = LocalVehicleProfiles.xpengG6Profile.pids
          .firstWhere((p) => p.pid == '220322');
      expect(t1.formula, 'B4-40');
      expect(t1.parser('7E80462032242'), 26.0);
    });

    test('the G3i profile does not expose 220326 at all', () {
      // Unverified G3i PIDs are commented out in the profile, so there is
      // nothing to correct there.
      expect(
        LocalVehicleProfiles.xpengG3iProfile.pids.any((p) => p.pid == '220326'),
        isFalse,
      );
    });
  });

  group('stored-PID corrections', () {
    test('rewrites the old formula on G6-family lists', () {
      final corrected = PidCorrections.apply([speed(), slowChgT3('B4-40')]);
      final fixed = corrected.firstWhere((p) => p.pid == '220326');

      expect(fixed.formula, 'B4/2-40');
      expect(fixed.parser('7E80462032686'), 27.0);
      expect(fixed.description, contains('formula corrected'));
    });

    test('is idempotent', () {
      final once = PidCorrections.apply([speed(), slowChgT3('B4-40')]);
      final twice = PidCorrections.apply(once);
      expect(identical(once, twice), isTrue, reason: 'no second rewrite');
    });

    test('returns the same list when nothing needs fixing', () {
      final pids = [speed(), slowChgT3('B4/2-40')];
      expect(identical(PidCorrections.apply(pids), pids), isTrue);
    });

    test('does not touch G3i-style lists (speed on BMS 704)', () {
      final pids = [speed(header: '704'), slowChgT3('B4-40')];
      expect(identical(PidCorrections.apply(pids), pids), isTrue);
    });

    test('does not touch community profiles without the speed PID', () {
      final pids = [slowChgT3('B4-40')];
      expect(identical(PidCorrections.apply(pids), pids), isTrue);
    });
  });
}
