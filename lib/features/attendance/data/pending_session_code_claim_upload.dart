import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/api/rtd_stubs.dart';
import '../../../core/api/api_collections.dart';
import '../../../core/api/api_store.dart';
import '../check_in_rejection.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_check_in_queue.dart';
import 'pending_retention.dart';
import 'pending_session_code_queue.dart';

enum PendingClaimServerState {
  missing,
  pending,
  accepted,
  rejected,
}

/// Uploads student session-code + GPS evidence to RTD first; Firestore is mirrored
/// by Cloud Functions (client may best-effort mirror when reachable).
class PendingSessionCodeClaimUpload {
  PendingSessionCodeClaimUpload._();

  static const Duration _uploadTimeout = Duration(seconds: 8);
  static const Duration _lookupTimeout = Duration(seconds: 5);

  static const String deviceBlockNote = deviceAlreadyUsedUserMessage;

  /// Firestore doc id for a claim awaiting session match.
  static String claimDocId({
    required String normalizedCode,
    required String studentId,
  }) =>
      'await_${normalizedCode}_$studentId';

  /// Best-effort upload after local queue write or during sync retries.
  static Future<bool> uploadForEntry(PendingSessionCodeEntry entry) async {
    if (!await _isOnlineForUpload()) return false;

    final student = await AttendanceRepository.instance
        .resolveStudentForRegistration(entry.registrationNumber, fast: true);
    if (student == null) return false;

    return uploadForEntryWithStudent(entry: entry, studentId: student.id);
  }

  /// RTD upload only — defers session linking and verification to a later drain pass.
  static Future<bool> uploadClaimMetadataOnly({
    required PendingSessionCodeEntry entry,
    required String studentId,
  }) async {
    if (!await _isOnlineForUpload()) return false;
    if (entry.hasLocalUploadEvidence) return true;

    final canonicalStudentId = AttendanceRepository.instance
        .canonicalStudentIdForUpload(studentId);

    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return false;
    if (entry.deviceId.trim().isEmpty) return false;

    final blockReason = await localDeviceBlockReason(
      entry,
      studentId: canonicalStudentId,
    );
    if (blockReason != null) return false;

    final docId = claimDocId(normalizedCode: code, studentId: canonicalStudentId);
    final existingRtd = await CheckInRtdAttemptPublish.readStatusOnRtd(docId);
    if (existingRtd != null) {
      await PendingSessionCodeQueue.markUploaded(entry.id);
      return true;
    }

    final uid = AuthRepository.instance.currentUserId?.trim();
    final rtdOk = await CheckInRtdAttemptPublish.uploadPending(
      recordId: docId,
      studentId: canonicalStudentId,
      deviceId: entry.deviceId.trim(),
      capturedAt: entry.capturedAt,
      latitude: entry.latitude,
      longitude: entry.longitude,
      sessionId: null,
      listId: null,
      course: '—',
      sessionCodeRaw: code,
      registrationNumber: entry.registrationNumber.trim().toUpperCase(),
      submittedByUid: uid,
      awaitingSession: true,
      pendingUntil: entry.pendingSince.add(PendingRetention.unverifiedPending),
    );
    if (!rtdOk) return false;

    await PendingSessionCodeQueue.markUploaded(entry.id);
    return true;
  }

  /// Local-only guard before student roster id is resolved.
  static Future<String?> localDeviceBlockReason(
    PendingSessionCodeEntry entry, {
    String? studentId,
  }) async {
    final deviceId = entry.deviceId.trim();
    if (deviceId.isEmpty) return null;

    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return null;

    final reg = entry.registrationNumber.trim().toUpperCase();
    final sid = studentId?.trim() ?? '';
    for (final e in await PendingSessionCodeQueue.loadAll()) {
      if (e.id == entry.id) continue;
      if (e.status == PendingSessionCodeStatus.deviceBlocked) continue;
      if (e.deviceId.trim() != deviceId) continue;
      if (normalizeSessionCodeInput(e.sessionCodeRaw) != code) continue;
      if (e.registrationNumber.trim().toUpperCase() != reg) {
        return deviceBlockNote;
      }
    }

    for (final e in await PendingCheckInQueue.loadAll()) {
      if (e.deviceId.trim() != deviceId) continue;
      if (sid.isNotEmpty && e.studentId.trim() == sid) continue;
      final sess = AttendanceStore.sessionById(e.sessionId);
      if (sess != null &&
          normalizeSessionCodeInput(sess.sessionCode) == code) {
        return deviceBlockNote;
      }
    }

    for (final sess in AttendanceStore.sessions) {
      if (normalizeSessionCodeInput(sess.sessionCode) != code) continue;
      for (final r in AttendanceStore.attendanceRecords) {
        if (r.sessionId != sess.id || !r.present) continue;
        if (r.deviceId?.trim() != deviceId) continue;
        if (sid.isNotEmpty && r.studentId.trim() == sid) continue;
        return deviceBlockNote;
      }
    }

    return null;
  }

