import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/vehicle_data_provider.dart';
import '../../services/mock_data_service.dart';
import '../../services/github_update_service.dart' show appVersion;
import '../../build_info.dart';
import '../debug_log_screen.dart';

/// About settings sub-screen
/// Includes: About, Debug
class AboutSettingsScreen extends ConsumerStatefulWidget {
  const AboutSettingsScreen({super.key});

  @override
  ConsumerState<AboutSettingsScreen> createState() => _AboutSettingsScreenState();
}

class _AboutSettingsScreenState extends ConsumerState<AboutSettingsScreen> {
  String _version = '';
  String _buildDate = '';

  @override
  void initState() {
    super.initState();
    _loadVersionInfo();
  }

  void _loadVersionInfo() {
    setState(() {
      _version = appVersion;
      _buildDate = BuildInfo.buildDateTime;
    });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // About Section
          _buildSectionHeader('About'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info),
                    title: Row(
                      children: [
                        const Text('XPCarData'),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.orange,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'BETA',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: Text(
                      'by Steve Lea\n'
                      'Version $_version\n'
                      'Built: $_buildDate\n'
                      'Battery Monitor for XPENG Vehicles',
                    ),
                  ),
                  const Divider(),
                  const ListTile(
                    leading: Icon(Icons.description),
                    title: Text('Features'),
                    subtitle: Text(
                      'OBD-II • MQTT • ABRP Integration\n'
                      'Charging Session Tracking\n'
                      'OpenChargeMap Location Lookup\n'
                      'Fleet Analytics • Home Assistant',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Support Section
          _buildSectionHeader('Support'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.email),
                  title: const Text('Email Support'),
                  subtitle: const Text('stevelea@gmail.com'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final uri = Uri.parse('mailto:stevelea@gmail.com?subject=XPCarData%20Support');
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri);
                    }
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('GitHub'),
                  subtitle: const Text('Report issues & contribute'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final uri = Uri.parse('https://github.com/stevelea/xpcardata');
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Debug Section
          _buildSectionHeader('Debug'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.bug_report),
                  title: const Text('View Debug Logs'),
                  subtitle: const Text('See diagnostic information'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const DebugLogScreen(),
                      ),
                    );
                  },
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('Mock Data Mode'),
                  subtitle: Text(
                    MockDataService.instance.isEnabled
                        ? 'Using sample vehicle & charging data'
                        : 'Show sample data for testing',
                  ),
                  value: MockDataService.instance.isEnabled,
                  onChanged: (value) async {
                    await MockDataService.instance.setEnabled(value);
                    // Reinitialize data source to switch to/from mock data
                    final manager = ref.read(dataSourceManagerProvider);
                    await manager.initialize();
                    setState(() {});
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            value
                                ? 'Mock data enabled - dashboard shows sample data'
                                : 'Mock data disabled - connect to car for real data',
                          ),
                          backgroundColor: value ? Colors.orange : Colors.grey,
                        ),
                      );
                    }
                  },
                  secondary: Icon(
                    Icons.science,
                    color: MockDataService.instance.isEnabled
                        ? Colors.orange
                        : Colors.grey,
                  ),
                ),
                if (MockDataService.instance.isEnabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      'Dashboard displays sample vehicle data (72% SOC, parked). '
                      'Charging History shows sample sessions with Australian locations. '
                      'Disable to see real data.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.orange,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
