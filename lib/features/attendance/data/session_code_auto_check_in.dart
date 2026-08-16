import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/auth/student_registration_number.dart';
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/device/device_identity.dart';
import '../../../core/device/device_student_registration_lock.dart';
import '../../../core/location/location_permission.dart';
import '../../../core/navigation/app_navigator.dart';
import '../check_in_outcome.dart';
import '../check_in_rejection.dart';
import '../check_in_validation.dart';
import '../models/attendance_models.dart';
import 'attendance_offline_sync.dart';
import 'attendance_repository.dart';
import 'pending_retention.dart';
import 'pending_session_code_queue.dart';

/// Outcome when the app auto-checks in from a session-code push / notice.
enum SessionCodeAutoCheckInResult {
  skipped,
  alreadyCheckedIn,
  submitted,
  submittedPendingVerification,
  queuedOffline,
  needsCourseChoice,
  validationFailed,
  deviceBlocked,
  failed,
}

/// Runs the student check-in pipeline when a session code arrives via push.
class SessionCodeAutoCheckIn {
  SessionCodeAutoCheckIn._();

  static String? _lastCode;
  static DateTime? _lastRunAt;
  static const _debounce = Duration(seconds: 20);

  /// Extracts a join code from FCM [data] or notice fields.
  static String? codeFromPushData(Map<String, dynamic> data) {
    final kind = (data['kind'] as String? ?? '').trim().toLowerCase();
    if (kind.isNotEmpty && kind != 'sessioncode') return null;
    final raw = (data['sessionCode'] as String? ?? '').trim();
    if (raw.isEmpty) return null;
    final normalized = normalizeSessionCodeInput(raw);
    return isValidJoinCodeFormat(normalized) ? normalized : null;
  }

