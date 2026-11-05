import 'package:flutter_test/flutter_test.dart';

import 'package:carsoc/models/local_vehicle_profiles.dart';

/// Profiles derived from Car Scanner's shared XPENG UDS PID set (profile 838:
/// "P5 / P7 / G6 / G9 / X9"). The G6 v4 profile is the verified reference; the
/// other models reuse its PIDs and only retune the motor-speed offset that the
/// source profile distinguishes per platform.
void main() {
  group('available local profiles', () {
    test('exposes G6, G3i, G9, P7, P5 and X9', () {
      final names = LocalVehicleProfiles.getProfiles().map((p) => p.name).toList();
      expect(names, containsAll(<String>[
        'XPENG G6',
        'XPENG G3i',
        'XPENG G9',
        'XPENG P7',
        'XPENG P5',
        'XPENG X9',
      ]));
    });

    test('findProfile resolves each model by name', () {
      for (final name in ['XPENG G6', 'XPENG G9', 'XPENG P7', 'XPENG P5', 'XPENG X9']) {
        expect(LocalVehicleProfiles.findProfile(name), isNotNull, reason: name);
      }
    });

    test('shared-set profiles poll the same PIDs as the G6', () {
      final g6 = LocalVehicleProfiles.xpengG6Profile.pids;
      for (final profile in [
        LocalVehicleProfiles.xpengG9Profile,
        LocalVehicleProfiles.xpengP7Profile,
        LocalVehicleProfiles.xpengP5Profile,
        LocalVehicleProfiles.xpengX9Profile,
      ]) {
        expect(profile.pids, hasLength(g6.length), reason: profile.name);
        expect(
          profile.pids.map((p) => p.pid).toList(),
          g6.map((p) => p.pid).toList(),
          reason: profile.name,
        );
        expect(profile.init, LocalVehicleProfiles.xpengG6Profile.init);
      }
    });

    test('legacy switch keeps returning the v3 G6 profile only', () {
      LocalVehicleProfiles.useLegacyV3XpengProfile = true;
      try {
        final profiles = LocalVehicleProfiles.getProfiles();
        expect(profiles.first.name, 'XPENG G6');
        expect(profiles.first.year, contains('legacy v3'));
        expect(profiles.first.pids, isNot(same(LocalVehicleProfiles.xpengG6Profile.pids)));
        expect(profiles.map((p) => p.name), contains('XPENG G9'));
      } finally {
        LocalVehicleProfiles.useLegacyV3XpengProfile = false;
      }
    });
  });

  group('motor speed offset per platform', () {
    OBDPIDConfigLike rpm(LocalVehicleProfile profile) =>
        OBDPIDConfigLike(profile.pids.firstWhere((p) => p.pid == '220317'));

    test('G6 and G9/X9 use the -16000 rpm offset', () {
      expect(rpm(LocalVehicleProfiles.xpengG6Profile).formula, '[B4:B5]-16000');
      expect(rpm(LocalVehicleProfiles.xpengG9Profile).formula, '[B4:B5]-16000');
      expect(rpm(LocalVehicleProfiles.xpengX9Profile).formula, '[B4:B5]-16000');
    });

    test('P5 and P7 use the -5000 rpm offset from the source profile', () {
      expect(rpm(LocalVehicleProfiles.xpengP5Profile).formula, '[B4:B5]-5000');
      expect(rpm(LocalVehicleProfiles.xpengP7Profile).formula, '[B4:B5]-5000');
    });

    test('P5 parser turns raw 5000 into 0 rpm and raw 6000 into 1000 rpm', () {
      final p5 = LocalVehicleProfiles.xpengP5Profile;
      final parser = p5.pids.firstWhere((p) => p.pid == '220317').parser;

      // 0x1388 = 5000 rpm raw, offset by -5000 per the source profile.
      expect(parser('7E8 06 62 03 17 13 88'), 0);
      // 0x1770 = 6000 rpm raw.
      expect(parser('7E8 06 62 03 17 17 70'), 1000);
    });
  });
}

/// Small wrapper so the test can name the RPM entry type without importing the
/// PID model into every matcher.
class OBDPIDConfigLike {
  final String formula;

  OBDPIDConfigLike(dynamic pid) : formula = pid.formula as String;
}
