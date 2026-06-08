import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../theme/app_theme.dart';
import 'location_permission.dart';

/// Inline GPS status for session start and check-in flows.
class LocationResolvingPanel extends StatelessWidget {
  const LocationResolvingPanel({
    super.key,
    this.resolving = false,
    this.position,
    this.errorMessage,
    this.locationServiceDisabled = false,
    this.permissionBlocked = false,
    this.onRetry,
    this.compact = false,
  });

  final bool resolving;
  final Position? position;
  final String? errorMessage;
  final bool locationServiceDisabled;
  final bool permissionBlocked;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final hasFix = position != null && !resolving;

    if (locationServiceDisabled) {
      return _LocationCard(
        compact: compact,
        icon: Icons.location_off_rounded,
        iconColor: AppTheme.error,
        title: 'Location is turned off',
        message:
            'Turn on GPS in your device settings so U-Panel can read your current position.',
        actions: [
          FilledButton.icon(
            onPressed: () => openDeviceLocationSettings(),
            icon: const Icon(Icons.settings_rounded, size: 18),
            label: const Text('Turn on location'),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      );
    }

    if (permissionBlocked && errorMessage != null) {
      return _LocationCard(
        compact: compact,
        icon: Icons.location_disabled_rounded,
        iconColor: AppTheme.error,
        title: 'Location permission needed',
        message: errorMessage!,
        actions: [
          FilledButton.icon(
            onPressed: () => openAppPermissionSettings(),
            icon: const Icon(Icons.app_settings_alt_rounded, size: 18),
            label: const Text('Open app settings'),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      );
    }

    if (resolving) {
      return _LocationCard(
        compact: compact,
        icon: Icons.location_searching_rounded,
        iconColor: AppTheme.primary,
        title: 'Resolving your location…',
        message:
            'Getting a fresh GPS fix. Stay in an open area and keep location enabled.',
        trailing: const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    if (errorMessage != null) {
      return _LocationCard(
        compact: compact,
        icon: Icons.error_outline_rounded,
        iconColor: AppTheme.error,
        title: 'Could not read location',
        message: errorMessage!,
        actions: [
          if (onRetry != null)
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry GPS'),
            ),
        ],
      );
    }

    if (hasFix) {
      return _LocationCard(
        compact: compact,
        icon: Icons.location_on_rounded,
        iconColor: AppTheme.primary,
        title: 'Current GPS location',
        message:
            '${position!.latitude.toStringAsFixed(5)}, ${position!.longitude.toStringAsFixed(5)}',
        actions: onRetry != null
            ? [
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Refresh location'),
                ),
              ]
            : null,
      );
    }

    return _LocationCard(
      compact: compact,
      icon: Icons.my_location_rounded,
      iconColor: AppTheme.primary,
      title: 'Location required',
      message:
          'U-Panel uses your current GPS position — not a cached location — for check-in.',
      actions: onRetry != null
          ? [
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.gps_fixed_rounded, size: 18),
                label: const Text('Get current location'),
              ),
            ]
          : null,
    );
  }
}

class _LocationCard extends StatelessWidget {
  const _LocationCard({
    required this.compact,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    this.actions,
    this.trailing,
  });

  final bool compact;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final List<Widget>? actions;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12 : 14),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: iconColor, size: compact ? 20 : 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
          if (actions != null && actions!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions!),
          ],
        ],
      ),
    );
  }
}
