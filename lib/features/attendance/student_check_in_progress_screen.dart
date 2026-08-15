import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/connectivity/app_connectivity.dart';
import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/device/device_identity.dart';
import '../../core/location/location_permission.dart';
import '../../core/location/location_resolving_panel.dart';
import '../../core/location/student_location_priming.dart';
import '../../core/offline/pending_offline_coordinator.dart';
import '../../core/theme/app_theme.dart';
import 'check_in_validation.dart';
import 'check_in_outcome.dart';
import 'check_in_rejection.dart';
import 'data/attendance_repository.dart';
import 'models/attendance_models.dart';

/// Returned to the sign-in flow when the automated check-in pipeline finishes.
class StudentCheckInProgressResult {
  const StudentCheckInProgressResult({
    required this.success,
    this.wasQueued = false,
    this.serverVerified = false,
    this.uploadedToServer = false,
    this.listRollStats,
  });

  /// True when a present row exists locally (submitted or queued for upload).
  final bool success;

  /// True when Firestore was unavailable and the row was written to the offline queue.
  final bool wasQueued;

  /// True when the official [attendanceRecords] row was pulled from Firebase.
  final bool serverVerified;

  /// True when check-in attempt evidence exists on RTD or Firestore.
  final bool uploadedToServer;

  /// Attendance % for this class list after server validation (when available).
  final AttendanceRollStats? listRollStats;

  int? get listAttendancePercent {
    final stats = listRollStats;
    if (stats == null || stats.total <= 0) return null;
    return stats.percentRounded;
  }
}

enum _CheckInUiPhase { processing, result, error }

enum _CheckInResultKind { present, pendingSync, offlineRecorded }

/// Animated pipeline: session time, GPS, distance, then Firestore or offline queue.
class StudentCheckInProgressScreen extends StatefulWidget {
  const StudentCheckInProgressScreen({
    super.key,
    required this.session,
    required this.student,
    required this.list,
    this.selectedCourse,
    this.prefetchedPosition,
  });

  final AttendanceSession session;
  final StudentRecord student;
  final AttendanceList list;
  final String? selectedCourse;

  /// When set (e.g. from sign-in tab priming), skips a second GPS read.
  final Position? prefetchedPosition;

  @override
  State<StudentCheckInProgressScreen> createState() =>
      _StudentCheckInProgressScreenState();
}

