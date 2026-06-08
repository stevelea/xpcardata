import 'obd_pid_config.dart';

/// Local vehicle profiles with verified PID configurations
/// These are maintained in-app and can be synced to Supabase later
class LocalVehicleProfiles {
  /// Back-out switch for the v4 XPENG G6 profile.
  /// When true, [findProfile] returns the pre-correction v3 profile instead of
  /// the WiCAN-corrected v4 one. Toggled via Settings → Vehicle and read by the
  /// OBD service at migration time, so users can revert if v4 regresses on
  /// their specific G6 firmware without reinstalling an older APK.
  static bool useLegacyV3XpengProfile = false;

  /// Get all available local profiles
  static List<LocalVehicleProfile> getProfiles() {
    return [
      useLegacyV3XpengProfile ? xpengG6ProfileV3Legacy : xpengG6Profile,
      // Add more profiles here as they are verified
    ];
  }

  /// Find a profile by name
  static LocalVehicleProfile? findProfile(String name) {
    try {
      return getProfiles().firstWhere((p) => p.name == name);
    } catch (e) {
      return null;
    }
  }

  /// XPENG G6 Profile v4 (2026-05-23) — corrected against community WiCAN
  /// definitions for the international G6 (E38B chassis, same as mainland E28).
  /// Notable changes vs v3:
  ///   - 220101 Odometer moved from VCU to BMS, formula [B4:B6] (3 bytes,
  ///     fixes issue #11 where VCU response yielded 25089 instead of 1146 km)
  ///   - 220102 12V voltage moved from VCU to BMS
  ///   - 220313 was wrongly labelled "Range Estimate"; is actually accelerator
  ///     pedal position (B4/2)
  ///   - 22031A was wrongly labelled "HV Power"; is actually rear motor torque
  ///     request ([B4:B5]/4-500). Power is now computed solely from
  ///     HV voltage × current at the OBD service level (more accurate anyway)
  ///   - 22031E was wrongly labelled "DC Charge Status"; is actually VCU-side
  ///     SoC ([B4:B5]/10)
  ///   - 220317 motor RPM now applies the G6-specific -16000 offset
  ///   - 220319 was wrongly labelled "Motor Torque"; is actually front motor
  ///     torque request ([B4:B5]/4-500)
  ///   - 220321 was wrongly labelled "AC Charge Current"; is actually brake
  ///     main cylinder pressure ([B4:B5]/5). Removes spurious AC charging UI
  ///     trigger that was firing while driving.
  ///   - 220322 was wrongly labelled "AC Charge Voltage"; is actually fast
  ///     charging temperature 1 (B4-40)
  ///   - 220325 was wrongly labelled "Inverter Temp"; is actually slow
  ///     charging temperature 2 (B4-40)
  ///   - New PIDs added: 220323 fast charging temp 2, 220324 slow charging
  ///     temp 1, 220326 slow charging temp 3
  ///
  /// ECU Headers:
  /// - 704 -> 784: BMS (Battery Management System) - PIDs 2211xx + a few 2201xx
  /// - 7E0 -> 7E8: VCU (Vehicle Control Unit) - PIDs 2201xx, 2203xx
  /// PIDs are ordered BMS first, then VCU to minimize header switches
  static final xpengG6Profile = LocalVehicleProfile(
    name: 'XPENG G6',
    manufacturer: 'XPENG',
    model: 'G6',
    year: '2023+ v4 (WiCAN-corrected)',
    // Init sets up BMS (704) as default header - PIDs start with BMS
    init: 'ATH1;ATSP6;ATS0;ATM0;ATAT1;ATFCSM1;ATSH704;ATCRA784;ATFCSH704',
    pids: [
      // ==================== BMS PIDs (Header 704) - Query first ====================
      // HIGH PRIORITY: Essential real-time data (polled every cycle)
      OBDPIDConfig(
        name: 'SOC',
        pid: '221109',
        description: 'State of Charge (%)',
        type: OBDPIDType.stateOfCharge,
        header: '704',
        priority: PIDPriority.high, // Critical - always needed
        formula: '[B4:B5]/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10'),
      ),
      OBDPIDConfig(
        name: 'SOH',
        pid: '22110A',
        description: 'State of Health (%)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Rarely changes - poll every 5 mins
        formula: '[B4:B5]/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10'),
      ),
      OBDPIDConfig(
        name: 'HV_V',
        pid: '221101',
        description: 'HV Battery Voltage (V)',
        type: OBDPIDType.batteryVoltage,
        header: '704',
        priority: PIDPriority.high, // Needed for power calculation
        formula: '[B4:B5]/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10'),
      ),
      OBDPIDConfig(
        name: 'HV_A',
        pid: '221103',
        description: 'HV Battery Current (A) — negative = charging',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.high, // Needed for charging detection & power
        formula: '[B4:B5]/2-1600',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/2-1600'),
      ),
      OBDPIDConfig(
        name: 'HV_C_V_MAX',
        pid: '221105',
        description: 'Max Cell Voltage (V)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Changes slowly - poll less often
        formula: '[B4:B5]/1000',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/1000'),
      ),
      OBDPIDConfig(
        name: 'HV_C_V_MIN',
        pid: '221106',
        description: 'Min Cell Voltage (V)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Changes slowly - poll less often
        formula: '[B4:B5]/1000',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/1000'),
      ),
      OBDPIDConfig(
        name: 'HV_T_MAX',
        pid: '221107',
        description: 'Max Battery Temp (°C)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.high, // Important for battery health monitoring
        formula: 'B4-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40'),
      ),
      OBDPIDConfig(
        name: 'HV_T_MIN',
        pid: '221108',
        description: 'Min Battery Temp (°C)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Less critical than max temp
        formula: 'B4-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40'),
      ),
      OBDPIDConfig(
        name: 'Cumulative Charge',
        pid: '221120',
        description: 'Battery Pack Cumulative Charging (Ah)',
        type: OBDPIDType.cumulativeCharge,
        header: '704',
        priority: PIDPriority.low, // Historical data - poll less often
        formula: 'A<<24+B<<16+C<<8+D',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'A<<24+B<<16+C<<8+D'),
      ),
      OBDPIDConfig(
        name: 'Cumulative Discharge',
        pid: '221121',
        description: 'Battery Pack Cumulative Discharging (Ah)',
        type: OBDPIDType.cumulativeDischarge,
        header: '704',
        priority: PIDPriority.low, // Historical data - poll less often
        formula: 'A<<24+B<<16+C<<8+D',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'A<<24+B<<16+C<<8+D'),
      ),
      // Multi-frame PIDs for individual cell data
      OBDPIDConfig(
        name: 'CELL_V_AVG',
        pid: '221122',
        description: 'Average Cell Voltage (V) - parses all ~150 cells',
        type: OBDPIDType.cellVoltages,
        header: '704',
        priority: PIDPriority.low, // Large response, poll less often
        formula: 'multi-frame',
        parser: OBDPIDConfig.getParserForType(OBDPIDType.cellVoltages),
      ),
      OBDPIDConfig(
        name: 'CELL_T_AVG',
        pid: '221123',
        description: 'Average Cell Temperature (°C) - parses all sensors',
        type: OBDPIDType.cellTemperatures,
        header: '704',
        priority: PIDPriority.low, // Large response, poll less often
        formula: 'multi-frame',
        parser: OBDPIDConfig.getParserForType(OBDPIDType.cellTemperatures),
      ),

      // ==================== Additional BMS PIDs (Header 704) - Confirmed working ====================
      OBDPIDConfig(
        name: 'BMS_1116',
        pid: '221116',
        description: 'BMS PID 1116 (unknown - large value ~22894)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Unknown/diagnostic - poll less often
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
      ),
      OBDPIDConfig(
        name: 'BMS_1117',
        pid: '221117',
        description: 'BMS PID 1117 (unknown - 732)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Unknown/diagnostic - poll less often
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
      ),
      OBDPIDConfig(
        name: 'CLTC_RANGE',
        pid: '221118',
        description: 'CLTC Range (km) - China rated range (~15-20% higher than WLTP)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Static value - poll less often
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
      ),
      OBDPIDConfig(
        name: 'BMS_111A',
        pid: '22111A',
        description: 'BMS PID 111A (unknown - reads 1000 raw, 100.0 with /10, formula may be wrong)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low,
        formula: '[B4:B5]/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10'),
      ),
      OBDPIDConfig(
        name: 'BMS_HV_V',
        pid: '221124',
        description: 'BMS HV Battery Voltage (V) - matches DC charger voltage',
        type: OBDPIDType.batteryVoltage,
        header: '704',
        priority: PIDPriority.low, // Redundant with HV_V - poll less often
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
      ),
      OBDPIDConfig(
        name: 'BMS_112C',
        pid: '22112C',
        description: 'BMS PID 112C (unknown - returned 30)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Unknown/diagnostic - poll less often
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
      ),
      OBDPIDConfig(
        name: 'BMS_CHG_STATUS',
        pid: '22112D',
        description: 'BMS Charge Status (0=Not charging, 2=Charging) — STALE after unplug, do not use for live state',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.high, // Important for charging detection
        formula: 'B4',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4'),
      ),
      OBDPIDConfig(
        name: 'CHG_LIMIT',
        pid: '221130',
        description: 'Charge Limit Setting (%) - BMS reports +10 offset, corrected here',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Setting rarely changes - poll less often
        formula: '[B4:B5]-10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]-10'),
      ),

      // BMS-hosted vehicle telemetry. Per the WiCAN community profile these PIDs
      // live on the BMS (704) rather than the VCU (7E0); querying them on the
      // VCU returned garbage (notably 0x6201 for the odometer, which was the
      // OBD response code being read as data — see issue #11).
      OBDPIDConfig(
        name: 'ODOMETER',
        pid: '220101',
        description: 'Odometer (km) — BMS-hosted, 3-byte value [B4:B6]',
        type: OBDPIDType.odometer,
        header: '704',
        priority: PIDPriority.low, // Changes very slowly - poll less often
        formula: '[B4:B6]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B6]'),
      ),
      OBDPIDConfig(
        name: 'AUX_V',
        pid: '220102',
        description: '12V Auxiliary Battery Voltage (V) — BMS-hosted',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.high, // High priority for 12V battery protection monitoring
        formula: 'B4/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/10'),
      ),

      // ==================== VCU PIDs (Header 7E0) - Query after BMS ====================
      OBDPIDConfig(
        name: 'Speed',
        pid: '220104',
        description: 'Vehicle Speed (km/h)',
        type: OBDPIDType.speed,
        header: '7E0',
        priority: PIDPriority.high, // Critical for charging detection (speed=0)
        formula: '[B4:B5]/100',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/100'),
      ),
      OBDPIDConfig(
        name: 'ACCEL_PEDAL',
        pid: '220313',
        description: 'Accelerator Pedal Position (%)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: 'B4/2',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/2'),
      ),
      OBDPIDConfig(
        name: 'FRONT_MOTOR_RPM',
        pid: '220317',
        description: 'Front Motor RPM (G6 offset -16000)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low, // Diagnostic - poll less often
        formula: '[B4:B5]-16000',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]-16000'),
      ),
      OBDPIDConfig(
        name: 'REAR_MOTOR_RPM',
        pid: '220318',
        description: 'Rear Motor RPM (G6 offset -16000)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: '[B4:B5]-16000',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]-16000'),
      ),
      OBDPIDConfig(
        name: 'FRONT_MOTOR_TORQUE_REQ',
        pid: '220319',
        description: 'Front Motor Torque Request (Nm)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: '[B4:B5]/4-500',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/4-500'),
      ),
      OBDPIDConfig(
        name: 'REAR_MOTOR_TORQUE_REQ',
        pid: '22031A',
        description: 'Rear Motor Torque Request (Nm) — was misidentified as HV_PWR in v3',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: '[B4:B5]/4-500',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/4-500'),
      ),
      OBDPIDConfig(
        name: 'CHARGING_HVIL',
        pid: '22031D',
        description: 'Charging HVIL Status — STALE after unplug, do not use for live state',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.high, // Important for charging detection
        formula: 'B4',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4'),
      ),
      OBDPIDConfig(
        name: 'VCU_SOC',
        pid: '22031E',
        description: 'VCU-side SoC (%) — was misidentified as DC_CHG_STATUS in v3',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: '[B4:B5]/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10'),
      ),
      OBDPIDConfig(
        name: 'DC_CHG_A',
        pid: '22031F',
        description: 'DC Fast Charge Current (A)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.high, // Important for DC charging monitoring
        formula: '[B4:B5]/10-1200',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10-1200'),
      ),
      OBDPIDConfig(
        name: 'DC_CHG_V',
        pid: '220320',
        description: 'DC Fast Charge Voltage (V)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.high, // Important for DC charging monitoring
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
      ),
      OBDPIDConfig(
        name: 'BRAKE_PRESSURE',
        pid: '220321',
        description: 'Brake Main Cylinder Pressure (bar) — was misidentified as AC_CHG_A in v3',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: '[B4:B5]/5',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/5'),
      ),
      OBDPIDConfig(
        name: 'FAST_CHG_T1',
        pid: '220322',
        description: 'Fast Charging Temperature 1 (°C) — was misidentified as AC_CHG_V in v3',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: 'B4-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40'),
      ),
      OBDPIDConfig(
        name: 'FAST_CHG_T2',
        pid: '220323',
        description: 'Fast Charging Temperature 2 (°C)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: 'B4-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40'),
      ),
      OBDPIDConfig(
        name: 'SLOW_CHG_T1',
        pid: '220324',
        description: 'Slow Charging Temperature 1 (°C)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: 'B4-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40'),
      ),
      OBDPIDConfig(
        name: 'SLOW_CHG_T2',
        pid: '220325',
        description: 'Slow Charging Temperature 2 (°C) — was misidentified as INV_T in v3',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: 'B4-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40'),
      ),
      OBDPIDConfig(
        name: 'SLOW_CHG_T3',
        pid: '220326',
        description: 'Slow Charging Temperature 3 (°C)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low,
        formula: 'B4-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40'),
      ),
      OBDPIDConfig(
        name: 'MOTOR_T',
        pid: '220327',
        description: 'Traction Motor Coolant Temp (°C)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low, // Diagnostic - poll less often
        formula: 'B4/2-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/2-40'),
      ),
      OBDPIDConfig(
        name: 'COOLANT_T',
        pid: '220328',
        description: 'Battery Coolant Temp (°C)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low, // Diagnostic - poll less often
        formula: 'B4/2-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/2-40'),
      ),
    ],
  );

  /// Legacy v3 XPENG G6 profile — kept as a back-out option.
  /// Reachable by setting [useLegacyV3XpengProfile] = true (Settings → Vehicle
  /// → "Use legacy v3 PIDs"). Use this if v4 regresses on a specific G6
  /// firmware variant. See the v4 docstring above for the diff.
  static final xpengG6ProfileV3Legacy = LocalVehicleProfile(
    name: 'XPENG G6',
    manufacturer: 'XPENG',
    model: 'G6',
    year: '2023+ (legacy v3)',
    init: 'ATH1;ATSP6;ATS0;ATM0;ATAT1;ATFCSM1;ATSH704;ATCRA784;ATFCSH704',
    pids: [
      OBDPIDConfig(name: 'SOC', pid: '221109', description: 'State of Charge (%)', type: OBDPIDType.stateOfCharge, header: '704', priority: PIDPriority.high, formula: '[B4:B5]/10', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10')),
      OBDPIDConfig(name: 'SOH', pid: '22110A', description: 'State of Health (%)', type: OBDPIDType.custom, header: '704', priority: PIDPriority.low, formula: '[B4:B5]/10', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10')),
      OBDPIDConfig(name: 'HV_V', pid: '221101', description: 'HV Battery Voltage (V)', type: OBDPIDType.batteryVoltage, header: '704', priority: PIDPriority.high, formula: '[B4:B5]/10', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10')),
      OBDPIDConfig(name: 'HV_A', pid: '221103', description: 'HV Battery Current (A)', type: OBDPIDType.custom, header: '704', priority: PIDPriority.high, formula: '(B4*256+B5)*0.5-1600', parser: (r) => OBDPIDConfig.parseWithFormula(r, '(B4*256+B5)*0.5-1600')),
      OBDPIDConfig(name: 'HV_C_V_MAX', pid: '221105', description: 'Max Cell Voltage (V)', type: OBDPIDType.custom, header: '704', priority: PIDPriority.low, formula: '[B4:B5]/1000', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/1000')),
      OBDPIDConfig(name: 'HV_C_V_MIN', pid: '221106', description: 'Min Cell Voltage (V)', type: OBDPIDType.custom, header: '704', priority: PIDPriority.low, formula: '[B4:B5]/1000', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/1000')),
      OBDPIDConfig(name: 'HV_T_MAX', pid: '221107', description: 'Max Battery Temp (°C)', type: OBDPIDType.custom, header: '704', priority: PIDPriority.high, formula: 'B4-40', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40')),
      OBDPIDConfig(name: 'HV_T_MIN', pid: '221108', description: 'Min Battery Temp (°C)', type: OBDPIDType.custom, header: '704', priority: PIDPriority.low, formula: 'B4-40', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40')),
      OBDPIDConfig(name: 'Cumulative Charge', pid: '221120', description: 'Battery Pack Cumulative Charging (Ah)', type: OBDPIDType.cumulativeCharge, header: '704', priority: PIDPriority.low, formula: 'A<<24+B<<16+C<<8+D', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'A<<24+B<<16+C<<8+D')),
      OBDPIDConfig(name: 'Cumulative Discharge', pid: '221121', description: 'Battery Pack Cumulative Discharging (Ah)', type: OBDPIDType.cumulativeDischarge, header: '704', priority: PIDPriority.low, formula: 'A<<24+B<<16+C<<8+D', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'A<<24+B<<16+C<<8+D')),
      OBDPIDConfig(name: 'CELL_V_AVG', pid: '221122', description: 'Average Cell Voltage (V)', type: OBDPIDType.cellVoltages, header: '704', priority: PIDPriority.low, formula: 'multi-frame', parser: OBDPIDConfig.getParserForType(OBDPIDType.cellVoltages)),
      OBDPIDConfig(name: 'CELL_T_AVG', pid: '221123', description: 'Average Cell Temperature (°C)', type: OBDPIDType.cellTemperatures, header: '704', priority: PIDPriority.low, formula: 'multi-frame', parser: OBDPIDConfig.getParserForType(OBDPIDType.cellTemperatures)),
      OBDPIDConfig(name: 'BMS_CHG_STATUS', pid: '22112D', description: 'BMS Charge Status (0=Not charging, 2=Charging)', type: OBDPIDType.custom, header: '704', priority: PIDPriority.high, formula: 'B4', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4')),
      OBDPIDConfig(name: 'CHG_LIMIT', pid: '221130', description: 'Charge Limit Setting (%)', type: OBDPIDType.custom, header: '704', priority: PIDPriority.low, formula: '[B4:B5]-10', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]-10')),
      OBDPIDConfig(name: 'Speed', pid: '220104', description: 'Vehicle Speed (km/h)', type: OBDPIDType.speed, header: '7E0', priority: PIDPriority.high, formula: '[B4:B5]/100', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/100')),
      // ↓ v3 had these on VCU; v4 moved them to BMS
      OBDPIDConfig(name: 'ODOMETER', pid: '220101', description: 'Odometer (km) [v3]', type: OBDPIDType.odometer, header: '7E0', priority: PIDPriority.low, formula: '[B5:B6]', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B5:B6]')),
      OBDPIDConfig(name: 'AUX_V', pid: '220102', description: '12V Auxiliary Battery Voltage (V) [v3]', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.high, formula: 'B4/10', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/10')),
      OBDPIDConfig(name: 'RANGE_EST', pid: '220313', description: 'Estimated Range (km) [v3 — actually accelerator pedal position]', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.low, formula: 'B4', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4')),
      OBDPIDConfig(name: 'HV_PWR', pid: '22031A', description: 'HV Battery Power (kW) [v3 — actually rear motor torque request]', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.high, formula: '([B4:B5]-20000)/10', parser: (r) => OBDPIDConfig.parseWithFormula(r, '([B4:B5]-20000)/10')),
      OBDPIDConfig(name: 'MOTOR_RPM', pid: '220317', description: 'Motor RPM [v3 — no G6 offset]', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.low, formula: '[B4:B5]', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]')),
      OBDPIDConfig(name: 'MOTOR_TORQUE', pid: '220319', description: 'Motor Torque (Nm) [v3]', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.low, formula: '([B4:B5]-20000)/10', parser: (r) => OBDPIDConfig.parseWithFormula(r, '([B4:B5]-20000)/10')),
      OBDPIDConfig(name: 'CHARGING', pid: '22031D', description: 'Charging Status (0=No, 1=Yes)', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.high, formula: 'B4', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4')),
      OBDPIDConfig(name: 'DC_CHG_STATUS', pid: '22031E', description: 'DC Charge Status [v3 — actually VCU SoC]', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.high, formula: 'B4', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4')),
      OBDPIDConfig(name: 'DC_CHG_A', pid: '22031F', description: 'DC Fast Charge Current (A)', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.high, formula: '[B4:B5]/10-1200', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10-1200')),
      OBDPIDConfig(name: 'DC_CHG_V', pid: '220320', description: 'DC Fast Charge Voltage (V)', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.high, formula: '[B4:B5]', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]')),
      OBDPIDConfig(name: 'AC_CHG_A', pid: '220321', description: 'AC Charge Current (A) [v3 — actually brake pressure]', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.high, formula: '[B4:B5]*2', parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]*2')),
      OBDPIDConfig(name: 'AC_CHG_V', pid: '220322', description: 'AC Charge Voltage (V) [v3 — actually fast charging temp 1]', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.high, formula: 'B4*3', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4*3')),
      OBDPIDConfig(name: 'INV_T', pid: '220325', description: 'Inverter Temperature (°C) [v3 — actually slow charging temp 2]', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.low, formula: 'B4/2-40', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/2-40')),
      OBDPIDConfig(name: 'MOTOR_T', pid: '220327', description: 'Motor Coolant Temp (°C)', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.low, formula: 'B4/2-40', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/2-40')),
      OBDPIDConfig(name: 'COOLANT_T', pid: '220328', description: 'Battery Coolant Temp (°C)', type: OBDPIDType.custom, header: '7E0', priority: PIDPriority.low, formula: 'B4/2-40', parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/2-40')),
    ],
  );
}

/// Local vehicle profile model
class LocalVehicleProfile {
  final String name;
  final String manufacturer;
  final String model;
  final String year;
  final String? init;
  final List<OBDPIDConfig> pids;

  const LocalVehicleProfile({
    required this.name,
    required this.manufacturer,
    required this.model,
    required this.year,
    this.init,
    required this.pids,
  });

  /// Convert to JSON for storage/sync
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'manufacturer': manufacturer,
      'model': model,
      'year': year,
      'init': init,
      'pids': pids.map((p) => p.toJson()).toList(),
    };
  }
}
