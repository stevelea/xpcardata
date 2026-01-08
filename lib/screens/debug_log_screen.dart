import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/debug_logger.dart';

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
      final logs = _logger.getLogsAsString();

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
          const SnackBar(
            content: Text('Logs copied to clipboard! Paste in email/messaging app'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
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

  @override
  Widget build(BuildContext context) {
    final logs = _logger.getLogs();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Logs'),
        actions: [
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
            tooltip: 'Download/Share logs',
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
      body: logs.isEmpty
          ? const Center(
              child: Text('No logs yet'),
            )
          : ListView.builder(
              controller: _scrollController,
              itemCount: logs.length,
              itemBuilder: (context, index) {
                final log = logs[index];
                final isError = log.contains('✗') || log.contains('Error');
                final isSuccess = log.contains('✓');

                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  color: index.isEven
                      ? Colors.grey.withOpacity(0.1)
                      : Colors.transparent,
                  child: SelectableText(
                    log,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: isError
                          ? Colors.red
                          : isSuccess
                              ? Colors.green
                              : null,
                    ),
                  ),
                );
              },
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