class _StudentCheckInProgressScreenState extends State<StudentCheckInProgressScreen>
    with TickerProviderStateMixin {
  static const _stageLabels = <String>[
    'Checking session time…',
    'Confirming your location…',
    'Verifying you are at class…',
    'Saving your attendance…',
  ];

  late final AnimationController _pulse;
  late final AnimationController _successController;
  late final Animation<double> _successScale;
  late final Future<String> _deviceIdFuture;

  _CheckInUiPhase _phase = _CheckInUiPhase.processing;
  int _stageIndex = 0;
  String? _errorMessage;
  bool _resolvingLocation = false;
  bool _locationServiceDisabled = false;
  bool _permissionBlocked = false;
  _CheckInResultKind? _resultKind;
  StudentCheckInProgressResult? _pendingResult;
  DateTime? _lastStageAdvancedAt;
  bool _pipelineLikelyOnline = true;
  bool _pipelineRunning = false;

  static const Duration _stageMinGap = Duration(milliseconds: 200);
  /// Resolves the session to validate against, refreshing when the store was
  /// overwritten with a stale closed/expired copy during background sync.
  Future<AttendanceSession?> _resolveSessionForPipeline() async {
    final fromStore = AttendanceStore.sessionById(widget.session.id);
    var candidate = fromStore ?? widget.session;
    if (candidate.isOpenForCheckIn) return candidate;
    if (widget.session.isOpenForCheckIn) return widget.session;

    final refreshed = await AttendanceRepository.instance
        .resolveActiveSessionByCodeForSignIn(widget.session.sessionCode);
    if (refreshed != null && refreshed.isOpenForCheckIn) return refreshed;

    return candidate.isOpenForCheckIn ? candidate : null;
  }

  @override
  void initState() {
    super.initState();
    _deviceIdFuture = DeviceIdentity.resolve();
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
      _runPipeline();
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
    final minGap =
        _pipelineLikelyOnline ? Duration.zero : _stageMinGap;
    final now = DateTime.now();
    if (_lastStageAdvancedAt != null && minGap > Duration.zero) {
      final elapsed = now.difference(_lastStageAdvancedAt!);
      if (elapsed < minGap) {
        await Future<void>.delayed(minGap - elapsed);
        if (!mounted) return;
      }
    }
    _lastStageAdvancedAt = DateTime.now();
    setState(() => _stageIndex = index.clamp(0, _stageLabels.length - 1));
  }

  Future<void> _completeStagesBeforeResult() async {
    if (!mounted) return;
    setState(() => _stageIndex = _stageLabels.length);
    if (!_pipelineLikelyOnline) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _CheckInUiPhase.error;
      _errorMessage = message;
      _resolvingLocation = false;
    });
  }

  Future<void> _showResult({
    required _CheckInResultKind kind,
    required StudentCheckInProgressResult result,
  }) async {
    await _completeStagesBeforeResult();
    if (!mounted) return;
    _successController.reset();
    setState(() {
      _phase = _CheckInUiPhase.result;
      _resultKind = kind;
      _pendingResult = result;
    });
    await _successController.forward();
  }

  void _finish() {
    final result = _pendingResult;
    if (result != null && mounted) {
      Navigator.of(context).pop(result);
    }
  }

  Future<AttendanceRollStats> _resolveListRollStatsAfterVerification({
    bool refreshFromServer = true,
  }) async {
    return AttendanceRepository.instance.listRollStatsAfterVerifiedCheckIn(
      sessionId: widget.session.id,
      studentId: widget.student.id,
      listId: widget.list.id,
      refreshFromServer: refreshFromServer,
    );
  }

  Future<bool> _checkInAttemptUploaded() async {
    final recordId = attendanceRecordIdForSessionStudent(
      widget.session.id,
      widget.student.id,
    );
    return AttendanceRepository.instance.checkInAttemptExistsOnServer(recordId);
  }

  Future<void> _showVerifiedPresentResult({
    bool refreshFromServer = true,
    bool serverVerified = true,
  }) async {
    AttendanceRollStats? stats;
    if (!_pipelineLikelyOnline) {
      stats = await _resolveListRollStatsAfterVerification(
        refreshFromServer: refreshFromServer,
      );
      if (stats.total <= 0 && !refreshFromServer) {
        stats = await _resolveListRollStatsAfterVerification(
          refreshFromServer: true,
        );
      }
    } else {
      unawaited(
        AttendanceRepository.instance.listRollStatsAfterVerifiedCheckIn(
          sessionId: widget.session.id,
          studentId: widget.student.id,
          listId: widget.list.id,
          refreshFromServer: true,
        ),
      );
    }
    await _showResult(
      kind: _CheckInResultKind.present,
      result: StudentCheckInProgressResult(
        success: true,
        wasQueued: false,
        serverVerified: serverVerified,
        uploadedToServer: true,
        listRollStats: stats,
      ),
    );
  }

  Future<({double latitude, double longitude})?> _resolveCoordinates(
    AttendanceSession session, {
    required bool likelyOnline,
  }) async {
    await _advanceToStage(1);
    final highAccuracy = sessionRequiresHighAccuracyGps(session);

    if (session.remoteLearning) {
      setState(() {
        _resolvingLocation = true;
        _locationServiceDisabled = false;
        _permissionBlocked = false;
      });
      final gps = await acquireCurrentGpsPosition(
        timeLimit: const Duration(seconds: 5),
      );
      if (!mounted) return null;
      setState(() => _resolvingLocation = false);
      return (
        latitude: gps.position?.latitude ?? 0,
        longitude: gps.position?.longitude ?? 0,
      );
    }

    if (!await isDeviceLocationServiceEnabled()) {
      setState(() {
        _locationServiceDisabled = true;
        _phase = _CheckInUiPhase.error;
      });
      return null;
    }

    final requiresGeofence = !sessionSkipsLocationCheck(session);
    final maxAge = locationMaxAgeForSession(session);
    Position? recent;
    final prefetched = widget.prefetchedPosition;
    if (prefetched != null && positionCapturedWithin(prefetched, maxAge)) {
      recent = prefetched;
    } else {
      final primed = StudentLocationPriming.instance.lastPosition;
      if (primed != null && positionCapturedWithin(primed, maxAge)) {
        recent = primed;
      }
    }
    if (recent == null) {
      recent = await readRecentKnownPosition(maxAge: maxAge);
    }

    if (recent != null) {
      return (latitude: recent.latitude, longitude: recent.longitude);
    }

    setState(() {
      _resolvingLocation = true;
      _locationServiceDisabled = false;
      _permissionBlocked = false;
    });

    if (StudentLocationPriming.instance.resolving) {
      await StudentLocationPriming.instance.acquireFreshForCheckIn();
      final primed = StudentLocationPriming.instance.lastPosition;
      if (primed != null && positionCapturedWithin(primed, maxAge)) {
        recent = primed;
      }
    }

    if (recent != null) {
      if (mounted) setState(() => _resolvingLocation = false);
      return (latitude: recent.latitude, longitude: recent.longitude);
    }

    final gps = await acquireCurrentGpsPosition(
      timeLimit: requiresGeofence
          ? (likelyOnline
              ? const Duration(seconds: 12)
              : const Duration(seconds: 16))
          : (likelyOnline
              ? const Duration(seconds: 8)
              : const Duration(seconds: 14)),
      reuseMaxAge: maxAge,
      forceFresh: requiresGeofence,
      highAccuracy: highAccuracy,
    );
    if (!mounted) return null;
    setState(() => _resolvingLocation = false);

    if (gps.locationServiceDisabled) {
      setState(() {
        _locationServiceDisabled = true;
        _phase = _CheckInUiPhase.error;
      });
      return null;
    }

    if (gps.position == null) {
      setState(() {
        _errorMessage = gps.errorMessage ??
            'Could not read your current location. Turn on GPS and try again.';
        _permissionBlocked = gps.permissionBlocked;
        _phase = _CheckInUiPhase.error;
      });
      return null;
    }
    final pos = gps.position!;
    return (latitude: pos.latitude, longitude: pos.longitude);
  }

  Future<void> _runPipeline() async {
    if (_pipelineRunning) return;
    _pipelineRunning = true;
    try {
      await _runPipelineBody();
    } finally {
      _pipelineRunning = false;
    }
  }

  Future<void> _runPipelineBody() async {
    final captureIntentAt = DateTime.now();
    final likelyOnline = AppConnectivity.instance.isOnline ||
        AppConnectivity.instance.hasNetworkInterface;
    _pipelineLikelyOnline = likelyOnline;

    setState(() {
      _phase = _CheckInUiPhase.processing;
      _errorMessage = null;
      _resultKind = null;
      _pendingResult = null;
      _stageIndex = 0;
      _lastStageAdvancedAt = null;
      _locationServiceDisabled = false;
      _permissionBlocked = false;
      _resolvingLocation = false;
    });

    AttendanceSession? session =
        widget.session.isOpenForCheckIn ? widget.session : null;
    session ??= await _resolveSessionForPipeline();
    if (!mounted) return;
    if (session == null || !session.isOpenForCheckIn) {
      _showError(
        'This session is no longer active. Ask your lecturer for a new code.',
      );
      return;
    }

    await _advanceToStage(0);
    if (likelyOnline) {
      unawaited(AuthRepository.instance.ensureStudentRegistrationHydrated());
      unawaited(ApiClient.instance.ensureLoaded());
    }
    if (!isTimestampWithinSessionBounds(session, captureIntentAt)) {
      _showError(
        'Check-in is only allowed during the scheduled session window.',
      );
      return;
    }

    final coordsFuture =
        _resolveCoordinates(session, likelyOnline: likelyOnline);
    final coords = await coordsFuture;
    if (!mounted || coords == null) return;

    await _advanceToStage(2);
    final verification = verifyLinkedSessionCheckIn(
      session: session,
      at: captureIntentAt,
      latitude: coords.latitude,
      longitude: coords.longitude,
    );
    if (!verification.passed) {
      _showError(
        verification.failureMessage ??
            'Check-in could not be verified for this session.',
      );
      return;
    }
    if (!mounted) return;

    final installDeviceId = await _deviceIdFuture;
    if (!mounted) return;
    if (installDeviceId.trim().isEmpty) {
      _showError(
        'Could not identify this device. Attendance cannot be saved.',
      );
      return;
    }
    if (AttendanceStore.hasPresentCheckInForDevice(
          session.id,
          installDeviceId,
          widget.student.id,
        ) ||
        await AttendanceRepository.instance.isDeviceBlockedForStudentSession(
          sessionId: session.id,
          studentId: widget.student.id,
          deviceId: installDeviceId,
          sessionCodeRaw: session.sessionCode,
        )) {
      _showError(
        userMessageForCheckInOutcome(StudentOfflineCheckInOutcome.deviceBlocked),
      );
      return;
    }
    if (AttendanceStore.isPresentForSession(session.id, widget.student.id)) {
      final row = AttendanceStore.attendanceRecordForSessionStudent(
        session.id,
        widget.student.id,
      );
      if (row?.verified == true) {
        await _showVerifiedPresentResult();
        return;
      }
    }

    await _advanceToStage(3);

    if (likelyOnline) {
      unawaited(
        AppConnectivity.instance.ensureReachable(
          timeout: const Duration(seconds: 2),
        ),
      );
    }

    final explicitCourse = widget.selectedCourse?.trim() ?? '';
    final course = explicitCourse.isNotEmpty
        ? explicitCourse
        : resolveCourseForStudentCheckIn(widget.list, widget.student.id);
    final record = AttendanceRecord(
      id: attendanceRecordIdForSessionStudent(session.id, widget.student.id),
      sessionId: session.id,
      studentId: widget.student.id,
      course: course,
      timestamp: captureIntentAt,
      latitude: coords.latitude,
      longitude: coords.longitude,
      verified: false,
      present: true,
      deviceId: installDeviceId,
    );

    final outcome = await AttendanceRepository.instance
        .submitStudentCheckInWithOfflineSupport(
      record,
      listIdOverride: widget.list.id,
      sessionCodeRaw: session.sessionCode,
    );
    if (AppConnectivity.instance.hasNetworkInterface) {
      PendingOfflineCoordinator.instance.requestCheckInSync();
    }
    if (!mounted) return;

    switch (outcome) {
      case StudentOfflineCheckInOutcome.deviceBlocked:
        if (await AttendanceRepository.instance
                .isCheckInAttemptAcceptedForSessionStudent(
              sessionId: session.id,
              studentId: widget.student.id,
            ) ||
            AttendanceStore.isPresentForSession(session.id, widget.student.id)) {
          await _showResult(
            kind: _CheckInResultKind.pendingSync,
            result: StudentCheckInProgressResult(
              success: true,
              wasQueued: false,
              serverVerified: false,
              uploadedToServer: await _checkInAttemptUploaded(),
            ),
          );
          return;
        }
        _showError(userMessageForCheckInOutcome(outcome));
        return;
      case StudentOfflineCheckInOutcome.sessionMismatch:
      case StudentOfflineCheckInOutcome.rejectedVerification:
        final reason = await AttendanceRepository.instance
            .fetchCheckInAttemptRejectionReasonWithRetry(record.id);
        if (!mounted) return;
        var resolved = outcome;
        if (resolved == StudentOfflineCheckInOutcome.rejectedVerification &&
            reason != null) {
          resolved = outcomeFromRejectionReason(reason);
        }
        if (resolved == StudentOfflineCheckInOutcome.rejectedVerification &&
            await AttendanceRepository.instance.isDeviceBlockedForStudentSession(
              sessionId: session.id,
              studentId: widget.student.id,
              deviceId: installDeviceId,
              sessionCodeRaw: session.sessionCode,
            )) {
          resolved = StudentOfflineCheckInOutcome.deviceBlocked;
        }
        _showError(
          userMessageForCheckInOutcome(
            resolved,
            rejectionReason: reason,
          ),
        );
        return;
      case StudentOfflineCheckInOutcome.duplicate:
        _showError(userMessageForCheckInOutcome(outcome));
        return;
      case StudentOfflineCheckInOutcome.success:
        await _showVerifiedPresentResult(
          refreshFromServer: false,
          serverVerified: true,
        );
        return;
      case StudentOfflineCheckInOutcome.submittedPendingVerification:
        if (_pipelineLikelyOnline) {
          await _showVerifiedPresentResult(
            refreshFromServer: false,
            serverVerified: false,
          );
          unawaited(
            AttendanceRepository.instance.awaitCheckInVerificationAfterUpload(
              sessionId: session.id,
              studentId: widget.student.id,
              sessionCodeRaw: session.sessionCode,
            ),
          );
          return;
        }
        final verified = await AttendanceRepository.instance
            .awaitCheckInVerificationAfterUpload(
          sessionId: session.id,
          studentId: widget.student.id,
          sessionCodeRaw: session.sessionCode,
          timeout: const Duration(seconds: 2),
        );
        if (!mounted) return;
        if (verified) {
          await _showVerifiedPresentResult(
            refreshFromServer: false,
            serverVerified: true,
          );
          return;
        }
        await _showResult(
          kind: _CheckInResultKind.pendingSync,
          result: StudentCheckInProgressResult(
            success: true,
            wasQueued: false,
            serverVerified: false,
            uploadedToServer: await _checkInAttemptUploaded(),
          ),
        );
        return;
      case StudentOfflineCheckInOutcome.queuedOffline:
        await _showResult(
          kind: _CheckInResultKind.offlineRecorded,
          result: const StudentCheckInProgressResult(
            success: true,
            wasQueued: true,
          ),
        );
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listLabel =
        '${widget.list.whoTaught} · ${widget.list.room}'.trim();
    if (_phase == _CheckInUiPhase.processing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus?.unfocus();
      });
    }
    return PopScope(
      canPop: _phase != _CheckInUiPhase.processing,
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            title: const Text('Check-in'),
            automaticallyImplyLeading: _phase != _CheckInUiPhase.processing,
            bottom: listLabel.isEmpty
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(22),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Text(
                        listLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 360),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, _) =>
                      current ?? const SizedBox.shrink(),
                  child: SizedBox(
                    key: ValueKey(_phase),
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: switch (_phase) {
                      _CheckInUiPhase.processing => _buildProcessing(
                          key: const ValueKey('processing'),
                          theme: theme,
                        ),
                      _CheckInUiPhase.result => _buildResult(
                          key: const ValueKey('result'),
                          theme: theme,
                        ),
                      _CheckInUiPhase.error => _buildError(
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
                'Checking you in',
                textAlign: TextAlign.center,
                style: (ultraCompact
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.titleLarge)
                    ?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Session ${widget.session.sessionCode}',
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
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: progress),
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) {
                    return LinearProgressIndicator(
                      minHeight: 6,
                      value: value,
                      backgroundColor: AppTheme.softGrey,
                      color: AppTheme.primary,
                    );
                  },
                ),
              ),
              SizedBox(height: ultraCompact ? 12 : (compact ? 14 : 22)),
              _CheckInStageList(
                labels: _stageLabels,
                activeIndex: _stageIndex,
                compact: compact || ultraCompact,
                suppressActiveSpinner: _resolvingLocation,
              ),
              if (_resolvingLocation) ...[
                SizedBox(height: ultraCompact ? 8 : (compact ? 12 : 18)),
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
                    onRetry: _runPipeline,
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
    final kind = _resultKind ?? _CheckInResultKind.present;
    final studentName = widget.student.name.trim();
    final sessionCode = widget.session.sessionCode.trim();
    final rollStats = _pendingResult?.listRollStats;
    final attendancePercent = _pendingResult?.listAttendancePercent;
    final listLabel = widget.list.displayTitle.trim().isNotEmpty
        ? widget.list.displayTitle.trim()
        : '${widget.list.whoTaught} · ${widget.list.room}'.trim();
    final (title, subtitle, icon, color) = switch (kind) {
      _CheckInResultKind.present => (
          'You\'re present',
          studentName.isEmpty
              ? 'Your attendance for session $sessionCode has been recorded.'
              : '$studentName — you are marked present for session $sessionCode.',
          Icons.check_rounded,
          AppTheme.success,
        ),
      _CheckInResultKind.pendingSync => (
          'Check-in submitted',
          _pipelineLikelyOnline
              ? 'Session $sessionCode was sent. The official record will appear '
                  'when the connection stabilizes — you can leave this screen.'
              : 'Session $sessionCode is saved locally and will sync when '
                  'you\'re back online. You can leave this screen.',
          Icons.cloud_sync_rounded,
          AppTheme.primary,
        ),
      _CheckInResultKind.offlineRecorded => (
          'Saved on this device',
          'Session $sessionCode is recorded on this phone. '
              'Attendance will verify automatically when you\'re online (up to 7 days).',
          Icons.offline_pin_rounded,
          AppTheme.warning,
        ),
    };

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
                        title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary,
                          height: 1.45,
                        ),
                      ),
                      if (_pendingResult?.uploadedToServer == true) ...[
                        const SizedBox(height: 14),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.check_circle_rounded,
                              size: 20,
                              color: AppTheme.success,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Check-in attempt uploaded',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: AppTheme.success,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (kind == _CheckInResultKind.present &&
                          !_pipelineLikelyOnline &&
                          attendancePercent != null &&
                          rollStats != null) ...[
                        const SizedBox(height: 22),
                        _CheckInAttendancePercentCard(
                          percent: attendancePercent,
                          present: rollStats.present,
                          total: rollStats.total,
                          listLabel: listLabel,
                        ),
                      ],
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _finish,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                          ),
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
                  if (_resolvingLocation || _locationServiceDisabled)
                    LocationResolvingPanel(
                      resolving: _resolvingLocation,
                      locationServiceDisabled: _locationServiceDisabled,
                      permissionBlocked: _permissionBlocked,
                      errorMessage: _errorMessage,
                      onRetry: _runPipeline,
                    )
                  else ...[
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 56,
                      color: AppTheme.error,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _errorMessage ?? 'Check-in could not be completed.',
                      style: theme.textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pop<StudentCheckInProgressResult>(null),
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

class _CheckInStageList extends StatelessWidget {
  const _CheckInStageList({
    required this.labels,
    required this.activeIndex,
    this.compact = false,
    this.suppressActiveSpinner = false,
  });

  final List<String> labels;
  final int activeIndex;
  final bool compact;
  final bool suppressActiveSpinner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gap = compact ? 6.0 : 10.0;
    return Column(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            child: _CheckInStageRow(
              key: ValueKey('$i-${i < activeIndex}-${i == activeIndex}'),
              label: labels[i],
              state: i < activeIndex || activeIndex >= labels.length
                  ? _StageRowState.done
                  : i == activeIndex
                      ? _StageRowState.active
                      : _StageRowState.pending,
              theme: theme,
              suppressActiveSpinner: suppressActiveSpinner,
            ),
          ),
        ],
      ],
    );
  }
}

