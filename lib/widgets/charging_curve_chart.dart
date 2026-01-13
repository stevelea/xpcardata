import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../models/charging_sample.dart';

/// Chart display mode
enum ChargingCurveMode {
  socVsTime, // SOC % over time (default)
  powerVsTime, // Power kW over time
  powerVsSoc, // Power kW vs SOC % (charging curve shape)
}

/// Widget to display charging curve data as an interactive line chart
class ChargingCurveChart extends StatefulWidget {
  final List<ChargingSample> samples;
  final String? chargingType; // 'ac' or 'dc' for color coding
  final ChargingCurveMode initialMode;

  const ChargingCurveChart({
    super.key,
    required this.samples,
    this.chargingType,
    this.initialMode = ChargingCurveMode.socVsTime,
  });

  @override
  State<ChargingCurveChart> createState() => _ChargingCurveChartState();
}

class _ChargingCurveChartState extends State<ChargingCurveChart> {
  late ChargingCurveMode _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  Color get _lineColor {
    if (widget.chargingType == 'dc') {
      return Colors.orange;
    } else if (widget.chargingType == 'ac') {
      return Colors.green;
    }
    return Colors.blue;
  }

  Color get _gradientColor => _lineColor.withValues(alpha: 0.3);

  @override
  Widget build(BuildContext context) {
    if (widget.samples.isEmpty) {
      return const Center(
        child: Text('No charging curve data available'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Mode selector
        _buildModeSelector(),
        const SizedBox(height: 12),
        // Chart
        SizedBox(
          height: 200,
          child: _buildChart(),
        ),
      ],
    );
  }

  Widget _buildModeSelector() {
    return SegmentedButton<ChargingCurveMode>(
      segments: const [
        ButtonSegment(
          value: ChargingCurveMode.socVsTime,
          label: Text('SOC'),
          icon: Icon(Icons.battery_charging_full, size: 16),
        ),
        ButtonSegment(
          value: ChargingCurveMode.powerVsTime,
          label: Text('Power'),
          icon: Icon(Icons.bolt, size: 16),
        ),
        ButtonSegment(
          value: ChargingCurveMode.powerVsSoc,
          label: Text('Curve'),
          icon: Icon(Icons.show_chart, size: 16),
        ),
      ],
      selected: {_mode},
      onSelectionChanged: (selected) {
        setState(() {
          _mode = selected.first;
        });
      },
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildChart() {
    final spots = _getSpots();
    if (spots.isEmpty) {
      return const Center(child: Text('Insufficient data'));
    }

    final minX = spots.map((s) => s.x).reduce((a, b) => a < b ? a : b);
    final maxX = spots.map((s) => s.x).reduce((a, b) => a > b ? a : b);
    final minY = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    final maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);

    // Add padding to Y axis
    final yPadding = (maxY - minY) * 0.1;
    final effectiveMinY = (minY - yPadding).clamp(0.0, double.infinity);
    final effectiveMaxY = maxY + yPadding;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          horizontalInterval: _getYInterval(effectiveMinY, effectiveMaxY),
          verticalInterval: _getXInterval(minX, maxX),
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey.withValues(alpha: 0.2),
              strokeWidth: 1,
            );
          },
          getDrawingVerticalLine: (value) {
            return FlLine(
              color: Colors.grey.withValues(alpha: 0.2),
              strokeWidth: 1,
            );
          },
        ),
        titlesData: FlTitlesData(
          show: true,
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            axisNameWidget: Text(
              _getXAxisLabel(),
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: _getXInterval(minX, maxX),
              getTitlesWidget: (value, meta) => _getXTitle(value, minX, maxX),
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: Text(
              _getYAxisLabel(),
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: _getYInterval(effectiveMinY, effectiveMaxY),
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(0),
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
        ),
        minX: minX,
        maxX: maxX,
        minY: effectiveMinY,
        maxY: effectiveMaxY,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (touchedSpot) => Colors.blueGrey.shade800,
            tooltipRoundedRadius: 8,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                return LineTooltipItem(
                  _getTooltipText(spot),
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              }).toList();
            },
          ),
          handleBuiltInTouches: true,
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.3,
            color: _lineColor,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: spots.length <= 20, // Show dots only for fewer points
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 3,
                  color: _lineColor,
                  strokeWidth: 1,
                  strokeColor: Colors.white,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              color: _gradientColor,
            ),
          ),
        ],
      ),
    );
  }

  List<FlSpot> _getSpots() {
    if (widget.samples.isEmpty) return [];

    final startTime = widget.samples.first.timestamp;

    switch (_mode) {
      case ChargingCurveMode.socVsTime:
        return widget.samples.map((s) {
          final minutesElapsed = s.timestamp.difference(startTime).inSeconds / 60.0;
          return FlSpot(minutesElapsed, s.soc);
        }).toList();

      case ChargingCurveMode.powerVsTime:
        return widget.samples.map((s) {
          final minutesElapsed = s.timestamp.difference(startTime).inSeconds / 60.0;
          return FlSpot(minutesElapsed, s.powerKw);
        }).toList();

      case ChargingCurveMode.powerVsSoc:
        return widget.samples.map((s) {
          return FlSpot(s.soc, s.powerKw);
        }).toList();
    }
  }

  String _getXAxisLabel() {
    switch (_mode) {
      case ChargingCurveMode.socVsTime:
      case ChargingCurveMode.powerVsTime:
        return 'Time (min)';
      case ChargingCurveMode.powerVsSoc:
        return 'SOC (%)';
    }
  }

  String _getYAxisLabel() {
    switch (_mode) {
      case ChargingCurveMode.socVsTime:
        return 'SOC (%)';
      case ChargingCurveMode.powerVsTime:
      case ChargingCurveMode.powerVsSoc:
        return 'Power (kW)';
    }
  }

  Widget _getXTitle(double value, double minX, double maxX) {
    switch (_mode) {
      case ChargingCurveMode.socVsTime:
      case ChargingCurveMode.powerVsTime:
        // Show time in minutes
        return Text(
          '${value.toInt()}',
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        );
      case ChargingCurveMode.powerVsSoc:
        // Show SOC %
        return Text(
          '${value.toInt()}%',
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        );
    }
  }

  double _getXInterval(double minX, double maxX) {
    final range = maxX - minX;
    if (range <= 10) return 2;
    if (range <= 30) return 5;
    if (range <= 60) return 10;
    if (range <= 120) return 20;
    return 30;
  }

  double _getYInterval(double minY, double maxY) {
    final range = maxY - minY;
    if (range <= 20) return 5;
    if (range <= 50) return 10;
    if (range <= 100) return 20;
    return 50;
  }

  String _getTooltipText(LineBarSpot spot) {
    final sampleIndex = spot.spotIndex;
    if (sampleIndex >= widget.samples.length) {
      return '${spot.y.toStringAsFixed(1)}';
    }

    final sample = widget.samples[sampleIndex];

    switch (_mode) {
      case ChargingCurveMode.socVsTime:
        return 'SOC: ${sample.soc.toStringAsFixed(1)}%\n'
            'Power: ${sample.powerKw.toStringAsFixed(1)} kW';
      case ChargingCurveMode.powerVsTime:
        return 'Power: ${sample.powerKw.toStringAsFixed(1)} kW\n'
            'SOC: ${sample.soc.toStringAsFixed(1)}%';
      case ChargingCurveMode.powerVsSoc:
        return 'SOC: ${sample.soc.toStringAsFixed(1)}%\n'
            'Power: ${sample.powerKw.toStringAsFixed(1)} kW';
    }
  }
}
