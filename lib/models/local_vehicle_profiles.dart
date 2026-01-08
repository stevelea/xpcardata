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
  static final xpengG6Profile = LocalVehicleProfile(
    name: 'XPENG G6',
    manufacturer: 'XPENG',
    model: 'G6',
    year: '2023+',
    init: 'ATH1;ATSP6;ATS0;ATM0;ATAT1;ATSH704;ATCRA784;ATFCSH704;ATFCSM1',
    pids: [
      OBDPIDConfig(
        name: 'Speed',
        pid: '220104',
        description: 'Vehicle Speed (km/h)',
        type: OBDPIDType.speed,
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
      ),
      OBDPIDConfig(
        name: 'SOC',
        pid: '221109',
        description: 'State of Charge (%)',
        type: OBDPIDType.stateOfCharge,
        formula: '[B4:B5]/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10'),
      ),
      OBDPIDConfig(
        name: 'SOH',
        pid: '22110A',
        description: 'State of Health (%)',
        type: OBDPIDType.custom,
        formula: '[B4:B5]/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10'),
      ),
      OBDPIDConfig(
        name: 'HV_V',
        pid: '221101',
        description: 'HV Battery Voltage (V)',
        type: OBDPIDType.batteryVoltage,
        formula: '[B4:B5]/10',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10'),
      ),
      OBDPIDConfig(
        name: 'HV_A',
        pid: '221103',
        description: 'HV Battery Current (A)',
        type: OBDPIDType.custom,
        formula: '(B4*256+B5)*0.5-1600',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '(B4*256+B5)*0.5-1600'),
      ),
      OBDPIDConfig(
        name: 'HV_C_V_MAX',
        pid: '221105',
        description: 'Max Cell Voltage (V)',
        type: OBDPIDType.custom,
        formula: '[B4:B5]/1000',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/1000'),
      ),
      OBDPIDConfig(
        name: 'HV_C_V_MIN',
        pid: '221106',
        description: 'Min Cell Voltage (V)',
        type: OBDPIDType.custom,
        formula: '[B4:B5]/1000',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/1000'),
      ),
      OBDPIDConfig(
        name: 'HV_T_MAX',
        pid: '221107',
        description: 'Max Battery Temp (°C)',
        type: OBDPIDType.custom,
        formula: 'B4-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40'),
      ),
      OBDPIDConfig(
        name: 'HV_T_MIN',
        pid: '221108',
        description: 'Min Battery Temp (°C)',
        type: OBDPIDType.custom,
        formula: 'B4-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4-40'),
      ),
      OBDPIDConfig(
        name: 'ODOMETER',
        pid: '220101',
        description: 'Odometer (km)',
        type: OBDPIDType.odometer,
        formula: '[B5:B6]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B5:B6]'),
      ),
      OBDPIDConfig(
        name: 'COOLANT_T',
        pid: '220328',
        description: 'Battery Coolant Temp (°C)',
        type: OBDPIDType.custom,
        formula: 'B4/2-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/2-40'),
      ),
      OBDPIDConfig(
        name: 'MOTOR_T',
        pid: '220327',
        description: 'Motor Coolant Temp (°C)',
        type: OBDPIDType.custom,
        formula: 'B4/2-40',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4/2-40'),
      ),
      OBDPIDConfig(
        name: 'DC_CHG_A',
        pid: '22031F',
        description: 'DC Fast Charge Current (A)',
        type: OBDPIDType.custom,
        formula: '[B4:B5]/10-1200',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]/10-1200'),
      ),
      OBDPIDConfig(
        name: 'DC_CHG_V',
        pid: '220320',
        description: 'DC Fast Charge Voltage (V)',
        type: OBDPIDType.custom,
        formula: '[B4:B5]',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, '[B4:B5]'),
      ),
      OBDPIDConfig(
        name: 'CHARGING',
        pid: '22031D',
        description: 'Charging Status (0=No, 1=Yes)',
        type: OBDPIDType.custom,
        formula: 'B4',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'B4'),
      ),
      OBDPIDConfig(
        name: 'Cumulative Charge',
        pid: '221120',
        description: 'Battery Pack Cumulative Charging (Ah)',
        type: OBDPIDType.cumulativeCharge,
        formula: 'A<<24+B<<16+C<<8+D',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'A<<24+B<<16+C<<8+D'),
      ),
      OBDPIDConfig(
        name: 'Cumulative Discharge',
        pid: '221121',
        description: 'Battery Pack Cumulative Discharging (Ah)',
        type: OBDPIDType.cumulativeDischarge,
        formula: 'A<<24+B<<16+C<<8+D',
        parser: (r) => OBDPIDConfig.parseWithFormula(r, 'A<<24+B<<16+C<<8+D'),
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