enum _StageRowState { pending, active, done }

class _CheckInStageRow extends StatelessWidget {
  const _CheckInStageRow({
    super.key,
    required this.label,
    required this.state,
    required this.theme,
    this.suppressActiveSpinner = false,
  });

  final String label;
  final _StageRowState state;
  final ThemeData theme;
  final bool suppressActiveSpinner;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      _StageRowState.done => (Icons.check_circle_rounded, AppTheme.success),
      _StageRowState.active => (Icons.radio_button_checked_rounded, AppTheme.primary),
      _StageRowState.pending => (Icons.radio_button_unchecked_rounded, AppTheme.textSecondary),
    };

    return Row(
      children: [
        if (state == _StageRowState.active && !suppressActiveSpinner)
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppTheme.primary,
            ),
          )
        else if (state == _StageRowState.active && suppressActiveSpinner)
          Icon(Icons.location_searching_rounded, size: 22, color: AppTheme.primary)
        else
          Icon(icon, size: 22, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: state == _StageRowState.pending
                  ? AppTheme.textSecondary
                  : AppTheme.textPrimary,
              fontWeight: state == _StageRowState.active
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

Color _attendancePercentColor(int percent) {
  final t = percent.clamp(0, 100) / 100.0;
  return HSVColor.fromAHSV(1.0, t * 120.0, 0.82, 0.94).toColor();
}

class _CheckInAttendancePercentCard extends StatelessWidget {
  const _CheckInAttendancePercentCard({
    required this.percent,
    required this.present,
    required this.total,
    required this.listLabel,
  });

  final int percent;
  final int present;
  final int total;
  final String listLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _attendancePercentColor(percent);
    final classLabel = listLabel.isEmpty ? 'this class' : listLabel;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.14)),
      ),
      child: Column(
        children: [
          Text(
            'Your attendance',
            style: theme.textTheme.labelLarge?.copyWith(
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          if (classLabel.isNotEmpty) ...[
            Text(
              classLabel,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            '$percent%',
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$present of $total sessions',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
