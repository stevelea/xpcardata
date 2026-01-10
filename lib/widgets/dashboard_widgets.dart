import 'package:flutter/material.dart';

/// Responsive breakpoints for dashboard layout
class DashboardBreakpoints {
  static const double phone = 600;
  static const double tablet = 900;
  static const double desktop = 1200;

  static bool isPhone(double width) => width < phone;
  static bool isTablet(double width) => width >= phone && width < desktop;
  static bool isDesktop(double width) => width >= desktop;

  /// Get number of columns for metrics grid based on screen width
  static int getMetricColumns(double width) {
    if (width < phone) return 2;
    if (width < tablet) return 3;
    if (width < desktop) return 4;
    return 5;
  }

  /// Get number of columns for primary cards (SOC/Range)
  static int getPrimaryColumns(double width) {
    if (width < phone) return 2;
    return 2; // Always 2 for primary cards
  }
}

/// Large primary metric display (SOC, Range)
class PrimaryMetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String unit;
  final Color? backgroundColor;
  final bool isCompact;

  const PrimaryMetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.unit,
    this.backgroundColor,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleSize = isCompact ? 14.0 : 16.0;
    final valueSize = isCompact ? 42.0 : 56.0;
    final unitSize = isCompact ? 18.0 : 22.0;
    final padding = isCompact ? 16.0 : 24.0;

    return Card(
      elevation: 2,
      color: backgroundColor ?? theme.colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: padding, horizontal: padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: titleSize,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onPrimaryContainer.withAlpha(204),
              ),
            ),
            SizedBox(height: isCompact ? 8 : 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: valueSize,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: TextStyle(
                    fontSize: unitSize,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onPrimaryContainer.withAlpha(179),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Standard metric card for secondary data
class MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String unit;
  final IconData? icon;
  final Color? iconColor;
  final bool isCompact;
  final Widget? trailing; // Optional widget shown in the title row (e.g., priority indicator)

  const MetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.unit,
    this.icon,
    this.iconColor,
    this.isCompact = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleSize = isCompact ? 12.0 : 14.0;
    final valueSize = isCompact ? 20.0 : 24.0;
    final unitSize = isCompact ? 12.0 : 14.0;
    final iconSize = isCompact ? 18.0 : 22.0;
    final padding = isCompact ? 12.0 : 16.0;

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: iconSize,
                    color: iconColor ?? theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: titleSize,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 4),
                  trailing!,
                ],
              ],
            ),
            SizedBox(height: isCompact ? 6 : 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: valueSize,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (unit.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    style: TextStyle(
                      fontSize: unitSize,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Stacked power metrics card showing Voltage, Current, and Power vertically
class PowerMetricCard extends StatelessWidget {
  final String? voltage;
  final String? current;
  final String? power;
  final bool isCompact;

  const PowerMetricCard({
    super.key,
    this.voltage,
    this.current,
    this.power,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleSize = isCompact ? 10.0 : 11.0;
    final valueSize = isCompact ? 14.0 : 16.0;
    final iconSize = isCompact ? 16.0 : 18.0;
    final padding = isCompact ? 10.0 : 12.0;
    final spacing = isCompact ? 4.0 : 6.0;

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with icon
            Row(
              children: [
                Icon(
                  Icons.electric_bolt,
                  size: iconSize,
                  color: Colors.purple,
                ),
                const SizedBox(width: 4),
                Text(
                  'Power',
                  style: TextStyle(
                    fontSize: titleSize + 1,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            SizedBox(height: spacing),
            // Stacked metrics
            _buildMetricRow('V', voltage ?? '--', 'V', valueSize, titleSize, theme),
            SizedBox(height: spacing - 2),
            _buildMetricRow('A', current ?? '--', 'A', valueSize, titleSize, theme),
            SizedBox(height: spacing - 2),
            _buildMetricRow('kW', power ?? '--', 'kW', valueSize, titleSize, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, String value, String unit, double valueSize, double labelSize, ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: labelSize,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: valueSize,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Status indicator for services (MQTT, ABRP, etc.)
class ServiceStatusIndicator extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final bool showLabel;

  const ServiceStatusIndicator({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? activeColor : Colors.grey[400];

    return Tooltip(
      message: '$label: ${isActive ? "Connected" : "Disconnected"}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          // Use white/light background for all states, with colored border when active
          color: isActive ? Colors.white : Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? activeColor : Colors.grey.withAlpha(77),
            width: isActive ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            if (showLabel) ...[
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Data source badge with timestamp
class DataSourceBadge extends StatelessWidget {
  final String sourceName;
  final IconData icon;
  final Color color;
  final String? timestamp;

  const DataSourceBadge({
    super.key,
    required this.sourceName,
    required this.icon,
    required this.color,
    this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withAlpha(26),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withAlpha(77)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Text(
                sourceName,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        if (timestamp != null) ...[
          const SizedBox(width: 12),
          Text(
            timestamp!,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ],
    );
  }
}

/// Responsive grid that adjusts columns based on screen width
class ResponsiveMetricsGrid extends StatelessWidget {
  final List<Widget> children;
  final double spacing;

  const ResponsiveMetricsGrid({
    super.key,
    required this.children,
    this.spacing = 8,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = DashboardBreakpoints.getMetricColumns(constraints.maxWidth);
        final isCompact = DashboardBreakpoints.isPhone(constraints.maxWidth);

        // Calculate aspect ratio based on columns and compactness
        double aspectRatio;
        if (isCompact) {
          aspectRatio = 1.8; // Wider cards on phone
        } else if (columns == 3) {
          aspectRatio = 1.6;
        } else {
          aspectRatio = 1.4; // Taller cards on larger screens
        }

        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: columns,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          childAspectRatio: aspectRatio,
          children: children,
        );
      },
    );
  }
}

/// Section header for dashboard
class DashboardSectionHeader extends StatelessWidget {
  final String title;
  final IconData? icon;

  const DashboardSectionHeader({
    super.key,
    required this.title,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 8),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
          ],
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state widget
class DashboardEmptyState extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;

  const DashboardEmptyState({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = Icons.error_outline,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
