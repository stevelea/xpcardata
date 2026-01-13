import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'settings/connections_settings_screen.dart';
import 'settings/integrations_settings_screen.dart';
import 'settings/vehicle_settings_screen.dart';
import 'settings/data_settings_screen.dart';
import 'settings/app_settings_screen.dart';
import 'settings/about_settings_screen.dart';

/// Main settings hub screen with category tiles
/// Navigates to sub-screens for each settings category
class SettingsHubScreen extends ConsumerWidget {
  const SettingsHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Determine if we're on a tablet (width > 600)
          final isTablet = constraints.maxWidth > 600;
          final crossAxisCount = isTablet ? 3 : 2;
          final aspectRatio = isTablet ? 1.3 : 1.5;
          final padding = isTablet ? 24.0 : 12.0;
          final spacing = isTablet ? 16.0 : 8.0;

          return Padding(
            padding: EdgeInsets.all(padding),
            child: GridView.count(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              childAspectRatio: aspectRatio,
              children: [
                _SettingsTile(
                  icon: Icons.wifi,
                  title: 'Connections',
                  subtitle: 'MQTT, Tailscale, OBD',
                  color: Colors.blue,
                  isTablet: isTablet,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ConnectionsSettingsScreen()),
                  ),
                ),
                _SettingsTile(
                  icon: Icons.extension,
                  title: 'Integrations',
                  subtitle: 'ABRP, Fleet Stats',
                  color: Colors.green,
                  isTablet: isTablet,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const IntegrationsSettingsScreen()),
                  ),
                ),
                _SettingsTile(
                  icon: Icons.directions_car,
                  title: 'Vehicle',
                  subtitle: 'Model, Location',
                  color: Colors.orange,
                  isTablet: isTablet,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const VehicleSettingsScreen()),
                  ),
                ),
                _SettingsTile(
                  icon: Icons.storage,
                  title: 'Data',
                  subtitle: 'Backup, Usage',
                  color: Colors.purple,
                  isTablet: isTablet,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DataSettingsScreen()),
                  ),
                ),
                _SettingsTile(
                  icon: Icons.settings,
                  title: 'App',
                  subtitle: 'Behavior, Alerts, Updates',
                  color: Colors.teal,
                  isTablet: isTablet,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AppSettingsScreen()),
                  ),
                ),
                _SettingsTile(
                  icon: Icons.info,
                  title: 'About',
                  subtitle: 'Version, Debug',
                  color: Colors.grey,
                  isTablet: isTablet,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AboutSettingsScreen()),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  final bool isTablet;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    required this.isTablet,
  });

  @override
  Widget build(BuildContext context) {
    // Scale sizes based on device type
    final iconSize = isTablet ? 28.0 : 24.0;
    final iconPadding = isTablet ? 12.0 : 8.0;
    final contentPadding = isTablet ? 12.0 : 8.0;
    final spacing = isTablet ? 8.0 : 6.0;
    final subtitleFontSize = isTablet ? 11.0 : 10.0;

    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(contentPadding),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: EdgeInsets.all(iconPadding),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: iconSize, color: color),
              ),
              SizedBox(height: spacing),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: subtitleFontSize,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
