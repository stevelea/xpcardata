import 'obd_pid_config.dart';
import 'wican_response_parser.dart';

/// Corrections applied to PID lists that are already persisted on a device.
///
/// Profiles are stored as JSON after the first run, so fixing a formula in
/// `local_vehicle_profiles.dart` is not enough: existing installs keep the old
/// formula until a full profile migration (which would also discard community
/// profiles). These targeted rewrites fix one known-wrong entry in place.
///
/// Every rule is keyed on a formula that is *known wrong*, so applying them is
/// idempotent and never touches a profile that already has the right value.
class PidCorrections {
  PidCorrections._();

  /// `220326` (SLOW_CHG_T3) was configured as `B4-40`, which produced 94 °C on
  /// an idle car whose other charge temperatures read 26-27 °C. The car answered
  /// `0x86` on 220326 and the same `0x86` on 220327 (MOTOR_T), which is decoded
  /// as `0x86/2-40 = 27 °C` — so the byte is a 0.5 °C/LSB sensor and `B4-40`
  /// doubled the value.
  static const Map<String, ({String from, String to})> _formulaFixes = {
    '220326': (from: 'B4-40', to: 'B4/2-40'),
  };

  /// True when this list looks like an XPENG G6 / G9 family profile: those keep
  /// the speed PID on the VCU (7E0). The G3i profile keeps it on the BMS (704),
  /// and community profiles do not use these names, so both are left untouched.
  static bool isXpengG6Family(List<OBDPIDConfig> pids) {
    return pids.any((p) => p.pid == '220104' && p.header == '7E0');
  }

  /// Returns a corrected copy of [pids], or the same instance when nothing
  /// needed fixing (so callers can cheaply detect "no change" by identity).
  static List<OBDPIDConfig> apply(List<OBDPIDConfig> pids) {
    if (!isXpengG6Family(pids)) return pids;

    var changed = false;
    final corrected = <OBDPIDConfig>[];
    for (final pid in pids) {
      final rule = _formulaFixes[pid.pid];
      if (rule != null && pid.formula == rule.from) {
        changed = true;
        corrected.add(OBDPIDConfig(
          name: pid.name,
          pid: pid.pid,
          description: '${pid.description} [formula corrected to ${rule.to}]',
          type: pid.type,
          header: pid.header,
          priority: pid.priority,
          formula: rule.to,
          useWiCanLayout: pid.useWiCanLayout,
          parser: pid.useWiCanLayout
              ? (r) => WiCanResponseParser.parse(r, rule.to)
              : (r) => OBDPIDConfig.parseWithFormula(r, rule.to),
        ));
      } else {
        corrected.add(pid);
      }
    }

    return changed ? corrected : pids;
  }
}
