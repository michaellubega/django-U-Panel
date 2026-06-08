import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import '../check_in_rejection.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_check_in_queue.dart';
import 'pending_retention.dart';
import 'pending_session_code_queue.dart';

/// Uploads student session-code + GPS evidence to Firestore.
/// When the lecturer session already exists, verifies presence immediately.
/// Otherwise keeps [awaitingSession] for up to [PendingRetention.unverifiedPending].
class PendingSessionCodeClaimUpload {
  PendingSessionCodeClaimUpload._();

  static const Duration _uploadTimeout = Duration(seconds: 6);

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
        .resolveStudentForRegistration(entry.registrationNumber);
    if (student == null) return false;

    return uploadForEntryWithStudent(entry: entry, studentId: student.id);
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
    if (!AppConnectivity.instance.hasNetworkInterface) return false;
    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return false;
    final docId = claimDocId(normalizedCode: code, studentId: studentId);
    try {
      final doc = await uPanelFirestore()
          .collection(FirestoreCollections.checkInAttempts)
          .doc(docId)
          .get()
          .timeout(_uploadTimeout);
      if (!doc.exists) return false;
      final status = (doc.data()?['status'] as String?)?.trim().toLowerCase();
      return status == 'pending' || status == 'accepted';
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _isOnlineForUpload() async {
    if (!AppConnectivity.instance.hasNetworkInterface) return false;
    if (AppConnectivity.instance.isOnline) return true;
    return AppConnectivity.instance.ensureReachable(
      timeout: const Duration(seconds: 4),
    );
  }
  static Future<bool> uploadForEntryWithStudent({
    required PendingSessionCodeEntry entry,
    required String studentId,
  }) async {
    if (!await _isOnlineForUpload()) return false;

    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return false;
    if (entry.deviceId.trim().isEmpty) return false;

    final blockReason = await deviceBlockReason(
      entry: entry,
      studentId: studentId,
    );
    if (blockReason != null) {
      if (kDebugMode) {
        debugPrint('PendingSessionCodeClaimUpload: blocked upload — $blockReason');
      }
      return false;
    }

    var lecturerSession = await AttendanceRepository.instance
        .resolvePublishedLecturerSessionForPendingClaim(
      sessionCodeRaw: entry.sessionCodeRaw,
      capturedAt: entry.capturedAt,
      sessionIdHint: entry.sessionId,
    );
    if (lecturerSession != null &&
        await isClaimOnServer(entry: entry, studentId: studentId)) {
      await awaitImmediateVerificationWhenBothEndsPresent(
        entry: entry,
        studentId: studentId,
        session: lecturerSession,
      );
      return true;
    }

    final bothEndsPresent = lecturerSession != null;

    final uid = AuthRepository.instance.currentFirebaseUid?.trim();
    final docId = claimDocId(normalizedCode: code, studentId: studentId);

    try {
      await uPanelFirestore()
          .collection(FirestoreCollections.checkInAttempts)
          .doc(docId)
          .set(
            <String, dynamic>{
              'studentId': studentId,
              'registrationNumber': entry.registrationNumber.trim().toUpperCase(),
              'sessionCodeRaw': code,
              'sessionId': bothEndsPresent ? lecturerSession.id : '',
              'listId': bothEndsPresent ? lecturerSession.listId : '',
              'course': '—',
              'capturedAt': Timestamp.fromDate(entry.capturedAt),
              'latitude': entry.latitude,
              'longitude': entry.longitude,
              'deviceId': entry.deviceId.trim(),
              'status': 'pending',
              'awaitingSession': !bothEndsPresent,
              if (!bothEndsPresent)
                'pendingUntil': Timestamp.fromDate(
                  entry.pendingSince.add(PendingRetention.unverifiedPending),
                ),
              if (uid != null && uid.isNotEmpty) 'submittedByUid': uid,
              'clientSubmittedAt': FieldValue.serverTimestamp(),
            },
          )
          .timeout(_uploadTimeout);
      if (bothEndsPresent) {
        await awaitImmediateVerificationWhenBothEndsPresent(
          entry: entry,
          studentId: studentId,
          session: lecturerSession,
        );
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PendingSessionCodeClaimUpload: failed $docId: $e');
      }
      return false;
    }
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
      final doc = await uPanelFirestore()
          .collection(FirestoreCollections.checkInAttempts)
          .doc(docId)
          .get()
          .timeout(_uploadTimeout);
      if (!doc.exists) return false;
      final data = doc.data();
      if (data == null) return false;
      final status = (data['status'] as String?)?.trim().toLowerCase();
      if (status != 'accepted') return false;
      final sessionId = (data['sessionId'] as String?)?.trim() ?? '';
      if (sessionId.isEmpty) return false;
      final result =
          await AttendanceRepository.instance.refreshOfficialRecordFromFirebase(
        sessionId: sessionId,
        studentId: studentId,
      );
      return result == OfficialRecordRefreshResult.verifiedPresent;
    } catch (_) {
      return false;
    }
  }
}
