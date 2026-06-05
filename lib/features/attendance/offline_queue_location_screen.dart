import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/connectivity/app_connectivity.dart';
import '../../core/location/location_permission.dart';
import '../../core/theme/app_theme.dart';
import 'data/pending_session_code_queue.dart';
import 'pending_sessions_screen.dart';

/// Matches [StudentCheckInProgressScreen] last-known window for provisional queue rows.
const Duration kOfflineQueueLastKnownMaxAge = Duration(hours: 4);

Future<({Position? position, String? errorMessage})> acquirePositionForOfflineQueue({
  bool requireFreshFix = false,
}) async {
  if (!requireFreshFix && !AppConnectivity.instance.isOnline) {
    final ready = await ensureLocationReady();
    if (ready != null) {
      return (position: null, errorMessage: ready);
    }
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) {
      final age = DateTime.now().difference(last.timestamp);
      if (age <= kOfflineQueueLastKnownMaxAge) {
        return (position: last, errorMessage: null);
      }
    }
  }
  return tryAcquireGpsPosition(
    timeLimit: AppConnectivity.instance.isOnline
        ? const Duration(seconds: 12)
        : const Duration(seconds: 24),
  );
}

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

/// Fullscreen pipeline (same feel as [StudentCheckInProgressScreen]) while saving
/// a session-code attempt to the offline pending queue with GPS evidence.
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
  String _statusLine = 'Preparing…';
  String? _errorMessage;
  bool _done = false;
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
    Position? quickLast;
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) {
      final age = DateTime.now().difference(last.timestamp);
      if (age <= kOfflineQueueLastKnownMaxAge) {
        quickLast = last;
      }
    }

    if (quickLast != null) {
      _setStage('Saving your place in line…');
      await PendingSessionCodeQueue.enqueue(
        _offlinePendingEntry(
          id: widget.id,
          registrationNumber: widget.registrationNumber,
          rawCode: widget.rawCode,
          capturedAt: widget.captureIntentAt,
          latitude: quickLast.latitude,
          longitude: quickLast.longitude,
          deviceId: widget.deviceId,
          note: 'Live queue · refining GPS…',
        ),
      );
      if (!mounted) return;
      _setStage('Refining GPS for accurate check-in…');
      await _openPendingListOnce();
    } else {
      _setStage('Resolving your location…');
    }

    final pos = await acquirePositionForOfflineQueue(
      requireFreshFix: quickLast != null,
    );
    if (!mounted) return;

    if (pos.position == null) {
      if (quickLast != null) {
        await PendingSessionCodeQueue.enqueue(
          _offlinePendingEntry(
            id: widget.id,
            registrationNumber: widget.registrationNumber,
            rawCode: widget.rawCode,
            capturedAt: widget.captureIntentAt,
            latitude: quickLast.latitude,
            longitude: quickLast.longitude,
            deviceId: widget.deviceId,
            note:
                'Saved with last known location. Open sky or retry online to refine.',
          ),
        );
        if (!mounted) return;
        if (!_openedPendingList) await _openPendingListOnce();
        setState(() {
          _done = true;
          _statusLine = 'Saved using last known location.';
        });
        await Future<void>.delayed(const Duration(milliseconds: 280));
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _errorMessage = pos.errorMessage ??
            'Offline queue needs your location. Turn on GPS and try again.';
      });
      return;
    }

    await PendingSessionCodeQueue.enqueue(
      _offlinePendingEntry(
        id: widget.id,
        registrationNumber: widget.registrationNumber,
        rawCode: widget.rawCode,
        capturedAt: widget.captureIntentAt,
        latitude: pos.position!.latitude,
        longitude: pos.position!.longitude,
        deviceId: widget.deviceId,
        note: 'Saved offline. Will validate and submit when online.',
      ),
    );
    if (!mounted) return;
    if (!_openedPendingList) await _openPendingListOnce();
    setState(() {
      _done = true;
      _statusLine = 'Saved on this device.';
    });
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
            child: _errorMessage != null
                ? Column(
                    key: const ValueKey('err'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          size: 56, color: AppTheme.error),
                      const SizedBox(height: 20),
                      Text(
                        _errorMessage!,
                        style: theme.textTheme.bodyLarge,
                        textAlign: TextAlign.center,
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
                      if (!_done) ...[
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
