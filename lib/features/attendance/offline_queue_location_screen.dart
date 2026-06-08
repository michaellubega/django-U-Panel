import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/connectivity/app_connectivity.dart';
import '../../core/location/location_permission.dart';
import '../../core/location/location_resolving_panel.dart';
import '../../core/theme/app_theme.dart';
import 'data/attendance_offline_sync.dart';
import 'data/pending_retention.dart';
import 'data/pending_session_code_queue.dart';
import 'pending_sessions_screen.dart';

PendingSessionCodeEntry _offlinePendingEntry({
  required String id,
  required String registrationNumber,
  required String rawCode,
  required DateTime capturedAt,
  required double latitude,
  required double longitude,
  required String deviceId,
  required String note,
}) {
  return PendingSessionCodeEntry(
    id: id,
    registrationNumber: registrationNumber.trim().toUpperCase(),
    sessionCodeRaw: rawCode.trim(),
    capturedAt: capturedAt,
    latitude: latitude,
    longitude: longitude,
    deviceId: deviceId.trim(),
    status: PendingSessionCodeStatus.queued,
    note: note,
  );
}

/// Fullscreen pipeline while saving a session-code attempt to the offline
/// pending queue (reuses last-known GPS when captured within 5 minutes).
class OfflineQueueLocationScreen extends StatefulWidget {
  const OfflineQueueLocationScreen({
    super.key,
    required this.id,
    required this.registrationNumber,
    required this.rawCode,
    required this.captureIntentAt,
    required this.deviceId,
  });

  final String id;
  final String registrationNumber;
  final String rawCode;
  final DateTime captureIntentAt;
  final String deviceId;

  @override
  State<OfflineQueueLocationScreen> createState() =>
      _OfflineQueueLocationScreenState();
}

class _OfflineQueueLocationScreenState extends State<OfflineQueueLocationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  String _statusLine = 'Checking location…';
  String? _errorMessage;
  bool _done = false;
  bool _resolving = false;
  bool _locationServiceDisabled = false;
  bool _permissionBlocked = false;
  var _openedPendingList = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _setStage(String line) {
    if (!mounted) return;
    setState(() {
      _statusLine = line;
      _errorMessage = null;
    });
  }

  Future<void> _openPendingListOnce() async {
    if (!mounted || _openedPendingList) return;
    _openedPendingList = true;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const PendingSessionsScreen(),
      ),
    );
  }

  Future<void> _run() async {
    if (!await isDeviceLocationServiceEnabled()) {
      setState(() {
        _locationServiceDisabled = true;
        _statusLine = 'Turn on location to continue';
      });
      return;
    }

    setState(() {
      _resolving = true;
      _locationServiceDisabled = false;
      _permissionBlocked = false;
      _errorMessage = null;
      _statusLine = 'Resolving your current location…';
    });

    final pos = await acquireCurrentGpsPosition(
      timeLimit: const Duration(seconds: 24),
      forceFresh: false,
    );
    if (!mounted) return;

    setState(() => _resolving = false);

    if (pos.locationServiceDisabled) {
      setState(() {
        _locationServiceDisabled = true;
        _statusLine = 'Turn on location to continue';
      });
      return;
    }

    if (pos.position == null) {
      setState(() {
        _errorMessage = pos.errorMessage ??
            'Could not read your current location. Turn on GPS and try again.';
        _permissionBlocked = pos.permissionBlocked;
        _statusLine = 'Location required';
      });
      return;
    }

    _setStage('Saving your check-in for verification…');
    final entryId = widget.id;
    await PendingSessionCodeQueue.enqueue(
      _offlinePendingEntry(
        id: entryId,
        registrationNumber: widget.registrationNumber,
        rawCode: widget.rawCode,
        capturedAt: widget.captureIntentAt,
        latitude: pos.position!.latitude,
        longitude: pos.position!.longitude,
        deviceId: widget.deviceId,
        note:
            'Waiting for session code to appear (up to ${PendingRetention.unverifiedPending.inDays} days). '
            'Your lecturer may start the session offline — it will auto-verify when synced. '
            'No attendance is recorded until verified.',
      ),
    );
    if (!mounted) return;
    final stillOnDevice = (await PendingSessionCodeQueue.loadAll())
        .any((e) => e.id == entryId);
    if (!stillOnDevice) {
      await _openPendingListOnce();
    }
    final online = AppConnectivity.instance.isOnline;
    setState(() {
      _done = true;
      _statusLine = stillOnDevice
          ? (online
              ? 'Saved on this device — will retry upload when stable.'
              : 'Saved as pending — will upload when online.')
          : (online
              ? 'Uploaded to server — will verify as soon as the lecturer session appears (up to ${PendingRetention.unverifiedPending.inDays} days if only your side is recorded).'
              : 'Saved as pending — will verify when online.');
    });
    if (online && stillOnDevice) {
      unawaited(AttendanceOfflineSync.drainAllInOrder());
    }
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Offline check-in')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: _errorMessage != null || _locationServiceDisabled
                ? Column(
                    key: const ValueKey('err'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LocationResolvingPanel(
                        resolving: _resolving,
                        errorMessage: _errorMessage,
                        locationServiceDisabled: _locationServiceDisabled,
                        permissionBlocked: _permissionBlocked,
                        onRetry: _run,
                      ),
                      const SizedBox(height: 28),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Back'),
                      ),
                    ],
                  )
                : Column(
                    key: ValueKey(_done ? 'done' : 'run'),
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FadeTransition(
                        opacity: Tween<double>(begin: 0.55, end: 1.0).animate(
                          CurvedAnimation(
                            parent: _pulse,
                            curve: Curves.easeInOut,
                          ),
                        ),
                        child: Icon(
                          _done
                              ? Icons.check_circle_rounded
                              : Icons.sensors_rounded,
                          size: 72,
                          color: _done ? AppTheme.success : AppTheme.primary,
                        ),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        _statusLine,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      LocationResolvingPanel(
                        resolving: _resolving,
                        locationServiceDisabled: _locationServiceDisabled,
                        onRetry: _run,
                      ),
                      if (!_done && _resolving) ...[
                        const SizedBox(height: 20),
                        const Center(
                          child: SizedBox(
                            width: 36,
                            height: 36,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
