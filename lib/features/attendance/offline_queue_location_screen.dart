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

enum _OfflineQueuePhase { processing, result, error }

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
    with TickerProviderStateMixin {
  static const _stageLabels = <String>[
    'Confirming your location…',
    'Saving check-in on this device…',
    'Preparing verification…',
  ];

  late final AnimationController _pulse;
  late final AnimationController _successController;
  late final Animation<double> _successScale;

  _OfflineQueuePhase _phase = _OfflineQueuePhase.processing;
  int _stageIndex = 0;
  String? _errorMessage;
  bool _resolving = false;
  bool _locationServiceDisabled = false;
  bool _permissionBlocked = false;
  var _openedPendingList = false;
  String? _resultTitle;
  String? _resultSubtitle;
  bool _uploadedToServer = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _successScale = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _successController, curve: Curves.elasticOut),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
      _run();
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _successController.dispose();
    super.dispose();
  }

  Future<void> _advanceToStage(int index) async {
    if (!mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() => _stageIndex = index.clamp(0, _stageLabels.length - 1));
  }

  Future<void> _showResult({
    required String title,
    required String subtitle,
    required bool uploaded,
  }) async {
    if (!mounted) return;
    setState(() => _stageIndex = _stageLabels.length);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    _successController.reset();
    setState(() {
      _phase = _OfflineQueuePhase.result;
      _resultTitle = title;
      _resultSubtitle = subtitle;
      _uploadedToServer = uploaded;
    });
    await _successController.forward();
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _OfflineQueuePhase.error;
      _errorMessage = message;
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
    setState(() {
      _phase = _OfflineQueuePhase.processing;
      _stageIndex = 0;
      _errorMessage = null;
    });

    if (!await isDeviceLocationServiceEnabled()) {
      setState(() {
        _locationServiceDisabled = true;
        _phase = _OfflineQueuePhase.error;
      });
      return;
    }

    await _advanceToStage(0);
    setState(() {
      _resolving = true;
      _locationServiceDisabled = false;
      _permissionBlocked = false;
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
        _phase = _OfflineQueuePhase.error;
      });
      return;
    }

    if (pos.position == null) {
      _showError(
        pos.errorMessage ??
            'Could not read your current location. Turn on GPS and try again.',
      );
      setState(() => _permissionBlocked = pos.permissionBlocked);
      return;
    }

    await _advanceToStage(1);
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

    await _advanceToStage(2);
    final allAfterEnqueue = await PendingSessionCodeQueue.loadAll();
    final stillOnDevice = allAfterEnqueue.any((e) => e.id == entryId);
    if (!stillOnDevice) {
      await _openPendingListOnce();
    }
    final online = AppConnectivity.instance.isOnline;
    if (online && stillOnDevice) {
      unawaited(AttendanceOfflineSync.drainAllInOrder());
    }

    final code = widget.rawCode.trim();
    if (stillOnDevice) {
      await _showResult(
        title: 'Recorded on this device',
        subtitle: online
            ? 'Check-in for session $code is saved on this phone. '
                'It will upload and verify when the connection is stable (up to ${PendingRetention.unverifiedPending.inDays} days).'
            : 'Check-in for session $code is saved on this phone. '
                'It will verify automatically when you\'re back online (up to ${PendingRetention.unverifiedPending.inDays} days).',
        uploaded: false,
      );
    } else {
      await _showResult(
        title: online ? 'Submitted for verification' : 'Recorded on this device',
        subtitle: online
            ? 'Check-in for session $code was sent to the server. '
                'You will be marked present once verification completes (up to ${PendingRetention.unverifiedPending.inDays} days).'
            : 'Check-in for session $code is saved on this phone. '
                'It will verify when you\'re back online.',
        uploaded: online,
      );
    }
  }

  void _finish() {
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_phase == _OfflineQueuePhase.processing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus?.unfocus();
      });
    }
    return PopScope(
      canPop: _phase != _OfflineQueuePhase.processing,
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            title: const Text('Offline check-in'),
            automaticallyImplyLeading: _phase != _OfflineQueuePhase.processing,
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 360),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
                  child: SizedBox(
                    key: ValueKey(_phase),
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: switch (_phase) {
                      _OfflineQueuePhase.processing => _buildProcessing(
                          key: const ValueKey('processing'),
                          theme: theme,
                        ),
                      _OfflineQueuePhase.result => _buildResult(
                          key: const ValueKey('result'),
                          theme: theme,
                        ),
                      _OfflineQueuePhase.error => _buildError(
                          key: const ValueKey('error'),
                          theme: theme,
                        ),
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessing({required Key key, required ThemeData theme}) {
    final progress = _stageIndex >= _stageLabels.length
        ? 1.0
        : (_stageIndex + 1) / _stageLabels.length;
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        final ultraCompact = constraints.maxHeight < 280;
        final compact = constraints.maxHeight < 520;
        final pad = ultraCompact ? 12.0 : (compact ? 16.0 : 24.0);
        final iconSize = ultraCompact ? 44.0 : (compact ? 56.0 : 72.0);
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(pad),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FadeTransition(
                opacity: Tween<double>(begin: 0.55, end: 1.0).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                ),
                child: Icon(
                  Icons.sensors_rounded,
                  size: iconSize,
                  color: AppTheme.primary,
                ),
              ),
              SizedBox(height: ultraCompact ? 10 : (compact ? 16 : 24)),
              Text(
                'Saving your check-in',
                textAlign: TextAlign.center,
                style: (ultraCompact
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.titleLarge)
                    ?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: ultraCompact ? 4 : 8),
              Text(
                'Session ${widget.rawCode.trim()}',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
              SizedBox(height: ultraCompact ? 10 : (compact ? 16 : 28)),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: progress,
                  backgroundColor: AppTheme.softGrey,
                  color: AppTheme.primary,
                ),
              ),
              SizedBox(height: ultraCompact ? 12 : 22),
              for (var i = 0; i < _stageLabels.length; i++) ...[
                if (i > 0) SizedBox(height: ultraCompact ? 6 : 10),
                Row(
                  children: [
                    if (i < _stageIndex || _stageIndex >= _stageLabels.length)
                      Icon(
                        Icons.check_circle_rounded,
                        size: ultraCompact ? 18 : 22,
                        color: AppTheme.success,
                      )
                    else if (i == _stageIndex)
                      SizedBox(
                        width: ultraCompact ? 18 : 22,
                        height: ultraCompact ? 18 : 22,
                        child: const CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    else
                      Icon(
                        Icons.radio_button_unchecked_rounded,
                        size: ultraCompact ? 18 : 22,
                        color: AppTheme.textSecondary,
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _stageLabels[i],
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: ultraCompact ? 13 : null,
                          fontWeight: i == _stageIndex
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: i > _stageIndex &&
                                  _stageIndex < _stageLabels.length
                              ? AppTheme.textSecondary
                              : AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_resolving) ...[
                SizedBox(height: ultraCompact ? 8 : 18),
                if (ultraCompact)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Getting GPS…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  )
                else
                  LocationResolvingPanel(
                    resolving: true,
                    locationServiceDisabled: _locationServiceDisabled,
                    onRetry: _run,
                    compact: true,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildResult({required Key key, required ThemeData theme}) {
    final color = _uploadedToServer ? AppTheme.primary : AppTheme.warning;
    final icon = _uploadedToServer
        ? Icons.cloud_done_rounded
        : Icons.offline_pin_rounded;
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight,
              maxWidth: 420,
            ),
            child: Align(
              alignment: Alignment.center,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ScaleTransition(
                        scale: _successScale,
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, size: 44, color: color),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        _resultTitle ?? 'Saved',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _resultSubtitle ?? '',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _finish,
                          child: const Text('Done'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildError({required Key key, required ThemeData theme}) {
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        final minBodyHeight =
            (constraints.maxHeight - 48).clamp(0.0, double.infinity);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minBodyHeight),
            child: Align(
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LocationResolvingPanel(
                    resolving: _resolving,
                    errorMessage: _errorMessage,
                    locationServiceDisabled: _locationServiceDisabled,
                    permissionBlocked: _permissionBlocked,
                    onRetry: _run,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Back'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
