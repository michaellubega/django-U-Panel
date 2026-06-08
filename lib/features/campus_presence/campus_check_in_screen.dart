import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/location/location_permission.dart';
import '../../core/location/location_resolving_panel.dart';
import '../../core/theme/app_theme.dart';
import 'kiu_admin_check_in_records_screen.dart';
import 'campus_geofence_validation.dart';
import 'campus_presence_grouping.dart';
import 'campus_presence_policy.dart';
import 'campus_presence_status_widgets.dart';
import 'data/campus_presence_repository.dart';
import 'data/pending_campus_presence_queue.dart';
import 'models/campus_presence_models.dart';

/// KIU administrators: record arrival on campus or departure when leaving.
class CampusCheckInScreen extends StatefulWidget {
  const CampusCheckInScreen({super.key});

  @override
  State<CampusCheckInScreen> createState() => _CampusCheckInScreenState();
}

class _CampusCheckInScreenState extends State<CampusCheckInScreen> {
  CampusGeofence? _geofence;
  AdminCampusDayStatus? _status;
  bool _loading = true;
  String? _loadError;

  Position? _position;
  String? _locationError;
  bool _resolvingLocation = false;
  bool _locationServiceDisabled = false;
  bool _locationPermissionBlocked = false;

  bool _submitting = false;
  CampusPresenceKind? _submittingKind;
  int _pendingUploadCount = 0;

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
      final uid = AuthRepository.instance.currentFirebaseUid;
      final fence = await CampusPresenceRepository.instance.fetchCampusGeofence();
      final status =
          await CampusPresenceRepository.instance.fetchTodayStatusForCurrentAdmin();
      final pendingCount = uid == null
          ? 0
          : await PendingCampusPresenceQueue.pendingCountForAdmin(uid);
      if (!mounted) return;
      setState(() {
        _geofence = fence;
        _status = status;
        _pendingUploadCount = pendingCount;
        _loading = false;
      });
      await _resolveLocation();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '$e';
        _loading = false;
      });
    }
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

  Future<void> _submit(CampusPresenceKind kind) async {
    if (_submitting) return;
    if (_position == null) {
      _showSnack('Resolve your location first, then try again.');
      return;
    }

    setState(() {
      _submitting = true;
      _submittingKind = kind;
    });

    final result = await CampusPresenceRepository.instance.submitPresence(
      kind: kind,
      latitude: _position!.latitude,
      longitude: _position!.longitude,
    );

    if (!mounted) return;
    setState(() {
      _submitting = false;
      _submittingKind = null;
    });

    switch (result.outcome) {
      case CampusPresenceSubmitOutcome.success:
        _showSnack(kind == CampusPresenceKind.arrival
            ? 'Checked in on campus.'
            : 'Checked out — departure recorded.');
        await _bootstrap();
        return;
      case CampusPresenceSubmitOutcome.queuedOffline:
        _showSnack(
          kind == CampusPresenceKind.arrival
              ? 'Checked in on campus (saved on this device). '
                  'It will upload when you are online.'
              : 'Checked out (saved on this device). '
                  'It will upload when you are online.',
        );
        await _bootstrap();
        return;
      default:
        _showSnack(result.message ?? 'Could not save campus presence.');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthRepository.instance.isKiuAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Campus check-in')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Campus check-in is only for KIU administrators. '
              'QA staff and lecturers do not use this screen.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final status = _status;
    final fence = _geofence;
    final fenceReady = fence != null && fence.isConfigured;

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: const Text('Campus check-in'),
        actions: [
          IconButton(
            tooltip: 'Today\'s log',
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const KiuAdminCheckInRecordsScreen(),
                ),
              );
            },
            icon: const Icon(Icons.history_rounded),
          ),
        ],
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
                    if (!AppConnectivity.instance.isOnline)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _OfflineBanner(
                          pendingUploadCount: _pendingUploadCount,
                        ),
                      ),
                    _StatusCard(
                      status: status,
                      pendingUpload: _pendingUploadCount > 0,
                    ),
                    const SizedBox(height: 16),
                    _CampusAreaPanel(geofence: fence),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.accentLight.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppTheme.primary.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 22,
                            color: AppTheme.primary.withValues(alpha: 0.9),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              fenceReady
                                  ? 'Check in and out only when you are at the centre '
                                      'of campus — within '
                                      '${formatCampusRadiusMeters(campusGeofenceMinRadiusMeters)} '
                                      'of the campus centre set by QA staff.'
                                  : 'The campus centre is not set yet. Ask QA staff to '
                                      'update it from Dashboard → Campus check-in area.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                height: 1.45,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Your location',
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
                    if (_position != null &&
                        fenceReady &&
                        !isPositionWithinCampus(
                          fence,
                          _position!.latitude,
                          _position!.longitude,
                        )) ...[
                      const SizedBox(height: 12),
                      Text(
                        campusDistanceMessage(
                          fence,
                          _position!.latitude,
                          _position!.longitude,
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppTheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _submitting ||
                              !(status?.canCheckIn ?? false) ||
                              _position == null ||
                              !fenceReady
                          ? null
                          : () => _submit(CampusPresenceKind.arrival),
                      icon: _submittingKind == CampusPresenceKind.arrival
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.login_rounded),
                      label: const Text('Check in — arrived on campus'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _submitting ||
                              !(status?.canCheckOut ?? false) ||
                              _position == null ||
                              !fenceReady
                          ? null
                          : () => _submit(CampusPresenceKind.departure),
                      icon: _submittingKind == CampusPresenceKind.departure
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.logout_rounded),
                      label: const Text('Check out — leaving campus'),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      fenceReady
                          ? 'Check in by 8:30 AM (later = Late). Check out before '
                              'midnight on the same day. Before 5:00 PM = left early; '
                              'after 5:30 PM = overwork. Be at the campus centre when '
                              'you tap check in or out.'
                          : 'Set the campus area first (QA staff), then check in when '
                              'you arrive at the centre of campus.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _CampusAreaPanel extends StatelessWidget {
  const _CampusAreaPanel({required this.geofence});

  final CampusGeofence? geofence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = geofence != null && geofence!.isConfigured;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.map_rounded,
                  color: configured ? AppTheme.primary : AppTheme.warning,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Campus check-in area',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (configured) ...[
              Text(
                '${geofence!.label} — centre '
                '${geofence!.latitude.toStringAsFixed(5)}, '
                '${geofence!.longitude.toStringAsFixed(5)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Allowed radius: ${formatCampusRadiusMeters(campusGeofenceMinRadiusMeters)} '
                '(from campus centre)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              if (geofence!.updatedByName?.isNotEmpty == true) ...[
                const SizedBox(height: 4),
                Text(
                  'Centre set by ${geofence!.updatedByName}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ] else
              Text(
                'Not set yet. QA staff can set the campus centre from '
                'Dashboard → Campus check-in area.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.pendingUploadCount});

  final int pendingUploadCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pendingLine = pendingUploadCount > 0
        ? ' $pendingUploadCount campus record(s) waiting to upload.'
        : '';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.cloud_off_rounded, color: AppTheme.warning, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'You are offline. You can still check in or out on campus; '
              'records are saved on this device and upload when internet '
              'returns.$pendingLine',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    this.pendingUpload = false,
  });

  final AdminCampusDayStatus? status;
  final bool pendingUpload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final onCampus = s?.isOnCampus ?? false;
    final failed = s?.failedToCheckOut ?? false;
    final color = failed
        ? AppTheme.error
        : (onCampus ? AppTheme.success : AppTheme.textSecondary);
    final icon = failed
        ? Icons.error_outline_rounded
        : (onCampus ? Icons.place_rounded : Icons.place_outlined);
    final title = failed
        ? 'Failed to check out'
        : (onCampus ? 'On campus' : 'Not on campus');

    StaffDayPresenceRow? row;
    CampusDayPresenceFlags? flags;
    if (s != null && s.events.isNotEmpty) {
      CampusPresenceEvent? arrival;
      CampusPresenceEvent? departure;
      for (final ev in s.events) {
        if (ev.kind == CampusPresenceKind.arrival) arrival ??= ev;
        if (ev.kind == CampusPresenceKind.departure) departure ??= ev;
      }
      final first = s.events.first;
      row = StaffDayPresenceRow(
        adminUid: first.adminUid,
        displayName: first.displayName ?? first.adminUid,
        staffNumber: first.staffNumber,
        localDateKey: s.localDateKey,
        arrival: arrival,
        departure: departure,
      );
      flags = row.flags();
    }

    String? subtitle;
    final last = s?.lastEvent;
    if (last != null) {
      final t = MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(last.capturedAt),
      );
      subtitle = '${last.kind.label} at $t';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 32),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (flags != null) ...[
              if (flags.statusLabels.isNotEmpty) ...[
                const SizedBox(height: 10),
                CampusPresenceStatusChips(flags: flags, compact: true),
              ],
              if (row?.arrival != null) ...[
                const SizedBox(height: 10),
                CampusPresenceHoursLine(flags: flags),
              ],
            ],
            if (pendingUpload) ...[
              const SizedBox(height: 10),
              Text(
                'Waiting to upload — open the app online to sync.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.warning,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
