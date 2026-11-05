/// State machine for the 12 V battery protection.
///
/// v1.4.25 and earlier paused OBD polling as soon as the 12 V rail dipped
/// below the threshold — including a perfectly healthy 12.6 V resting battery
/// against the old 12.8 V default. Because the pause also stopped the host from
/// reading `AUX_V` again, the recovery branch could never run and the app
/// stopped polling until restart.
///
/// This guard fixes both halves of that deadlock:
///  * it only pauses after [requiredLowSamples] consecutive low readings, so a
///    single dip (cranking, contactor clap) cannot trigger it;
///  * the caller keeps sampling with a slow timer while paused and feeds those
///    readings back in, so a recovered rail resumes polling.
class AuxBatteryGuard {
  AuxBatteryGuard({
    required this.thresholdVolts,
    this.hysteresisVolts = 0.3,
    this.requiredLowSamples = 3,
  })  : assert(requiredLowSamples > 0, 'need at least one sample'),
        assert(hysteresisVolts >= 0, 'hysteresis must not be negative');

  final double thresholdVolts;
  final double hysteresisVolts;
  final int requiredLowSamples;

  int _lowSamples = 0;
  bool _active = false;

  bool get isActive => _active;
  int get lowSampleCount => _lowSamples;

  /// Feed a 12 V reading. Returns what the caller should do.
  AuxBatteryAction update(double volts) {
    if (!volts.isFinite) return AuxBatteryAction.none;

    if (!_active) {
      if (volts < thresholdVolts) {
        _lowSamples++;
        if (_lowSamples >= requiredLowSamples) {
          _active = true;
          return AuxBatteryAction.pause;
        }
      } else {
        _lowSamples = 0;
      }
      return AuxBatteryAction.none;
    }

    if (volts >= thresholdVolts + hysteresisVolts) {
      _active = false;
      _lowSamples = 0;
      return AuxBatteryAction.resume;
    }
    return AuxBatteryAction.none;
  }

  /// Forget history, e.g. when the user changes the threshold or disables the
  /// protection.
  void reset({bool keepActive = false}) {
    _lowSamples = 0;
    if (!keepActive) _active = false;
  }
}

enum AuxBatteryAction { none, pause, resume }
