import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/obd_pid_config.dart';
import '../models/vehicle_profile.dart';
import '../models/local_vehicle_profiles.dart';
import '../services/vehicle_profile_service.dart';

/// Screen for configuring custom OBD-II PIDs
class OBDPIDConfigScreen extends StatefulWidget {
  const OBDPIDConfigScreen({super.key});

  @override
  State<OBDPIDConfigScreen> createState() => _OBDPIDConfigScreenState();
}

class _OBDPIDConfigScreenState extends State<OBDPIDConfigScreen> {
  final _profileService = VehicleProfileService();
  List<OBDPIDConfig> _pids = [];
  String? _selectedVehicleProfile;
  VehicleProfiles? _vehicleProfiles;
  bool _isLoadingProfiles = false;

  // Local profiles (verified, in-app)
  final List<LocalVehicleProfile> _localProfiles = LocalVehicleProfiles.getProfiles();

  @override
  void initState() {
    super.initState();
    _loadPIDs();
    _loadVehicleProfiles();
    _loadSelectedProfile();
  }

  Future<void> _loadPIDs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pidsJson = prefs.getString('obd_pids');

      if (pidsJson != null) {
        final List<dynamic> pidsList = json.decode(pidsJson);
        setState(() {
          _pids = pidsList.map((p) => OBDPIDConfig.fromJson(p)).toList();
        });
        debugPrint('Loaded ${_pids.length} PIDs from SharedPreferences');
      } else {
        // No saved PIDs in SharedPreferences, try file fallback
        debugPrint('No PIDs in SharedPreferences, trying file...');
        await _loadPIDsFromFile();
      }
    } catch (e) {
      // SharedPreferences error, try file fallback
      debugPrint('SharedPreferences failed, trying file fallback: $e');
      await _loadPIDsFromFile();
    }

    // If still empty after all attempts, log it
    if (_pids.isEmpty) {
      debugPrint('No PIDs found - user needs to load a vehicle profile');
    }
  }

  Future<void> _loadSelectedProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final selectedProfile = prefs.getString('selected_vehicle_profile');

      if (selectedProfile != null) {
        setState(() {
          _selectedVehicleProfile = selectedProfile;
        });
      }
    } catch (e) {
      // SharedPreferences not available, continue without saved profile
      debugPrint('Could not load selected profile: $e');
    }
  }

  Future<void> _loadVehicleProfiles() async {
    setState(() {
      _isLoadingProfiles = true;
    });

    final profiles = await _profileService.fetchProfiles();

    setState(() {
      _vehicleProfiles = profiles;
      _isLoadingProfiles = false;
    });

    if (profiles == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to load vehicle profiles. Check internet connection.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _savePIDs() async {
    // Always save to file first (most reliable)
    await _savePIDsToFile();

    // Also try to save to SharedPreferences (if available)
    try {
      final prefs = await SharedPreferences.getInstance();
      final pidsJson = json.encode(_pids.map((p) => p.toJson()).toList());
      await prefs.setString('obd_pids', pidsJson);
      debugPrint('PIDs saved to SharedPreferences');
    } catch (e) {
      debugPrint('SharedPreferences save failed (file save successful): $e');
    }
  }

  Future<void> _savePIDsToFile() async {
    try {
      // Try path_provider first, fallback to hardcoded path
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/obd_pids.json';
      } catch (e) {
        // path_provider failed, use hardcoded Android path
        filePath = '/data/data/com.example.carsoc/files/obd_pids.json';
      }

      final file = File(filePath);
      final pidsJson = json.encode(_pids.map((p) => p.toJson()).toList());
      await file.writeAsString(pidsJson);
      debugPrint('PIDs saved to file: $filePath');
    } catch (e) {
      debugPrint('File-based PID storage failed: $e');
    }
  }

  Future<void> _loadPIDsFromFile() async {
    try {
      // Try path_provider first, fallback to hardcoded path
      String? filePath;
      try {
        final directory = await getApplicationDocumentsDirectory();
        filePath = '${directory.path}/obd_pids.json';
      } catch (e) {
        // path_provider failed, use hardcoded Android path
        filePath = '/data/data/com.example.carsoc/files/obd_pids.json';
      }

      final file = File(filePath);

      if (await file.exists()) {
        final pidsJson = await file.readAsString();
        final List<dynamic> pidsList = json.decode(pidsJson);
        setState(() {
          _pids = pidsList.map((p) => OBDPIDConfig.fromJson(p)).toList();
        });
        debugPrint('PIDs loaded from file: ${_pids.length} PIDs from $filePath');
      } else {
        debugPrint('No PID file found at $filePath');
      }
    } catch (e) {
      debugPrint('File-based PID loading failed: $e');
    }
  }

  void _addCustomPID() {
    final nameController = TextEditingController();
    final pidController = TextEditingController();
    final descController = TextEditingController();
    final formulaController = TextEditingController();
    OBDPIDType selectedType = OBDPIDType.custom;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Custom PID'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g., Battery Temperature',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pidController,
                decoration: const InputDecoration(
                  labelText: 'PID (hex)',
                  hintText: 'e.g., 015B or 2101',
                ),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: formulaController,
                decoration: const InputDecoration(
                  labelText: 'Formula',
                  hintText: 'e.g., A or (A*256+B)/4 or A-40',
                  helperText: 'A, B, C, D = data bytes',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: descController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'What this PID measures',
                ),
              ),
              const SizedBox(height: 16),
              StatefulBuilder(
                builder: (context, setDialogState) => DropdownButtonFormField<OBDPIDType>(
                  initialValue: selectedType,
                  decoration: const InputDecoration(
                    labelText: 'Type',
                  ),
                  items: OBDPIDType.values
                      .map((type) => DropdownMenuItem(
                            value: type,
                            child: Text(_formatPIDType(type)),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() {
                        selectedType = value;
                      });
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.isNotEmpty &&
                  pidController.text.isNotEmpty &&
                  formulaController.text.isNotEmpty) {
                final newPID = OBDPIDConfig(
                  name: nameController.text,
                  pid: pidController.text.toUpperCase(),
                  description: descController.text,
                  type: selectedType,
                  formula: formulaController.text,
                  parser: (response) => OBDPIDConfig.parseWithFormula(response, formulaController.text),
                );

                setState(() {
                  _pids.add(newPID);
                });
                _savePIDs();
                Navigator.pop(context);

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Added PID: ${nameController.text}'),
                    backgroundColor: Colors.green,
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please fill in all fields'),
                    backgroundColor: Colors.orange,
                  ),
                );
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  /// Load a local (verified) vehicle profile
  Future<void> _loadLocalProfile(LocalVehicleProfile profile) async {
    setState(() {
      _pids = List.from(profile.pids);
      _selectedVehicleProfile = profile.name;
    });
    _savePIDs();

    // Save selected profile and init commands
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_vehicle_profile', profile.name);

      if (profile.init != null && profile.init!.isNotEmpty) {
        await prefs.setString('obd_init_commands', profile.init!);
        debugPrint('Saved init commands for ${profile.name}');
      } else {
        await prefs.remove('obd_init_commands');
      }
    } catch (e) {
      debugPrint('Could not save selected profile: $e');
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Loaded ${profile.pids.length} PIDs for ${profile.name}'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _loadVehicleProfilePIDs(String carModel) async {
    final profile = _vehicleProfiles?.findProfile(carModel);
    if (profile != null) {
      final profilePIDs = _profileService.convertProfileToPIDs(profile);

      setState(() {
        // REPLACE all PIDs with profile PIDs (don't add to existing)
        _pids = profilePIDs;
        _selectedVehicleProfile = carModel;
      });
      _savePIDs();

      // Save selected vehicle profile and init commands (non-blocking)
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('selected_vehicle_profile', carModel);

        // Save vehicle-specific init commands if present
        if (profile.init != null && profile.init!.isNotEmpty) {
          await prefs.setString('obd_init_commands', profile.init!);
          debugPrint('Saved init commands for $carModel');
        } else {
          await prefs.remove('obd_init_commands');
        }
      } catch (e) {
        // SharedPreferences error, profile won't persist but PIDs are loaded
        debugPrint('Could not save selected profile: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Loaded ${profilePIDs.length} PIDs for $carModel'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  void _clearAllPIDs() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All PIDs'),
        content: const Text('This will remove all configured PIDs. You can then load a vehicle profile. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _pids = [];
                _selectedVehicleProfile = null;
              });
              _savePIDs();
              Navigator.pop(context);

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('All PIDs cleared'),
                  backgroundColor: Colors.orange,
                ),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }

  void _deletePID(int index) {
    setState(() {
      _pids.removeAt(index);
    });
    _savePIDs();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PID removed')),
    );
  }

  String _formatPIDType(OBDPIDType type) {
    switch (type) {
      case OBDPIDType.speed:
        return 'Speed';
      case OBDPIDType.stateOfCharge:
        return 'State of Charge';
      case OBDPIDType.batteryVoltage:
        return 'Battery Voltage';
      case OBDPIDType.odometer:
        return 'Odometer';
      case OBDPIDType.cumulativeCharge:
        return 'Cumulative Charge';
      case OBDPIDType.cumulativeDischarge:
        return 'Cumulative Discharge';
      case OBDPIDType.custom:
        return 'Custom';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OBD-II PID Configuration'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _clearAllPIDs,
            tooltip: 'Clear All PIDs',
          ),
        ],
      ),
      body: Column(
        children: [
          // Local (Verified) Vehicle Profiles - shown first
          if (_localProfiles.isNotEmpty)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.green.shade900.withValues(alpha: 0.3)
                  : Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.verified, size: 20, color: Colors.green.shade400),
                        const SizedBox(width: 8),
                        Text(
                          'Verified Profiles',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tested and verified PID configurations',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surface,
                      ),
                      hint: Text(
                        'Select your vehicle',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      initialValue: _localProfiles.any((p) => p.name == _selectedVehicleProfile)
                          ? _selectedVehicleProfile
                          : null,
                      items: _localProfiles
                          .map((profile) => DropdownMenuItem(
                                value: profile.name,
                                child: Text(
                                  '${profile.name} (${profile.year})',
                                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                                ),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          final profile = _localProfiles.firstWhere((p) => p.name == value);
                          _loadLocalProfile(profile);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),

          // WiCAN Vehicle Profiles (community profiles)
          if (_vehicleProfiles != null)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.cloud_download, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Community Profiles',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'From WiCAN firmware (may need adjustment)',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    DropdownButton<String>(
                      isExpanded: true,
                      hint: const Text('Select vehicle model'),
                      value: _vehicleProfiles!.getCarModels().contains(_selectedVehicleProfile)
                          ? _selectedVehicleProfile
                          : null,
                      items: _vehicleProfiles!.getCarModels()
                          .map((model) => DropdownMenuItem(
                                value: model,
                                child: Text(model),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          _loadVehicleProfilePIDs(value);
                        }
                      },
                    ),
                  ],
                ),
              ),
            )
          else if (_isLoadingProfiles)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: const [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('Loading community profiles...'),
                  ],
                ),
              ),
            ),

          // PID list
          Expanded(
            child: _pids.isEmpty
                ? const Center(
                    child: Text('No PIDs configured'),
                  )
                : ListView.builder(
                    itemCount: _pids.length,
                    itemBuilder: (context, index) {
                      final pid = _pids[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text(
                              pid.pid.length >= 2 ? pid.pid.substring(0, 2) : pid.pid,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          title: Text(pid.name),
                          subtitle: Text(
                            'PID: ${pid.pid}\n'
                            '${pid.formula != null ? 'Formula: ${pid.formula}\n' : ''}'
                            '${pid.description}',
                          ),
                          isThreeLine: true,
                          trailing: IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _deletePID(index),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCustomPID,
        icon: const Icon(Icons.add),
        label: const Text('Add Custom PID'),
      ),
    );
  }
}