  /// Blocks when this device already checked in (local, queued, or server)
  /// for another student on the same session code or session id.
  static Future<String?> deviceBlockReason({
    required PendingSessionCodeEntry entry,
    String? studentId,
  }) async {
    final local = await localDeviceBlockReason(entry, studentId: studentId);
    if (local != null) return local;

    final sid = studentId?.trim() ?? '';
    if (sid.isEmpty) return null;

    final blocked =
        await AttendanceRepository.instance.isDeviceBlockedForStudentSession(
      sessionId: entry.sessionId?.trim() ?? '',
      studentId: sid,
      deviceId: entry.deviceId,
      sessionCodeRaw: entry.sessionCodeRaw,
    );
    return blocked ? deviceBlockNote : null;
  }

  /// True when this student's awaiting claim is already on Firestore.
  static Future<bool> isClaimOnServer({
    required PendingSessionCodeEntry entry,
    required String studentId,
  }) async {
    final state = await claimServerState(entry: entry, studentId: studentId);
    if (state == PendingClaimServerState.pending ||
        state == PendingClaimServerState.accepted) {
      return true;
    }
    if (entry.hasLocalUploadEvidence) {
      final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
      if (!isValidJoinCodeFormat(code)) return false;
      final docId = claimDocId(normalizedCode: code, studentId: studentId);
      return CheckInRtdAttemptPublish.existsOnRtd(docId);
    }
    return false;
  }

  /// Reads authoritative claim status — RTD first, then Firestore.
  static Future<PendingClaimServerState> claimServerState({
    required PendingSessionCodeEntry entry,
    required String studentId,
  }) async {
    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return PendingClaimServerState.missing;
    final docId = claimDocId(normalizedCode: code, studentId: studentId);

    final rtdStatus = await CheckInRtdAttemptPublish.readStatusOnRtd(docId);
    if (rtdStatus != null) {
      return switch (rtdStatus) {
        'accepted' => PendingClaimServerState.accepted,
        'rejected' => PendingClaimServerState.rejected,
        'pending' => PendingClaimServerState.pending,
        _ => PendingClaimServerState.pending,
      };
    }

    if (!AppConnectivity.instance.hasNetworkInterface) {
      return PendingClaimServerState.missing;
    }
    try {
      final doc = await apiStore()
          .collection(ApiCollections.checkInAttempts)
          .doc(docId)
          .get(const ApiGetOptions(source: ApiSource.server))
          .timeout(_lookupTimeout);
      if (!doc.exists) return PendingClaimServerState.missing;
      final status = (doc.data()?['status'] as String?)?.trim().toLowerCase();
      return switch (status) {
        'accepted' => PendingClaimServerState.accepted,
        'rejected' => PendingClaimServerState.rejected,
        'pending' => PendingClaimServerState.pending,
        _ => PendingClaimServerState.missing,
      };
    } catch (_) {
      return PendingClaimServerState.missing;
    }
  }

  static Future<bool> _isOnlineForUpload() async {
    // RTD is the primary upload path — do not require Firestore reachability.
    return AppConnectivity.instance.hasNetworkInterface;
  }

