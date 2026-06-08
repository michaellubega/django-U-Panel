import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/location/location_permission.dart';
import '../../core/location/location_resolving_panel.dart';
import '../../core/theme/app_theme.dart';
import 'campus_geofence_validation.dart';
import 'data/campus_presence_repository.dart';
import 'models/campus_presence_models.dart';

/// QA staff: set the shared campus centre for KIU administrator check-in (1.5 km radius).
class UpdateCampusLocationScreen extends StatefulWidget {
  const UpdateCampusLocationScreen({super.key});

  @override
  State<UpdateCampusLocationScreen> createState() =>
      _UpdateCampusLocationScreenState();
}

class _UpdateCampusLocationScreenState extends State<UpdateCampusLocationScreen> {
  CampusGeofence? _geofence;
  bool _loading = true;
  String? _loadError;

  Position? _position;
  String? _locationError;
  bool _resolvingLocation = false;
  bool _locationServiceDisabled = false;
  bool _locationPermissionBlocked = false;

  bool _saving = false;

  static const _radiusMeters = campusGeofenceMinRadiusMeters;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrap());
    });
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await _reloadGeofence();
      if (!mounted) return;
      await _resolveLocation();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _reloadGeofence({bool forceServer = false}) async {
    final fence = await CampusPresenceRepository.instance.fetchCampusGeofence(
      forceServer: forceServer,
    );
    if (!mounted) return;
    setState(() {
      _geofence = fence;
      _loading = false;
    });
  }

  Future<void> _resolveLocation() async {
    setState(() {
      _resolvingLocation = true;
      _locationError = null;
      _locationServiceDisabled = false;
      _locationPermissionBlocked = false;
      _position = null;
    });

    if (!await isDeviceLocationServiceEnabled()) {
      if (!mounted) return;
      setState(() {
        _resolvingLocation = false;
        _locationServiceDisabled = true;
      });
      return;
    }

    final result = await acquireCurrentGpsPosition(
      timeLimit: const Duration(seconds: 30),
    );
    if (!mounted) return;
    setState(() {
      _resolvingLocation = false;
      _position = result.position;
      _locationError = result.errorMessage;
      _locationServiceDisabled = result.locationServiceDisabled;
      _locationPermissionBlocked = result.permissionBlocked;
    });
  }

  Future<void> _save() async {
    if (_saving || _position == null) return;
    if (!AppConnectivity.instance.isOnline) {
      _snack('Connect to the internet to update the campus location.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set campus centre?'),
        content: Text(
          'Your current GPS position will become the campus centre for '
          'KIU administrator check-in, with a fixed '
          '${formatCampusRadiusMeters(_radiusMeters)} radius.\n\n'
          'Confirm you are standing at the centre of campus '
          '(main administration / central campus area), not at the edge '
          'of the grounds.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save campus centre'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    final result = await CampusPresenceRepository.instance.saveCampusGeofence(
      latitude: _position!.latitude,
      longitude: _position!.longitude,
      radiusMeters: _radiusMeters,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    switch (result.outcome) {
      case CampusGeofenceSaveOutcome.success:
        _snack('Campus check-in area updated (${formatCampusRadiusMeters(_radiusMeters)} radius).');
        await _reloadGeofence(forceServer: true);
        return;
      default:
        _snack(result.message ?? 'Could not update campus location.');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthRepository.instance.isQaStaff) {
      return Scaffold(
        appBar: AppBar(title: const Text('Campus check-in area')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Only QA staff can update the campus check-in area.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final fence = _geofence;
    final configured = fence != null && fence.isConfigured;

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: const Text('Campus check-in area'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _bootstrap,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_loadError != null)
                      Text(
                        _loadError!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppTheme.error,
                        ),
                      ),
                    _GuidanceBanner(theme: theme),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Allowed check-in radius',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              formatCampusRadiusMeters(_radiusMeters),
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: AppTheme.primary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'KIU administrators must be within this distance '
                              'of the campus centre when they check in or out.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (configured) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Current campus centre',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${fence.label} · '
                                '${fence.latitude.toStringAsFixed(5)}, '
                                '${fence.longitude.toStringAsFixed(5)}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              if (fence.updatedByName?.isNotEmpty == true) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Last updated by ${fence.updatedByName}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      'Your location (stand at campus centre)',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    LocationResolvingPanel(
                      resolving: _resolvingLocation,
                      position: _position,
                      errorMessage: _locationError,
                      locationServiceDisabled: _locationServiceDisabled,
                      permissionBlocked: _locationPermissionBlocked,
                      onRetry: _resolveLocation,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _saving || _position == null ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.add_location_alt_rounded),
                      label: Text(
                        configured
                            ? 'Update campus centre to my location'
                            : 'Save campus centre from my location',
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _GuidanceBanner extends StatelessWidget {
  const _GuidanceBanner({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.accentLight.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: AppTheme.primary.withValues(alpha: 0.9),
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Go to the centre of campus (main administration / central grounds) '
              'before saving. This point becomes the centre of the '
              '${formatCampusRadiusMeters(campusGeofenceMinRadiusMeters)} check-in '
              'area for all KIU administrators. They must also be within that '
              'area when they check in or out.',
              style: theme.textTheme.bodySmall?.copyWith(
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