  /// True when [code] belongs to an active remote-learning session (no code push / auto check-in).
  static Future<bool> isRemoteLearningSessionCode(String rawCode) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) return false;
    await AttendanceRepository.instance.loadAll(force: false);
    var session = AttendanceRepository.instance.validateSessionCode(code);
    if (session == null && AppConnectivity.instance.isOnline) {
      session = await AttendanceRepository.instance
          .resolveActiveSessionByCodeForSignIn(code);
    }
    return session?.remoteLearning == true;
  }

  static bool _shouldRunForCurrentUser() {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || !auth.roleCheckDone) return false;
    if (auth.isAdmin || auth.isLecturer) return false;
    if (!AttendanceRepository.isStudentScopedUser()) return false;
    final reg = StudentRegistrationNumber.normalize(
      auth.currentRegistrationNumber?.trim() ?? '',
    );
    return reg.isNotEmpty;
  }

  static bool _debounced(String code) {
    final now = DateTime.now();
    if (_lastCode == code &&
        _lastRunAt != null &&
        now.difference(_lastRunAt!) < _debounce) {
      return true;
    }
    _lastCode = code;
    _lastRunAt = now;
    return false;
  }

  /// Handles session-code pushes from OneSignal click / foreground handlers.
  static Future<void> handlePushData(Map<String, dynamic> data) async {
    final code = codeFromPushData(data);
    if (code == null || code.isEmpty) return;
    if (await isRemoteLearningSessionCode(code)) return;
    await run(rawCode: code, showFeedback: true);
  }

  static Future<SessionCodeAutoCheckInResult> run({
    required String rawCode,
    bool showFeedback = true,
  }) async {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || !auth.roleCheckDone) {
      return SessionCodeAutoCheckInResult.skipped;
    }
    if (auth.isAdmin || auth.isLecturer) {
      return SessionCodeAutoCheckInResult.skipped;
    }
    await auth.ensureStudentRegistrationHydrated();
    if (!_shouldRunForCurrentUser()) {
      return SessionCodeAutoCheckInResult.skipped;
    }

    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) {
      return SessionCodeAutoCheckInResult.validationFailed;
    }
    if (_debounced(code)) {
      return SessionCodeAutoCheckInResult.skipped;
    }

    final reg = StudentRegistrationNumber.normalize(
      AuthRepository.instance.currentRegistrationNumber?.trim() ?? '',
    );
    if (reg.isEmpty) {
      if (showFeedback) {
        showRootSnackBar(
          'Your account has no registration number. Update your profile in Settings or contact support.',
          isError: true,
        );
      }
      return SessionCodeAutoCheckInResult.validationFailed;
    }

    try {
      await AttendanceRepository.instance.loadAll(force: false);
      await AppConnectivity.instance.ensureReachable(
        timeout: const Duration(seconds: 2),
      );

      var student =
          await AttendanceRepository.instance.resolveStudentForRegistration(reg);
      if (student == null) {
        return SessionCodeAutoCheckInResult.failed;
      }
      await AttendanceRepository.instance.ensureStudentDocOnServer(student.id);

      final resolved = await AttendanceRepository.instance
          .resolveSessionAndListForStudentCode(code);
      final session = resolved.session;

      if (session == null) {
        final queued = await _queueOfflineAttempt(reg: reg, rawCode: code);
        if (showFeedback && queued) {
          showRootSnackBar(
            'Class code $code saved — will auto-verify when the session is available.',
          );
        }
        return queued
            ? SessionCodeAutoCheckInResult.queuedOffline
            : SessionCodeAutoCheckInResult.failed;
      }

      if (session.remoteLearning) {
        return SessionCodeAutoCheckInResult.skipped;
      }

      if (!session.isOpenForCheckIn) {
        if (showFeedback) {
          showRootSnackBar(
            'Session code $code is no longer active.',
            isError: true,
          );
        }
        return SessionCodeAutoCheckInResult.validationFailed;
      }

      final list = resolved.list;
      if (list == null) {
        final queued = await _queueOfflineAttempt(reg: reg, rawCode: code);
        return queued
            ? SessionCodeAutoCheckInResult.queuedOffline
            : SessionCodeAutoCheckInResult.failed;
      }

      final enroll =
          await AttendanceRepository.instance.ensureStudentEnrolledOnList(
        list: list,
        student: student,
      );
      if (enroll == StudentListEnrollOutcome.deviceBlocked) {
        if (showFeedback) {
          showRootSnackBar(
            DeviceStudentRegistrationLock.blockMessage,
            isError: true,
          );
        }
        return SessionCodeAutoCheckInResult.deviceBlocked;
      }
      if (enroll == StudentListEnrollOutcome.needsCourseChoice) {
        if (showFeedback) {
          showRootSnackBar(
            'Open Attendance, enter code $code, and choose your course to join this list.',
          );
        }
        return SessionCodeAutoCheckInResult.needsCourseChoice;
      }
      if (enroll == StudentListEnrollOutcome.noCourses) {
        return SessionCodeAutoCheckInResult.failed;
      }

      final existing = AttendanceStore.attendanceRecordForSessionStudent(
        session.id,
        student.id,
      );
      if (existing != null && existing.present && existing.verified) {
        if (showFeedback) {
          showRootSnackBar('You are already checked in for this session.');
        }
        return SessionCodeAutoCheckInResult.alreadyCheckedIn;
      }

      final captureIntentAt = DateTime.now();
      final deviceIdFuture = DeviceIdentity.resolve();
      final requiresGeofence = !sessionSkipsLocationCheck(session);
      final maxAge = locationMaxAgeForSession(session);
      final highAccuracy = sessionRequiresHighAccuracyGps(session);
      final gpsFuture = acquireCurrentGpsPosition(
        timeLimit: requiresGeofence
            ? const Duration(seconds: 12)
            : const Duration(seconds: 8),
        reuseMaxAge: maxAge,
        forceFresh: requiresGeofence,
        highAccuracy: highAccuracy,
      );

      if (!isTimestampWithinSessionBounds(session, captureIntentAt)) {
        if (showFeedback) {
          showRootSnackBar(
            'Check-in for code $code is outside the session time window.',
            isError: true,
          );
        }
        return SessionCodeAutoCheckInResult.validationFailed;
      }

      final gps = await gpsFuture;
      if (gps.position == null || gps.locationServiceDisabled) {
        final queued = await _queueOfflineAttempt(
          reg: reg,
          rawCode: code,
          captureIntentAt: captureIntentAt,
          latitude: gps.position?.latitude,
          longitude: gps.position?.longitude,
        );
        if (showFeedback && queued) {
          showRootSnackBar(
            'Code $code saved — enable GPS or go online to finish check-in.',
          );
        }
        return queued
            ? SessionCodeAutoCheckInResult.queuedOffline
            : SessionCodeAutoCheckInResult.failed;
      }

      final latitude = gps.position!.latitude;
      final longitude = gps.position!.longitude;
      final accuracy = gps.position!.accuracy;
      final studentAccuracy =
          accuracy.isFinite && accuracy > 0 ? accuracy : null;
      final verification = verifyLinkedSessionCheckIn(
        session: session,
        at: captureIntentAt,
        latitude: latitude,
        longitude: longitude,
        studentAccuracyMeters: studentAccuracy,
      );
      if (!verification.passed) {
        if (showFeedback) {
          showRootSnackBar(
            '${verification.failureMessage ?? 'Check-in could not be verified.'} '
            'Code: $code.',
            isError: true,
          );
        }
        return SessionCodeAutoCheckInResult.validationFailed;
      }

      final deviceId = await deviceIdFuture;
      if (deviceId.trim().isEmpty) {
        return SessionCodeAutoCheckInResult.failed;
      }

      if (AttendanceStore.hasPresentCheckInForDevice(
            session.id,
            deviceId,
            student.id,
          ) ||
          await AttendanceRepository.instance.isDeviceBlockedForStudentSession(
            sessionId: session.id,
            studentId: student.id,
            deviceId: deviceId,
            sessionCodeRaw: session.sessionCode,
          )) {
        if (showFeedback) {
          showRootSnackBar(
            userMessageForCheckInOutcome(
              StudentOfflineCheckInOutcome.deviceBlocked,
            ),
            isError: true,
          );
        }
        return SessionCodeAutoCheckInResult.deviceBlocked;
      }

      final course = resolveCourseForStudentCheckIn(list, student.id);
      final record = AttendanceRecord(
        id: attendanceRecordIdForSessionStudent(session.id, student.id),
        sessionId: session.id,
        studentId: student.id,
        course: course,
        timestamp: captureIntentAt,
        latitude: latitude,
        longitude: longitude,
        verified: false,
        present: true,
        deviceId: deviceId,
      );

      final outcome = await AttendanceRepository.instance
          .submitStudentCheckInWithOfflineSupport(
        record,
        listIdOverride: list.id,
        gpsAccuracyMeters: studentAccuracy,
      );

      switch (outcome) {
        case StudentOfflineCheckInOutcome.success:
          if (showFeedback) {
            showRootSnackBar(
              'Check-in verified for ${list.displayTitle} (code $code).',
            );
          }
          return SessionCodeAutoCheckInResult.submitted;
        case StudentOfflineCheckInOutcome.submittedPendingVerification:
          if (showFeedback) {
            showRootSnackBar(
              'Check-in submitted for ${list.displayTitle} — syncing from server.',
            );
          }
          return SessionCodeAutoCheckInResult.submittedPendingVerification;
        case StudentOfflineCheckInOutcome.queuedOffline:
          if (showFeedback) {
            showRootSnackBar(
              'Check-in for code $code saved on this device — will upload when online.',
            );
          }
          return SessionCodeAutoCheckInResult.queuedOffline;
        case StudentOfflineCheckInOutcome.sessionMismatch:
        case StudentOfflineCheckInOutcome.rejectedVerification:
          if (showFeedback) {
            final reason = await AttendanceRepository.instance
                .fetchCheckInAttemptRejectionReasonWithRetry(record.id);
            var resolved = outcome;
            if (resolved == StudentOfflineCheckInOutcome.rejectedVerification &&
                reason != null) {
              resolved = outcomeFromRejectionReason(reason);
            }
            if (resolved == StudentOfflineCheckInOutcome.rejectedVerification &&
                await AttendanceRepository.instance
                    .isDeviceBlockedForStudentSession(
                  sessionId: session.id,
                  studentId: student.id,
                  deviceId: deviceId,
                  sessionCodeRaw: session.sessionCode,
                )) {
              resolved = StudentOfflineCheckInOutcome.deviceBlocked;
            }
            showRootSnackBar(
              userMessageForCheckInOutcome(
                resolved,
                rejectionReason: reason,
              ),
              isError: true,
            );
          }
          return SessionCodeAutoCheckInResult.validationFailed;
        case StudentOfflineCheckInOutcome.duplicate:
          return SessionCodeAutoCheckInResult.alreadyCheckedIn;
        case StudentOfflineCheckInOutcome.deviceBlocked:
          if (showFeedback) {
            showRootSnackBar(
              userMessageForCheckInOutcome(
                StudentOfflineCheckInOutcome.deviceBlocked,
              ),
              isError: true,
            );
          }
          return SessionCodeAutoCheckInResult.deviceBlocked;
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('SessionCodeAutoCheckIn failed: $e\n$st');
      }
      return SessionCodeAutoCheckInResult.failed;
    }
  }

  static Future<bool> _queueOfflineAttempt({
    required String reg,
    required String rawCode,
    DateTime? captureIntentAt,
    double? latitude,
    double? longitude,
  }) async {
    final capturedAt = captureIntentAt ?? DateTime.now();
    final deviceId = await DeviceIdentity.resolve();
    if (deviceId.trim().isEmpty) return false;

    var lat = latitude;
    var lng = longitude;
    if (lat == null || lng == null) {
      final gps = await acquireCurrentGpsPosition(
        timeLimit: const Duration(seconds: 10),
        forceFresh: false,
      );
      if (gps.position == null) return false;
      lat = gps.position!.latitude;
      lng = gps.position!.longitude;
    }

    final id =
        '${normalizeSessionCodeInput(rawCode)}_${reg.trim().toUpperCase()}';
    await PendingSessionCodeQueue.enqueue(
      PendingSessionCodeEntry(
        id: id,
        registrationNumber: reg,
        sessionCodeRaw: rawCode,
        capturedAt: capturedAt,
        latitude: lat,
        longitude: lng,
        deviceId: deviceId.trim(),
        status: PendingSessionCodeStatus.queued,
        note:
            'Auto-saved from class notification (up to ${PendingRetention.unverifiedPending.inDays} days). '
            'Will verify when the session appears on the server.',
      ),
    );
    if (AppConnectivity.instance.isOnline) {
      unawaited(AttendanceOfflineSync.drainSessionValidationFirst());
    }
    return true;
  }
}
