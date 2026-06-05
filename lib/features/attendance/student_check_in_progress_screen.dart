import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/connectivity/app_connectivity.dart';
import '../../core/device/device_identity.dart';
import '../../core/location/location_permission.dart';
import '../../core/theme/app_theme.dart';
import 'check_in_validation.dart';
import 'data/attendance_repository.dart';
import 'models/attendance_models.dart';

/// Returned to the sign-in flow when the automated check-in pipeline finishes.
class StudentCheckInProgressResult {
  const StudentCheckInProgressResult({
    required this.success,
    this.wasQueued = false,
  });

  /// True when a present row exists locally (submitted or queued for upload).
  final bool success;

  /// True when Firestore was unavailable and the row was written to the offline queue.
  final bool wasQueued;
}

/// Animated pipeline: session time, GPS, distance, then Firestore or offline queue.
class StudentCheckInProgressScreen extends StatefulWidget {
  const StudentCheckInProgressScreen({
    super.key,
    required this.session,
    required this.student,
    required this.list,
    this.selectedCourse,
  });

  final AttendanceSession session;
  final StudentRecord student;
  final AttendanceList list;
  final String? selectedCourse;

  @override
  State<StudentCheckInProgressScreen> createState() =>
      _StudentCheckInProgressScreenState();
}

class _StudentCheckInProgressScreenState extends State<StudentCheckInProgressScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  String _statusLine = 'Preparing…';
  String? _errorMessage;
  bool _done = false;

  AttendanceSession get _live =>
      AttendanceStore.sessionById(widget.session.id) ?? widget.session;

  @override
  void initState() {
    super.initState();
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

  Future<void> _runPipeline() async {
    final session = _live;
    if (!session.isActive) {
      setState(() {
        _errorMessage =
            'This session is no longer active. Ask your lecturer for a new code.';
      });
      return;
    }

    _setStage('Checking session time…');
    await Future<void>.delayed(const Duration(milliseconds: 16));
    final now = DateTime.now();
    if (!isTimestampWithinSessionBounds(session, now)) {
      setState(() {
        _errorMessage =
            'Check-in is only allowed during the scheduled session window.';
      });
      return;
    }

    final isOnline = AppConnectivity.instance.isOnline;
    double latitude;
    double longitude;
    if (session.remoteLearning) {
      _setStage('Long-distance session — location not required…');
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final gps = await tryAcquireGpsPosition(
        timeLimit: const Duration(seconds: 8),
      );
      latitude = gps.position?.latitude ?? 0;
      longitude = gps.position?.longitude ?? 0;
    } else {
      _setStage('Resolving your current location…');
      final gps = await tryAcquireGpsPosition(
        timeLimit: isOnline
            ? const Duration(seconds: 12)
            : const Duration(seconds: 18),
      );
      if (!mounted) return;
      if (gps.position == null) {
        setState(() {
          _errorMessage = gps.errorMessage ??
              'Could not read your location. Allow location and try again.';
        });
        return;
      }
      final pos = gps.position!;
      latitude = pos.latitude;
      longitude = pos.longitude;

      _setStage('Checking distance to class…');
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (!isPositionWithinSession(session, latitude, longitude)) {
        final dist = Geolocator.distanceBetween(
          session.latitude,
          session.longitude,
          latitude,
          longitude,
        );
        setState(() {
          _errorMessage =
              'Too far from class (${(dist / 1000).toStringAsFixed(2)} km). '
              'You must be within ${session.radiusMeters.toInt()} m.';
        });
        return;
      }
    }
    if (!mounted) return;

    final installDeviceId = await DeviceIdentity.resolve();
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
    )) {
      setState(() {
        _errorMessage =
            'This phone already recorded attendance for this session for another student.';
      });
      return;
    }
    if (AttendanceStore.isPresentForSession(session.id, widget.student.id)) {
      setState(() {
        _errorMessage = 'You already checked in for this session.';
      });
      return;
    }

    _setStage('Saving attendance…');
    await Future<void>.delayed(const Duration(milliseconds: 16));

    final explicitCourse = widget.selectedCourse?.trim() ?? '';
    final course = explicitCourse.isNotEmpty
        ? explicitCourse
        : resolveCourseForStudentCheckIn(widget.list, widget.student.id);
    final record = AttendanceRecord(
      id: attendanceRecordIdForSessionStudent(session.id, widget.student.id),
      sessionId: session.id,
      studentId: widget.student.id,
      course: course,
      timestamp: now,
      latitude: latitude,
      longitude: longitude,
      selfieStoragePath: null,
      verified: true,
      present: true,
      deviceId: installDeviceId,
    );

    final outcome = await AttendanceRepository.instance
        .submitStudentCheckInWithOfflineSupport(record);
    if (!mounted) return;

    switch (outcome) {
      case StudentOfflineCheckInOutcome.deviceBlocked:
        setState(() {
          _errorMessage =
              'This phone already recorded attendance for this session.';
        });
        return;
      case StudentOfflineCheckInOutcome.duplicate:
        setState(() {
          _errorMessage = 'Attendance was already recorded for this session.';
        });
        return;
      case StudentOfflineCheckInOutcome.success:
        setState(() {
          _statusLine = 'Attendance saved.';
          _done = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (mounted) {
          Navigator.of(context).pop(const StudentCheckInProgressResult(
            success: true,
            wasQueued: false,
          ));
        }
        return;
      case StudentOfflineCheckInOutcome.queuedOffline:
        setState(() {
          _statusLine = 'Saved on this device. Will upload when you are online.';
          _done = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 140));
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
    return Scaffold(
      appBar: AppBar(title: const Text('Check-in')),
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
