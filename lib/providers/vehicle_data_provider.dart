import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/vehicle_data.dart';
import '../models/alert.dart';
import '../services/database_service.dart';
import '../services/car_info_service.dart';
import '../services/obd_service.dart';
import '../services/data_source_manager.dart';
import 'mqtt_provider.dart';

// ==================== Service Providers ====================

/// CarInfo API service provider
final carInfoServiceProvider = Provider<CarInfoService>((ref) {
  final service = CarInfoService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// OBD service provider
final obdServiceProvider = Provider<OBDService>((ref) {
  final service = OBDService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Data source manager provider (orchestrates all data sources)
final dataSourceManagerProvider = Provider<DataSourceManager>((ref) {
  final carInfoService = ref.watch(carInfoServiceProvider);
  final obdService = ref.watch(obdServiceProvider);
  final mqttService = ref.watch(mqttServiceProvider);

  final manager = DataSourceManager(
    carInfoService: carInfoService,
    obdService: obdService,
    mqttService: mqttService,
  );

  ref.onDispose(() => manager.dispose());
  return manager;
});

// ==================== Vehicle Data Providers ====================

/// Current vehicle data stream from active data source (managed by DataSourceManager)
final vehicleDataStreamProvider = StreamProvider<VehicleData?>((ref) {
  final manager = ref.watch(dataSourceManagerProvider);
  return manager.vehicleDataStream;
});

/// Current data source stream
final currentDataSourceProvider = StreamProvider<DataSource>((ref) {
  final manager = ref.watch(dataSourceManagerProvider);
  return manager.dataSourceStream;
});

/// Latest vehicle data from database
final latestVehicleDataProvider = FutureProvider<VehicleData?>((ref) async {
  return await DatabaseService.instance.getLatestVehicleData();
});

/// Date range for historical data queries
class DateRange {
  final DateTime start;
  final DateTime end;

  DateRange(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DateRange &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => start.hashCode ^ end.hashCode;
}

/// Historical vehicle data provider with date range filter
final historicalDataProvider =
    FutureProvider.family<List<VehicleData>, DateRange>(
  (ref, dateRange) async {
    return await DatabaseService.instance.getVehicleData(
      startTime: dateRange.start,
      endTime: dateRange.end,
    );
  },
);

/// Vehicle data count provider
final vehicleDataCountProvider = FutureProvider<int>((ref) async {
  return await DatabaseService.instance.getVehicleDataCount();
});

// ==================== Alert Providers ====================

/// All alerts provider
final alertsProvider = FutureProvider<List<VehicleAlert>>((ref) async {
  return await DatabaseService.instance.getAlerts();
});

/// Unread alerts only provider
final unreadAlertsProvider = FutureProvider<List<VehicleAlert>>((ref) async {
  return await DatabaseService.instance.getAlerts(unreadOnly: true);
});

/// Unread alerts count provider
final unreadAlertsCountProvider = FutureProvider<int>((ref) async {
  return await DatabaseService.instance.getUnreadAlertsCount();
});

