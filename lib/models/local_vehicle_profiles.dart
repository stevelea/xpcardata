import 'obd_pid_config.dart';

/// Local vehicle profiles with verified PID configurations
/// These are maintained in-app and can be synced to Supabase later
class LocalVehicleProfiles {
  /// Get all available local profiles
  static List<LocalVehicleProfile> getProfiles() {
    return [
      xpengG6Profile,
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

  /// XPENG G6 Profile - Verified PIDs
  /// ECU Headers:
  /// - 704 -> 784: BMS (Battery Management System) - PIDs 2211xx
  /// - 7E0 -> 7E8: VCU (Vehicle Control Unit) - PIDs 2201xx, 2203xx
  /// PIDs are ordered BMS first, then VCU to minimize header switches
  static final xpengG6Profile = LocalVehicleProfile(
    name: 'XPENG G6',
    manufacturer: 'XPENG',
    model: 'G6',
    year: '2023+',
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
        description: 'HV Battery Current (A)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.high, // Needed for charging detection & power
        formula: '(B4*256+B5)*0.5-1600',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '(B4*256+B5)*0.5-1600'),
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
        description: 'BMS PID 111A (unknown - 1000, maybe 100.0%?)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Unknown/diagnostic - poll less often
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
        description: 'BMS Charge Status (0=Not charging, 2=Charging)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.high, // Important for charging detection
        formula: 'B4',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4'),
      ),
      OBDPIDConfig(
        name: 'CHG_LIMIT',
        pid: '221130',
        description: 'Charge Limit Setting (%)',
        type: OBDPIDType.custom,
        header: '704',
        priority: PIDPriority.low, // Setting rarely changes - poll less often
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
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
        name: 'ODOMETER',
        pid: '220101',
        description: 'Odometer (km)',
        type: OBDPIDType.odometer,
        header: '7E0',
        priority: PIDPriority.low, // Changes very slowly - poll less often
        formula: '[B5:B6]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B5:B6]'),
      ),
      OBDPIDConfig(
        name: 'AUX_V',
        pid: '220102',
        description: '12V Auxiliary Battery Voltage (V)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.high, // High priority for 12V battery protection monitoring
        formula: 'B4/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/10'),
      ),
      OBDPIDConfig(
        name: 'RANGE_EST',
        pid: '220313',
        description: 'Estimated Range (km)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low, // Changes slowly - poll less often
        formula: 'B4',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4'),
      ),
      OBDPIDConfig(
        name: 'HV_PWR',
        pid: '22031A',
        description: 'HV Battery Power (kW)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.high, // Important for power monitoring
        formula: '([B4:B5]-20000)/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '([B4:B5]-20000)/10'),
      ),
      OBDPIDConfig(
        name: 'MOTOR_RPM',
        pid: '220317',
        description: 'Motor RPM',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low, // Diagnostic - poll less often
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
      ),
      OBDPIDConfig(
        name: 'MOTOR_TORQUE',
        pid: '220319',
        description: 'Motor Torque (Nm)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low, // Diagnostic - poll less often
        formula: '([B4:B5]-20000)/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '([B4:B5]-20000)/10'),
      ),
      OBDPIDConfig(
        name: 'CHARGING',
        pid: '22031D',
        description: 'Charging Status (0=No, 1=Yes)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.high, // Important for charging detection
        formula: 'B4',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4'),
      ),
      OBDPIDConfig(
        name: 'DC_CHG_STATUS',
        pid: '22031E',
        description: 'DC Charge Status (0=Unplugged, 1=Initializing, 2=Charging, 3=Complete, 4=Stopped)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.high, // Important for DC charging detection
        formula: 'B4',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4'),
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
        name: 'AC_CHG_A',
        pid: '220321',
        description: 'AC Charge Current (A)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.high, // Important for AC charging monitoring
        formula: '[B4:B5]*2',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]*2'),
      ),
      OBDPIDConfig(
        name: 'AC_CHG_V',
        pid: '220322',
        description: 'AC Charge Voltage (V)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.high, // Important for AC charging monitoring
        formula: 'B4*3',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4*3'),
      ),
      OBDPIDConfig(
        name: 'INV_T',
        pid: '220325',
        description: 'Inverter Temperature (°C)',
        type: OBDPIDType.custom,
        header: '7E0',
        priority: PIDPriority.low, // Diagnostic - poll less often
        formula: 'B4/2-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/2-40'),
      ),
      OBDPIDConfig(
        name: 'MOTOR_T',
        pid: '220327',
        description: 'Motor Coolant Temp (°C)',
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