  static Future<AttendanceSession?> _resolvePublishedSession(
    PendingSessionCodeEntry entry,
  ) async {
    try {
      return await AttendanceRepository.instance
          .resolvePublishedLecturerSessionForPendingClaim(
        sessionCodeRaw: entry.sessionCodeRaw,
        capturedAt: entry.capturedAt,
        sessionIdHint: entry.sessionId,
      )
          .timeout(_lookupTimeout);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _patchClaimWithSession({
    required PendingSessionCodeEntry entry,
    required String studentId,
    required AttendanceSession session,
  }) async {
    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return false;
    final docId = claimDocId(normalizedCode: code, studentId: studentId);
    return CheckInRtdAttemptPublish.patchLinkedSession(
      recordId: docId,
      studentId: studentId,
      sessionId: session.id,
      listId: session.listId,
      sessionCodeRaw: code,
      registrationNumber: entry.registrationNumber.trim().toUpperCase(),
    );
  }

  /// Links an existing or new awaiting claim to a published lecturer session.
  static Future<bool> linkPublishedSessionToClaim({
    required PendingSessionCodeEntry entry,
    required String studentId,
    required AttendanceSession session,
  }) async {
    if (!await AttendanceRepository.instance
        .isLecturerSessionPublishedOnServer(session.id)) {
      return false;
    }
    unawaited(
      AttendanceRepository.instance.ensureStudentDocOnServer(studentId),
    );
    if (await isClaimOnServer(entry: entry, studentId: studentId)) {
      final patched = await _patchClaimWithSession(
        entry: entry,
        studentId: studentId,
        session: session,
      );
      if (patched) {
        await awaitImmediateVerificationWhenBothEndsPresent(
          entry: entry,
          studentId: studentId,
          session: session,
        );
      }
      return patched;
    }
    return uploadForEntryWithStudent(entry: entry, studentId: studentId);
  }

  static Future<bool> uploadForEntryWithStudent({
    required PendingSessionCodeEntry entry,
    required String studentId,
  }) async {
    if (!await _isOnlineForUpload()) return false;

    final canonicalStudentId = AttendanceRepository.instance
        .canonicalStudentIdForUpload(studentId);

    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return false;
    if (entry.deviceId.trim().isEmpty) return false;

    // Persist before upload so Check-ins lists the attempt even when the
    // lecturer session is not on the device yet.
    await PendingSessionCodeQueue.updateStoredEntry(
      entry.copyWith(
        status: entry.status == PendingSessionCodeStatus.approved
            ? entry.status
            : PendingSessionCodeStatus.queued,
        note: entry.note?.trim().isNotEmpty == true
            ? entry.note
            : 'Saved on this device — uploading session metadata.',
        invalidMarkedAt: null,
      ),
    );

    final blockReason = await localDeviceBlockReason(
      entry,
      studentId: canonicalStudentId,
    );
    if (blockReason != null) {
      if (kDebugMode) {
        debugPrint('PendingSessionCodeClaimUpload: blocked upload — $blockReason');
      }
      return false;
    }

    unawaited(
      AttendanceRepository.instance
          .ensureStudentDocOnServer(canonicalStudentId),
    );

    final lecturerSession = await _resolvePublishedSession(entry);
    final bothEndsPresent = lecturerSession != null;

    if (await isClaimOnServer(
      entry: entry,
      studentId: canonicalStudentId,
    )) {
      if (bothEndsPresent) {
        await _patchClaimWithSession(
          entry: entry,
          studentId: canonicalStudentId,
          session: lecturerSession,
        );
        await awaitImmediateVerificationWhenBothEndsPresent(
          entry: entry,
          studentId: canonicalStudentId,
          session: lecturerSession,
        );
      }
      return true;
    }

    final uid = AuthRepository.instance.currentUserId?.trim();
    final docId = claimDocId(normalizedCode: code, studentId: canonicalStudentId);

    final rtdOk = await CheckInRtdAttemptPublish.uploadPending(
      recordId: docId,
      studentId: canonicalStudentId,
      deviceId: entry.deviceId.trim(),
      capturedAt: entry.capturedAt,
      latitude: entry.latitude,
      longitude: entry.longitude,
      sessionId: bothEndsPresent ? lecturerSession.id : null,
      listId: bothEndsPresent ? lecturerSession.listId : null,
      course: '—',
      sessionCodeRaw: code,
      registrationNumber: entry.registrationNumber.trim().toUpperCase(),
      submittedByUid: uid,
      awaitingSession: !bothEndsPresent,
      pendingUntil: !bothEndsPresent
          ? entry.pendingSince.add(PendingRetention.unverifiedPending)
          : null,
    );
    if (!rtdOk) return false;

    await PendingSessionCodeQueue.markUploaded(entry.id);

    if (bothEndsPresent) {
      await awaitImmediateVerificationWhenBothEndsPresent(
        entry: entry,
        studentId: canonicalStudentId,
        session: lecturerSession,
      );
    }
    return true;
  }

  /// Both lecturer session + student claim are on the server — verify now.
  static Future<bool> awaitImmediateVerificationWhenBothEndsPresent({
    required PendingSessionCodeEntry entry,
    required String studentId,
    required AttendanceSession session,
  }) async {
    if (await tryRefreshLocalFromServerClaim(
      entry: entry,
      studentId: studentId,
    )) {
      return true;
    }
    return AttendanceRepository.instance.quickVerifyStudentCheckIn(
      sessionId: session.id,
      studentId: studentId,
    );
  }

  /// When the server already matched this claim, pull the official row locally.
  static Future<bool> tryRefreshLocalFromServerClaim({
    required PendingSessionCodeEntry entry,
    required String studentId,
  }) async {
    if (!AppConnectivity.instance.hasNetworkInterface) return false;
    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return false;
    final docId = claimDocId(normalizedCode: code, studentId: studentId);
    try {
      final doc = await apiStore()
          .collection(ApiCollections.checkInAttempts)
          .doc(docId)
          .get(const ApiGetOptions(source: ApiSource.server))
          .timeout(_lookupTimeout);
      if (!doc.exists) return false;
      final data = doc.data();
      if (data == null) return false;
      final status = (data['status'] as String?)?.trim().toLowerCase();
      if (status != 'accepted') return false;
      final sessionId = (data['sessionId'] as String?)?.trim() ?? '';
      if (sessionId.isEmpty) return false;
      final result =
          await AttendanceRepository.instance.refreshOfficialRecordFromApi(
        sessionId: sessionId,
        studentId: studentId,
      );
      return result == OfficialRecordRefreshResult.verifiedPresent;
    } catch (_) {
      return false;
    }
  }
}
