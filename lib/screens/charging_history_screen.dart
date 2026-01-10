import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/charging_session.dart';
import '../providers/vehicle_data_provider.dart';
import '../providers/mqtt_provider.dart';

/// Screen displaying charging history with consumption tracking
class ChargingHistoryScreen extends ConsumerStatefulWidget {
  const ChargingHistoryScreen({super.key});

  @override
  ConsumerState<ChargingHistoryScreen> createState() => _ChargingHistoryScreenState();
}

class _ChargingHistoryScreenState extends ConsumerState<ChargingHistoryScreen> {
  List<ChargingSession> _sessions = [];
  Map<String, dynamic> _statistics = {};
  bool _isLoading = true;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    final manager = ref.read(dataSourceManagerProvider);
    final service = manager.chargingSessionService;

    final sessions = await service.getAllSessions();
    final stats = await service.getStatistics();

    setState(() {
      _sessions = sessions;
      _statistics = stats;
      _isLoading = false;
    });
  }

  Future<void> _syncToMqtt() async {
    final mqttService = ref.read(mqttServiceProvider);
    if (!mqttService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('MQTT not connected'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isSyncing = true);

    try {
      final manager = ref.read(dataSourceManagerProvider);
      await manager.chargingSessionService.syncHistoryToMqtt();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Synced ${_sessions.length} sessions to MQTT'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mqttConnected = ref.watch(mqttServiceProvider).isConnected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Charging History'),
        actions: [
          IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Icon(
                    Icons.cloud_upload,
                    color: mqttConnected ? Colors.green : Colors.grey,
                  ),
            onPressed: (_isSyncing || _sessions.isEmpty) ? null : _syncToMqtt,
            tooltip: mqttConnected ? 'Sync to MQTT' : 'MQTT not connected',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: CustomScrollView(
                slivers: [
                  // Statistics header
                  SliverToBoxAdapter(
                    child: _buildStatisticsCard(),
                  ),
                  // Sessions list
                  if (_sessions.isEmpty)
                    const SliverFillRemaining(
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.ev_station_outlined, size: 64, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              'No charging sessions yet',
                              style: TextStyle(fontSize: 16, color: Colors.grey),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Sessions will appear here after charging',
                              style: TextStyle(fontSize: 14, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => _buildSessionCard(_sessions[index]),
                        childCount: _sessions.length,
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildStatisticsCard() {
    final sessionCount = _statistics['sessionCount'] ?? 0;
    final totalEnergy = _statistics['totalEnergyKwh'] ?? 0.0;
    final avgConsumption = _statistics['averageConsumptionKwhPer100km'];

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Statistics',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(
                  icon: Icons.ev_station,
                  label: 'Sessions',
                  value: sessionCount.toString(),
                ),
                _buildStatItem(
                  icon: Icons.bolt,
                  label: 'Total Energy',
                  value: '${totalEnergy.toStringAsFixed(1)} kWh',
                ),
                _buildStatItem(
                  icon: Icons.speed,
                  label: 'Avg Consumption',
                  value: avgConsumption != null
                      ? '${avgConsumption.toStringAsFixed(1)} kWh/100km'
                      : '--',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Column(
      children: [
        Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }

  Widget _buildSessionCard(ChargingSession session) {
    final isAC = session.chargingType == 'ac';
    final isDC = session.chargingType == 'dc';
    final typeIcon = isDC ? Icons.flash_on : (isAC ? Icons.power : Icons.ev_station);
    final typeColor = isDC ? Colors.orange : (isAC ? Colors.green : Colors.blue);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: () => _showSessionDetails(session),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                children: [
                  Icon(typeIcon, color: typeColor, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _formatSessionDate(session.startTime),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (session.locationName != null && session.locationName!.isNotEmpty)
                          Text(
                            session.locationName!,
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                      ],
                    ),
                  ),
                  // Charging type badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: typeColor.withAlpha(51),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      isDC ? 'DC Fast' : (isAC ? 'AC' : 'Unknown'),
                      style: TextStyle(fontSize: 12, color: typeColor, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Data row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildDataColumn(
                    'SOC',
                    '${session.startSoc.toStringAsFixed(0)}% → ${session.endSoc?.toStringAsFixed(0) ?? "--"}%',
                  ),
                  _buildDataColumn(
                    'Energy',
                    session.energyAddedKwh != null
                        ? '${session.energyAddedKwh!.toStringAsFixed(1)} kWh'
                        : '${session.energyAddedAh?.toStringAsFixed(1) ?? "--"} Ah',
                  ),
                  _buildDataColumn(
                    'Duration',
                    _formatDuration(session.duration),
                  ),
                  if (session.maxPowerKw != null && session.maxPowerKw! > 0)
                    _buildDataColumn(
                      'Max Power',
                      '${session.maxPowerKw!.toStringAsFixed(0)} kW',
                    ),
                ],
              ),
              // Consumption row (if available)
              if (session.distanceSinceLastCharge != null || session.consumptionKwhPer100km != null) ...[
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (session.distanceSinceLastCharge != null)
                      _buildDataColumn(
                        'Distance',
                        '${session.distanceSinceLastCharge!.toStringAsFixed(0)} km',
                      ),
                    if (session.consumptionKwhPer100km != null)
                      _buildDataColumn(
                        'Consumption',
                        '${session.consumptionKwhPer100km!.toStringAsFixed(1)} kWh/100km',
                      ),
                    if (session.chargingCost != null)
                      _buildDataColumn(
                        'Cost',
                        '\$${session.chargingCost!.toStringAsFixed(2)}',
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDataColumn(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  String _formatSessionDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final sessionDate = DateTime(date.year, date.month, date.day);

    String dateStr;
    if (sessionDate == today) {
      dateStr = 'Today';
    } else if (sessionDate == today.subtract(const Duration(days: 1))) {
      dateStr = 'Yesterday';
    } else {
      dateStr = '${date.day}/${date.month}/${date.year}';
    }

    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$dateStr at $hour:$minute';
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '--';
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  void _showSessionDetails(ChargingSession session) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SessionDetailsSheet(
        session: session,
        onUpdate: (updated) async {
          final manager = ref.read(dataSourceManagerProvider);
          final success = await manager.chargingSessionService.updateSession(updated);
          if (success) {
            _loadData();
          }
          return success;
        },
        onDelete: () async {
          final manager = ref.read(dataSourceManagerProvider);
          final success = await manager.chargingSessionService.deleteSession(session.id);
          if (success) {
            _loadData();
          }
          return success;
        },
      ),
    );
  }
}

/// Bottom sheet for viewing and editing session details
class _SessionDetailsSheet extends StatefulWidget {
  final ChargingSession session;
  final Future<bool> Function(ChargingSession) onUpdate;
  final Future<bool> Function() onDelete;

  const _SessionDetailsSheet({
    required this.session,
    required this.onUpdate,
    required this.onDelete,
  });

  @override
  State<_SessionDetailsSheet> createState() => _SessionDetailsSheetState();
}

class _SessionDetailsSheetState extends State<_SessionDetailsSheet> {
  late TextEditingController _locationController;
  late TextEditingController _costController;
  late TextEditingController _notesController;
  bool _isEditing = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _locationController = TextEditingController(text: widget.session.locationName ?? '');
    _costController = TextEditingController(
      text: widget.session.chargingCost?.toStringAsFixed(2) ?? '',
    );
    _notesController = TextEditingController(text: widget.session.notes ?? '');
  }

  @override
  void dispose() {
    _locationController.dispose();
    _costController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          controller: scrollController,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Title
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Session Details',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    if (!_isEditing)
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => setState(() => _isEditing = true),
                        tooltip: 'Edit',
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: _confirmDelete,
                      tooltip: 'Delete',
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Session info
            _buildInfoRow('Date', _formatFullDate(session.startTime)),
            _buildInfoRow('Type', _getChargingTypeLabel(session.chargingType)),
            _buildInfoRow('SOC', '${session.startSoc.toStringAsFixed(1)}% → ${session.endSoc?.toStringAsFixed(1) ?? "--"}%'),
            if (session.energyAddedKwh != null)
              _buildInfoRow('Energy Added', '${session.energyAddedKwh!.toStringAsFixed(2)} kWh'),
            if (session.energyAddedAh != null)
              _buildInfoRow('Energy Added', '${session.energyAddedAh!.toStringAsFixed(2)} Ah'),
            if (session.duration != null)
              _buildInfoRow('Duration', _formatFullDuration(session.duration!)),
            if (session.maxPowerKw != null && session.maxPowerKw! > 0)
              _buildInfoRow('Max Power', '${session.maxPowerKw!.toStringAsFixed(1)} kW'),
            _buildInfoRow('Odometer', '${session.startOdometer.toStringAsFixed(0)} km'),
            if (session.distanceSinceLastCharge != null)
              _buildInfoRow('Distance Since Last Charge', '${session.distanceSinceLastCharge!.toStringAsFixed(1)} km'),
            if (session.consumptionKwhPer100km != null)
              _buildInfoRow('Consumption', '${session.consumptionKwhPer100km!.toStringAsFixed(1)} kWh/100km'),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
            // Editable fields
            const Text(
              'Additional Info',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _locationController,
              enabled: _isEditing,
              decoration: const InputDecoration(
                labelText: 'Location',
                hintText: 'e.g., Home, Supercharger, etc.',
                prefixIcon: Icon(Icons.location_on),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _costController,
              enabled: _isEditing,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Cost',
                hintText: '0.00',
                prefixIcon: Icon(Icons.attach_money),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              enabled: _isEditing,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Notes',
                hintText: 'Any additional notes...',
                prefixIcon: Icon(Icons.note),
                border: OutlineInputBorder(),
              ),
            ),
            if (_isEditing) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => setState(() => _isEditing = false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _isSaving ? null : _saveChanges,
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey[600])),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  String _formatFullDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatFullDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;
    if (hours > 0) {
      return '$hours h $minutes m';
    }
    return '$minutes m $seconds s';
  }

  String _getChargingTypeLabel(String? type) {
    switch (type) {
      case 'dc':
        return 'DC Fast Charging';
      case 'ac':
        return 'AC Charging';
      default:
        return 'Unknown';
    }
  }

  Future<void> _saveChanges() async {
    setState(() => _isSaving = true);

    final updated = widget.session.copyWith(
      locationName: _locationController.text.isEmpty ? null : _locationController.text,
      chargingCost: double.tryParse(_costController.text),
      notes: _notesController.text.isEmpty ? null : _notesController.text,
    );

    final success = await widget.onUpdate(updated);

    setState(() {
      _isSaving = false;
      if (success) {
        _isEditing = false;
      }
    });

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session updated')),
      );
    }
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Session'),
        content: const Text('Are you sure you want to delete this charging session? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context); // Close dialog
              final success = await widget.onDelete();
              if (success && mounted) {
                if (!context.mounted) return;
                Navigator.pop(context); // Close sheet
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Session deleted')),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
