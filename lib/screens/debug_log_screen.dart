import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/debug_logger.dart';

/// Log filter categories matching service prefixes
enum LogCategory {
  obdService('[OBDService]', 'OBD Service', Icons.bluetooth),
  obdTraffic('[OBD Traffic]', 'OBD Traffic', Icons.swap_horiz),
  obdProxy('[OBDProxy]', 'OBD Proxy', Icons.wifi_tethering),
  mqtt('[MQTT]', 'MQTT', Icons.cloud),
  abrp('[ABRP]', 'ABRP', Icons.route),
  charging('[Charging]', 'Charging', Icons.battery_charging_full),
  background('[Background]', 'Background', Icons.sync),
  carInfo('[CarInfo]', 'Car Info', Icons.info),
  parser('[Parser]', 'Parser', Icons.code),
  dataSource('[DataSource]', 'Data Source', Icons.source),
  bm300('[BM300]', 'BM300 12V', Icons.battery_std),
  other('', 'Other', Icons.more_horiz);

  final String prefix;
  final String displayName;
  final IconData icon;

  const LogCategory(this.prefix, this.displayName, this.icon);

  /// Check if a log line belongs to this category
  bool matches(String log) {
    if (this == LogCategory.other) {
      // "Other" matches anything that doesn't match other categories
      return !LogCategory.values
          .where((c) => c != LogCategory.other && c.prefix.isNotEmpty)
          .any((c) => log.contains(c.prefix));
    }
    return prefix.isNotEmpty && log.contains(prefix);
  }
}

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  final _logger = DebugLogger.instance;
  final _scrollController = ScrollController();
  bool _autoScroll = true;
  int _lastLogCount = 0;
  bool _showFilters = false;

  // Filter state - all enabled by default
  final Map<LogCategory, bool> _filters = {
    for (var cat in LogCategory.values) cat: true,
  };

  @override
  void initState() {
    super.initState();
    _lastLogCount = _logger.getLogs().length;
    // Auto-scroll to bottom when opening
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
    // Start periodic refresh for auto-scroll
    _startAutoRefresh();
  }

  void _startAutoRefresh() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;

      // Always refresh when auto-scroll is enabled
      if (_autoScroll) {
        final currentCount = _logger.getLogs().length;
        final hasNewLogs = currentCount != _lastLogCount;
        _lastLogCount = currentCount;

        setState(() {});

        if (hasNewLogs) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToBottom();
          });
        }
      }
      _startAutoRefresh();
    });
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Get filtered logs based on current filter settings
  List<String> _getFilteredLogs() {
    final allLogs = _logger.getLogs();

    // If all filters are enabled, return all logs
    if (_filters.values.every((v) => v)) {
      return allLogs;
    }

    // Filter logs based on enabled categories
    return allLogs.where((log) {
      for (final category in LogCategory.values) {
        if (category.matches(log)) {
          return _filters[category] ?? true;
        }
      }
      return true; // Show unmatched logs
    }).toList();
  }

  /// Get count of logs per category
  Map<LogCategory, int> _getLogCounts() {
    final allLogs = _logger.getLogs();
    final counts = <LogCategory, int>{};

    for (final category in LogCategory.values) {
      counts[category] = allLogs.where((log) => category.matches(log)).length;
    }

    return counts;
  }

  void _toggleAllFilters(bool value) {
    setState(() {
      for (final category in LogCategory.values) {
        _filters[category] = value;
      }
    });
  }

  Future<void> _confirmClearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Logs'),
        content: const Text('Are you sure you want to delete all logs? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _logger.clear();
      _lastLogCount = 0;
      setState(() {});
    }
  }

  Future<void> _exportLogs() async {
    try {
      // Export filtered logs
      final filteredLogs = _getFilteredLogs();
      final logs = filteredLogs.join('\n');

      if (logs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No logs to export'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Copy to clipboard (most reliable method)
      await Clipboard.setData(ClipboardData(text: logs));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${filteredLogs.length} logs copied to clipboard!'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to copy logs: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildFilterPanel() {
    final counts = _getLogCounts();
    final allEnabled = _filters.values.every((v) => v);
    final noneEnabled = _filters.values.every((v) => !v);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Filter by Service',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: allEnabled ? null : () => _toggleAllFilters(true),
                child: const Text('All'),
              ),
              TextButton(
                onPressed: noneEnabled ? null : () => _toggleAllFilters(false),
                child: const Text('None'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: LogCategory.values.map((category) {
              final count = counts[category] ?? 0;
              final enabled = _filters[category] ?? true;

              return FilterChip(
                avatar: Icon(
                  category.icon,
                  size: 16,
                  color: enabled ? null : Colors.grey,
                ),
                label: Text(
                  '${category.displayName} ($count)',
                  style: TextStyle(
                    fontSize: 12,
                    color: enabled ? null : Colors.grey,
                  ),
                ),
                selected: enabled,
                onSelected: (value) {
                  setState(() {
                    _filters[category] = value;
                  });
                },
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Color? _getLogColor(String log) {
    if (log.contains('Error') || log.contains('error') || log.contains('✗') || log.contains('FAILED')) {
      return Colors.red;
    }
    if (log.contains('✓') || log.contains('success') || log.contains('Connected')) {
      return Colors.green;
    }
    if (log.contains('Warning') || log.contains('warning')) {
      return Colors.orange;
    }
    // Color by category
    if (log.contains('[OBDProxy]')) return Colors.purple.shade300;
    if (log.contains('[OBD Traffic]')) return Colors.cyan.shade300;
    if (log.contains('[MQTT]')) return Colors.blue.shade300;
    if (log.contains('[ABRP]')) return Colors.teal.shade300;
    if (log.contains('[Charging]')) return Colors.orange.shade700;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final filteredLogs = _getFilteredLogs();
    final totalLogs = _logger.getLogs().length;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          filteredLogs.length == totalLogs
              ? 'Debug Logs ($totalLogs)'
              : 'Debug Logs (${filteredLogs.length}/$totalLogs)',
        ),
        actions: [
          // Filter toggle
          IconButton(
            icon: Icon(_showFilters ? Icons.filter_alt : Icons.filter_alt_outlined),
            onPressed: () {
              setState(() {
                _showFilters = !_showFilters;
              });
            },
            tooltip: 'Toggle filters',
          ),
          // Auto-scroll toggle
          IconButton(
            icon: Icon(_autoScroll ? Icons.sync : Icons.sync_disabled),
            onPressed: () {
              setState(() {
                _autoScroll = !_autoScroll;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_autoScroll ? 'Auto-scroll enabled' : 'Auto-scroll disabled'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
          ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _exportLogs,
            tooltip: 'Export filtered logs',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _confirmClearLogs,
            tooltip: 'Clear logs',
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter panel (collapsible)
          if (_showFilters) _buildFilterPanel(),

          // Log list
          Expanded(
            child: filteredLogs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.filter_alt_off, size: 48, color: Colors.grey),
                        const SizedBox(height: 16),
                        Text(
                          totalLogs == 0
                              ? 'No logs yet'
                              : 'No logs match current filters',
                          style: const TextStyle(color: Colors.grey),
                        ),
                        if (totalLogs > 0)
                          TextButton(
                            onPressed: () => _toggleAllFilters(true),
                            child: const Text('Show all logs'),
                          ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: filteredLogs.length,
                    // Use cacheExtent to improve scrolling performance
                    cacheExtent: 500,
                    itemBuilder: (context, index) {
                      final log = filteredLogs[index];
                      final color = _getLogColor(log);

                      // Use simpler Text widget instead of SelectableText for performance
                      return GestureDetector(
                        onLongPress: () {
                          // Copy single log on long press
                          Clipboard.setData(ClipboardData(text: log));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Log copied to clipboard'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          color: index.isEven
                              ? Colors.grey.withOpacity(0.1)
                              : Colors.transparent,
                          child: Text(
                            log,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: color,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        },
        child: const Icon(Icons.arrow_downward),
      ),
    );
  }
}
