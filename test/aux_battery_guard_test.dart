import 'package:flutter_test/flutter_test.dart';

import 'package:carsoc/services/aux_battery_guard.dart';
import 'package:carsoc/services/data_source_manager.dart';

/// Regression tests for the v1.4.25 12 V deadlock: on a parked G6 the rail sat
/// at 12.60 V, the old 12.8 V default paused polling on the first sample, and
/// because polling was paused the app never read `AUX_V` again — so it never
/// resumed. The guard now needs consecutive low samples and the caller keeps
/// sampling on a timer while paused.
void main() {
  group('defaults', () {
    test('the app default threshold is below a healthy resting battery', () {
      expect(DataSourceManager.defaultAuxBatteryThreshold, 12.0);
      expect(DataSourceManager.defaultAuxBatteryThreshold, lessThan(12.5));
    });
  });

  group('pause decisions', () {
    test('12.6 V no longer pauses with the new default threshold', () {
      final guard = AuxBatteryGuard(thresholdVolts: 12.0);
      for (var i = 0; i < 5; i++) {
        expect(guard.update(12.6), AuxBatteryAction.none);
      }
      expect(guard.isActive, isFalse);
    });

    test('a single dip does not pause (cranking / contactor clap)', () {
      final guard = AuxBatteryGuard(thresholdVolts: 12.0);
      expect(guard.update(11.9), AuxBatteryAction.none);
      expect(guard.update(12.6), AuxBatteryAction.none);
      expect(guard.isActive, isFalse);
      expect(guard.lowSampleCount, 0, reason: 'recovery must clear the counter');
    });

    test('three consecutive low samples pause', () {
      final guard = AuxBatteryGuard(thresholdVolts: 12.0);
      expect(guard.update(11.9), AuxBatteryAction.none);
      expect(guard.update(11.8), AuxBatteryAction.none);
      expect(guard.update(11.7), AuxBatteryAction.pause);
      expect(guard.isActive, isTrue);
      // Further low samples do not re-trigger.
      expect(guard.update(11.6), AuxBatteryAction.none);
    });

    test('the old 12.8 V threshold reproduces the reported behaviour', () {
      final guard = AuxBatteryGuard(thresholdVolts: 12.8);
      expect(guard.update(12.6), AuxBatteryAction.none);
      expect(guard.update(12.6), AuxBatteryAction.none);
      expect(guard.update(12.6), AuxBatteryAction.pause);
    });
  });

  group('resume decisions', () {
    test('resumes once the rail clears threshold + hysteresis', () {
      final guard = AuxBatteryGuard(thresholdVolts: 12.0);
      for (var i = 0; i < 3; i++) {
        guard.update(11.5);
      }
      expect(guard.isActive, isTrue);

      expect(guard.update(12.2), AuxBatteryAction.none, reason: 'inside hysteresis band');
      expect(guard.update(12.3), AuxBatteryAction.resume);
      expect(guard.isActive, isFalse);
    });

    test('resumes immediately when the alternator/charger raises the rail', () {
      final guard = AuxBatteryGuard(thresholdVolts: 12.0);
      for (var i = 0; i < 3; i++) {
        guard.update(11.5);
      }
      expect(guard.update(13.8), AuxBatteryAction.resume);
    });

    test('reset clears history and active state', () {
      final guard = AuxBatteryGuard(thresholdVolts: 12.0);
      guard.update(11.5);
      guard.update(11.5);
      guard.reset();
      expect(guard.lowSampleCount, 0);
      expect(guard.update(11.5), AuxBatteryAction.none);
      expect(guard.isActive, isFalse);
    });
  });

  group('edge cases', () {
    test('non-finite readings are ignored', () {
      final guard = AuxBatteryGuard(thresholdVolts: 12.0);
      expect(guard.update(double.nan), AuxBatteryAction.none);
      expect(guard.lowSampleCount, 0);
    });

    test('custom sample counts are honoured', () {
      final guard = AuxBatteryGuard(thresholdVolts: 12.0, requiredLowSamples: 1);
      expect(guard.update(11.9), AuxBatteryAction.pause);
    });
  });
}
