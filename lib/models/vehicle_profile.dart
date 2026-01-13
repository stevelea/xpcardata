/// Model for WiCAN vehicle profiles
/// Based on https://github.com/meatpiHQ/wican-fw/blob/main/vehicle_profiles.json
class VehicleProfile {
  final String carModel;
  final String? init;
  final List<ProfilePID> pids;

  const VehicleProfile({
    required this.carModel,
    this.init,
    required this.pids,
  });

  factory VehicleProfile.fromJson(Map<String, dynamic> json) {
    final pidsJson = json['pids'] as List<dynamic>? ?? [];
    final pids = pidsJson.map((p) => ProfilePID.fromJson(p as Map<String, dynamic>)).toList();

    return VehicleProfile(
      carModel: json['car_model'] as String,
      init: json['init'] as String?,
      pids: pids,
    );
  }
}

class ProfilePID {
  final String pid;
  final List<ProfileParameter> parameters;

  const ProfilePID({
    required this.pid,
    required this.parameters,
  });

  factory ProfilePID.fromJson(Map<String, dynamic> json) {
    final parametersJson = json['parameters'] as List<dynamic>? ?? [];
    final parameters = parametersJson.map((p) => ProfileParameter.fromJson(p as Map<String, dynamic>)).toList();

    return ProfilePID(
      pid: json['pid'] as String,
      parameters: parameters,
    );
  }
}

class ProfileParameter {
  final String name;
  final String expression;
  final String unit;
  final String? class_;

  const ProfileParameter({
    required this.name,
    required this.expression,
    required this.unit,
    this.class_,
  });

  factory ProfileParameter.fromJson(Map<String, dynamic> json) {
    return ProfileParameter(
      name: json['name'] as String,
      expression: json['expression'] as String,
      unit: json['unit'] as String,
      class_: json['class'] as String?,
    );
  }

  /// Get WiCAN expression as formula (no conversion needed)
  /// WiCAN uses: B3, [B3:B4], [B3:B6], etc. for byte references
  /// Our parser now supports this notation directly
  String toFormula() {
    // Return WiCAN expression as-is - our parser now understands this notation
    return expression;
  }
}

/// Container for all vehicle profiles
class VehicleProfiles {
  final List<VehicleProfile> cars;

  const VehicleProfiles({required this.cars});

  factory VehicleProfiles.fromJson(Map<String, dynamic> json) {
    final carsJson = json['cars'] as List<dynamic>? ?? [];
    final cars = carsJson.map((c) => VehicleProfile.fromJson(c as Map<String, dynamic>)).toList();

    return VehicleProfiles(cars: cars);
  }

  /// Get all unique car models
  List<String> getCarModels() {
    return cars.map((c) => c.carModel).toList()..sort();
  }

  /// Find profile by car model
  VehicleProfile? findProfile(String carModel) {
    try {
      return cars.firstWhere((c) => c.carModel == carModel);
    } catch (e) {
      return null;
    }
  }
}
