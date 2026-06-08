import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/connectivity/app_connectivity.dart';
import '../../core/device/device_identity.dart';
import '../../core/location/location_permission.dart';
import '../../core/location/location_resolving_panel.dart';
import '../../core/location/student_location_priming.dart';
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
  });

  /// True when a present row exists locally (submitted or queued for upload).
  final bool success;

  /// True when Firestore was unavailable and the row was written to the offline queue.
  final bool wasQueued;

  /// True when the official [attendanceRecords] row was pulled from Firebase.
  final bool serverVerified;
}

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
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Future<String> _deviceIdFuture;
  String _statusLine = 'Preparing…';
  String? _errorMessage;
  bool _done = false;
  bool _resolvingLocation = false;
  bool _locationServiceDisabled = false;
  bool _permissionBlocked = false;

  static const Duration _linkedSessionLocationMaxAge = Duration(minutes: 8);

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _runPipeline());
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

  Future<({double latitude, double longitude})?> _resolveCoordinates(
    AttendanceSession session, {
    required bool likelyOnline,
  }) async {
    if (session.remoteLearning) {
      setState(() {
        _resolvingLocation = true;
        _locationServiceDisabled = false;
        _permissionBlocked = false;
      });
      _setStage('Confirming location…');
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
        _statusLine = 'Turn on location to check in';
      });
      return null;
    }

    Position? recent;
    final maxAge = _linkedSessionLocationMaxAge;
    final prefetched = widget.prefetchedPosition;
    if (prefetched != null && positionCapturedWithin(prefetched, maxAge)) {
      recent = prefetched;
    } else {
      final primed = StudentLocationPriming.instance.lastPosition;
      if (primed != null && positionCapturedWithin(primed, maxAge)) {
        recent = primed;
      }
    }
    recent ??= await readRecentKnownPosition(maxAge: maxAge);

    if (recent != null) {
      return (latitude: recent.latitude, longitude: recent.longitude);
    }

    setState(() {
      _resolvingLocation = true;
      _locationServiceDisabled = false;
      _permissionBlocked = false;
    });
    _setStage('Confirming your location…');

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
      timeLimit:
          likelyOnline ? const Duration(seconds: 8) : const Duration(seconds: 14),
      reuseMaxAge: maxAge,
      forceFresh: false,
    );
    if (!mounted) return null;
    setState(() => _resolvingLocation = false);

    if (gps.locationServiceDisabled) {
      setState(() {
        _locationServiceDisabled = true;
        _statusLine = 'Turn on location to check in';
      });
      return null;
    }

    if (gps.position == null) {
      setState(() {
        _errorMessage = gps.errorMessage ??
            'Could not read your current location. Turn on GPS and try again.';
        _permissionBlocked = gps.permissionBlocked;
      });
      return null;
    }
    final pos = gps.position!;
    return (latitude: pos.latitude, longitude: pos.longitude);
  }

  Future<void> _runPipeline() async {
    final captureIntentAt = DateTime.now();
    final likelyOnline = AppConnectivity.instance.isOnline ||
        AppConnectivity.instance.hasNetworkInterface;

    AttendanceSession? session =
        widget.session.isOpenForCheckIn ? widget.session : null;
    session ??= await _resolveSessionForPipeline();
    if (!mounted) return;
    if (session == null || !session.isOpenForCheckIn) {
      setState(() {
        _errorMessage =
            'This session is no longer active. Ask your lecturer for a new code.';
      });
      return;
    }

    final coordsFuture =
        _resolveCoordinates(session, likelyOnline: likelyOnline);

    _setStage('Checking session time…');
    if (!isTimestampWithinSessionBounds(session, captureIntentAt)) {
      setState(() {
        _errorMessage =
            'Check-in is only allowed during the scheduled session window.';
      });
      return;
    }

    final coords = await coordsFuture;
    if (!mounted || coords == null) return;

    _setStage('Checking your location…');
    final verification = verifyLinkedSessionCheckIn(
      session: session,
      at: captureIntentAt,
      latitude: coords.latitude,
      longitude: coords.longitude,
    );
    if (!verification.passed) {
      setState(() {
        _errorMessage = verification.failureMessage ??
            'Check-in could not be verified for this session.';
      });
      return;
    }
    if (!mounted) return;

    final installDeviceId = await _deviceIdFuture;
    if (!mounted) return;
    if (installDeviceId.trim().isEmpty) {
      setState(() {
        _errorMessage =
            'Could not identify this device. Attendance cannot be saved.';
      });
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
      setState(() {
        _errorMessage = userMessageForCheckInOutcome(
          StudentOfflineCheckInOutcome.deviceBlocked,
        );
      });
      return;
    }
    if (AttendanceStore.isPresentForSession(session.id, widget.student.id)) {
      final row = AttendanceStore.attendanceRecordForSessionStudent(
        session.id,
        widget.student.id,
      );
      if (row?.verified == true) {
        setState(() {
          _errorMessage = 'You already checked in for this session.';
        });
        return;
      }
    }

    _setStage('Saving attendance…');

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
    if (!mounted) return;

    switch (outcome) {
      case StudentOfflineCheckInOutcome.deviceBlocked:
        if (await AttendanceRepository.instance
                .isCheckInAttemptAcceptedForSessionStudent(
              sessionId: session.id,
              studentId: widget.student.id,
            ) ||
            AttendanceStore.isPresentForSession(session.id, widget.student.id)) {
          setState(() {
            _statusLine =
                'Check-in submitted. Syncing official record from server…';
            _done = true;
          });
          if (mounted) {
            Navigator.of(context).pop(const StudentCheckInProgressResult(
              success: true,
              wasQueued: false,
              serverVerified: false,
            ));
          }
          return;
        }
        setState(() {
          _errorMessage = userMessageForCheckInOutcome(outcome);
        });
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
        setState(() {
          _errorMessage = userMessageForCheckInOutcome(
            resolved,
            rejectionReason: reason,
          );
        });
        return;
      case StudentOfflineCheckInOutcome.duplicate:
        setState(() {
          _errorMessage = userMessageForCheckInOutcome(outcome);
        });
        return;
      case StudentOfflineCheckInOutcome.success:
        setState(() {
          _statusLine = 'Attendance verified and saved.';
          _done = true;
        });
        if (mounted) {
          Navigator.of(context).pop(const StudentCheckInProgressResult(
            success: true,
            wasQueued: false,
            serverVerified: true,
          ));
        }
        return;
      case StudentOfflineCheckInOutcome.submittedPendingVerification:
        setState(() {
          _statusLine =
              'Check-in submitted. Syncing official record from server…';
          _done = true;
        });
        if (mounted) {
          Navigator.of(context).pop(const StudentCheckInProgressResult(
            success: true,
            wasQueued: false,
            serverVerified: false,
          ));
        }
        return;
      case StudentOfflineCheckInOutcome.queuedOffline:
        setState(() {
          _statusLine =
              'Saved as pending on this device. Will verify when online (up to 7 days).';
          _done = true;
        });
        if (mounted) {
          Navigator.of(context).pop(const StudentCheckInProgressResult(
            success: true,
            wasQueued: true,
          ));
        }
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listLabel =
        '${widget.list.whoTaught} · ${widget.list.room}'.trim();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check-in'),
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: _errorMessage != null || _locationServiceDisabled
                ? Column(
                    key: const ValueKey('err'),
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
                        const Icon(Icons.error_outline_rounded,
                            size: 56, color: AppTheme.error),
                        const SizedBox(height: 20),
                        Text(
                          _errorMessage!,
                          style: theme.textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 28),
                      FilledButton(
                        onPressed: () =>
                            Navigator.of(context).pop<StudentCheckInProgressResult>(
                              null,
                            ),
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
                          _done ? Icons.check_circle_rounded : Icons.sensors_rounded,
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
                      if (_resolvingLocation) ...[
                        const SizedBox(height: 16),
                        LocationResolvingPanel(
                          resolving: true,
                          locationServiceDisabled: _locationServiceDisabled,
                          onRetry: _runPipeline,
                        ),
                      ],
                      if (!_done && (_resolvingLocation || !_done)) ...[
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
