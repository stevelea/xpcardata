import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/google_drive_backup_service.dart';
import '../../services/data_usage_service.dart';
import '../../services/database_service.dart';

/// Data settings sub-screen
/// Includes: Backup & Restore, Data Management, Data Usage
class DataSettingsScreen extends ConsumerStatefulWidget {
  const DataSettingsScreen({super.key});

  @override
  ConsumerState<DataSettingsScreen> createState() => _DataSettingsScreenState();
}

class _DataSettingsScreenState extends ConsumerState<DataSettingsScreen> {
  int _dataRetentionDays = 30;
  bool _backupInProgress = false;
  bool _restoreInProgress = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _initializeBackupService();
  }

  Future<void> _initializeBackupService() async {
    await BackupService.instance.initialize();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _dataRetentionDays = prefs.getInt('data_retention_days') ?? 30;
      });
    } catch (e) {
      debugPrint('Failed to load settings: $e');
    }
  }

  Future<void> _autoSaveInt(String key, int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, value);
    } catch (e) {
      debugPrint('Failed to save $key: $e');
    }
  }

  Future<void> _clearAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Data'),
        content: const Text(
          'Are you sure you want to delete all vehicle data and alerts? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final db = await DatabaseService.instance.database;
        await db.delete('vehicle_data');
        await db.delete('alerts');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('All data cleared successfully')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error clearing data: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  String _formatBackupTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes} minutes ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours} hours ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${time.day}/${time.month}/${time.year}';
    }
  }

  Future<void> _saveBackupToDownloads() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    setState(() => _backupInProgress = true);

    try {
      final savedPath = await BackupService.instance.saveBackupToDownloads();

      if (mounted) {
        setState(() => _backupInProgress = false);

        if (savedPath != null) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text('Backup saved to: $savedPath'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 5),
            ),
          );
        } else {
          final error = BackupService.instance.error;
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(error ?? 'Save failed'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _backupInProgress = false);
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Save error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _copyBackupToClipboard() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    setState(() => _backupInProgress = true);

    try {
      final success = await BackupService.instance.copyBackupToClipboard();

      if (mounted) {
        setState(() => _backupInProgress = false);

        if (success) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(
              content: Text('Backup copied to clipboard! Paste it somewhere safe.'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        } else {
          final error = BackupService.instance.error;
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(error ?? 'Copy failed'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _backupInProgress = false);
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Copy error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _shareBackup() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    setState(() => _backupInProgress = true);

    try {
      final success = await BackupService.instance.shareBackup();

      if (mounted) {
        setState(() => _backupInProgress = false);

        if (success) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(
              content: Text('Backup shared successfully!'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }
        // Don't show error for dismissed shares - user just cancelled
      }
    } catch (e) {
      if (mounted) {
        setState(() => _backupInProgress = false);
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Share error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _restoreBackup() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    // Pick a backup file
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Select XPCarData Backup File',
    );

    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.first.path;
    if (filePath == null) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text('Could not access selected file'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Confirm restore with user
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Backup'),
        content: const Text(
          'This will replace your current settings and charging history with the backed up data. '
          'Are you sure you want to continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _restoreInProgress = true);

    try {
      final success = await BackupService.instance.restoreFromFile(filePath);

      if (mounted) {
        setState(() => _restoreInProgress = false);

        if (success) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(
              content: Text('Backup imported successfully. Please restart the app.'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 5),
            ),
          );
          // Reload settings to show restored values
          await _loadSettings();
        } else {
          final error = BackupService.instance.error;
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(error ?? 'Import failed'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _restoreInProgress = false);
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Import error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildDataUsageItem(String label, int bytes, int requests, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          DataUsageStats.formatBytes(bytes),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          '$requests requests',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Data'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Backup & Restore Section
          _buildSectionHeader('Backup & Restore'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: const Icon(Icons.save_alt, color: Colors.blue),
                    title: const Text('Export & Import'),
                    subtitle: const Text(
                      'Backup your settings and charging history',
                    ),
                  ),
                  if (BackupService.instance.lastBackupTime != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Last export: ${_formatBackupTime(BackupService.instance.lastBackupTime!)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const Divider(),
                  // Export options - Share button (primary)
                  ElevatedButton.icon(
                    onPressed: _backupInProgress ? null : _shareBackup,
                    icon: _backupInProgress
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.share),
                    label: Text(_backupInProgress ? 'Preparing...' : 'Share Backup'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 44),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Secondary export options
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _backupInProgress ? null : _saveBackupToDownloads,
                          icon: const Icon(Icons.download, size: 18),
                          label: const Text('Downloads'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _backupInProgress ? null : _copyBackupToClipboard,
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Clipboard'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Import option
                  OutlinedButton.icon(
                    onPressed: _restoreInProgress ? null : _restoreBackup,
                    icon: _restoreInProgress
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.file_open),
                    label: Text(_restoreInProgress ? 'Importing...' : 'Import from File'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 44),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Backup includes all settings, API keys, and charging history as a JSON file.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Data Management Section
          _buildSectionHeader('Data Management'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.timer),
                    title: const Text('Data Retention Period'),
                    subtitle: Text('$_dataRetentionDays days'),
                  ),
                  Slider(
                    value: _dataRetentionDays.toDouble(),
                    min: 7,
                    max: 365,
                    divisions: 51,
                    label: '$_dataRetentionDays days',
                    onChanged: (value) {
                      setState(() => _dataRetentionDays = value.toInt());
                      _autoSaveInt('data_retention_days', value.toInt());
                    },
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.delete_forever, color: Colors.red),
                    title: const Text('Clear All Data'),
                    subtitle: const Text('Delete all vehicle data and alerts'),
                    onTap: _clearAllData,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Data Usage Section
          _buildSectionHeader('Data Usage'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: StreamBuilder<DataUsageStats>(
                stream: DataUsageService.instance.usageStream,
                builder: (context, snapshot) {
                  final sessionStats = DataUsageService.instance.sessionStats;
                  final totalStats = DataUsageService.instance.totalStats;

                  return Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.access_time),
                        title: const Text('Current Session'),
                        subtitle: Text(
                          'Duration: ${DataUsageStats.formatDuration(sessionStats.sessionDuration)}',
                        ),
                      ),
                      const Divider(),
                      Row(
                        children: [
                          Expanded(
                            child: _buildDataUsageItem(
                              'MQTT',
                              sessionStats.mqttBytesSent,
                              sessionStats.mqttRequestCount,
                              Icons.cloud_upload,
                            ),
                          ),
                          Expanded(
                            child: _buildDataUsageItem(
                              'ABRP',
                              sessionStats.abrpBytesSent,
                              sessionStats.abrpRequestCount,
                              Icons.route,
                            ),
                          ),
                        ],
                      ),
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.data_usage),
                        title: const Text('Session Total'),
                        subtitle: Text(
                          '${DataUsageStats.formatBytes(sessionStats.totalBytesSent)} sent (${sessionStats.totalRequestCount} requests)',
                        ),
                      ),
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.history),
                        title: const Text('All-Time Total'),
                        subtitle: Text(
                          '${DataUsageStats.formatBytes(totalStats.totalBytesSent)} sent (${totalStats.totalRequestCount} requests)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          TextButton.icon(
                            onPressed: () {
                              DataUsageService.instance.resetSession();
                              setState(() {});
                            },
                            icon: const Icon(Icons.refresh),
                            label: const Text('Reset Session'),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Reset All Data Usage'),
                                  content: const Text('This will reset all data usage statistics. Continue?'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: const Text('Reset'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                await DataUsageService.instance.resetAll();
                                setState(() {});
                              }
                            },
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Reset All'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
