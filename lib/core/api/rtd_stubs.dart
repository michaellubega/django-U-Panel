import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../auth/auth_repository.dart';
import '../auth/student_registration_number.dart';
import 'api_client.dart';
import 'api_collections.dart';
import 'api_config.dart';
import 'api_datetime.dart';
import 'api_field_value.dart';
import 'api_store.dart';
import '../../features/attendance/data/attendance_repository.dart';
import '../../features/attendance/data/pending_session_code_claim_upload.dart';
import '../../features/attendance/models/attendance_models.dart';

/// REST-backed replacements for former Firebase Realtime Database sync.

abstract final class StudentRtdIndex {
  StudentRtdIndex._();

  static Future<bool> publishCurrentStudentRegistration() async {
    if (!isApiConfigured) return true;
    final uid = AuthRepository.instance.currentUserId?.trim();
    final reg =
        AuthRepository.instance.currentRegistrationNumber?.trim().toUpperCase();
    if (uid == null || uid.isEmpty || reg == null || reg.isEmpty) return true;
    try {
      await apiStore()
          .collection(ApiCollections.studentRegistrations)
          .doc(reg)
          .set(
            {
              'registrationNumber': reg,
              'uid': uid,
              'email': AuthRepository.instance.currentEmail,
              'fullName': AuthRepository.instance.currentFullName,
            },
            const ApiSetOptions(merge: true),
          );
      return true;
    } catch (_) {
      return false;
    }
  }
}

class CheckInRtdConfirmation {
  const CheckInRtdConfirmation({
    required this.status,
    required this.present,
    required this.verified,
    this.rejectionReason,
    this.sessionId,
    this.studentId,
  });

  final String status;
  final bool present;
  final bool verified;
  final String? rejectionReason;
  final String? sessionId;
  final String? studentId;

  bool get isPending => status == 'pending';
  bool get isAccepted => status == 'accepted' && present;
  bool get isRejected => status == 'rejected';

  static CheckInRtdConfirmation? fromValue(dynamic value) {
    if (value is! Map) return null;
    final map = value.map((k, v) => MapEntry(k.toString(), v));
    final status = (map['status'] as String?)?.trim().toLowerCase() ?? '';
    if (status.isEmpty) return null;
    return CheckInRtdConfirmation(
      status: status,
      present: map['present'] == true || status == 'accepted',
      verified: map['verified'] == true || status == 'accepted',
      rejectionReason: (map['rejectionReason'] as String?)?.trim(),
      sessionId: (map['sessionId'] as String?)?.trim(),
      studentId: (map['studentId'] as String?)?.trim(),
    );
  }
}

abstract final class CheckInRtdConfirmationWatch {
  static Stream<CheckInRtdConfirmation?> watch({
    required String sessionId,
    required String studentId,
  }) async* {
    if (!isApiConfigured) return;
    final canonicalId =
        AttendanceRepository.instance.canonicalStudentIdForUpload(studentId);
    final watchIds = _watchDocIds(
      sessionKey: sessionId,
      studentId: canonicalId,
    );
    await for (final _ in Stream.periodic(const Duration(seconds: 2))) {
      final conf = await _fetchBestConfirmation(
        watchIds: watchIds,
        sessionKey: sessionId,
        studentId: canonicalId,
      );
      yield conf;
    }
  }

  static Future<CheckInRtdConfirmation?> fetchOnce({
    required String sessionId,
    required String studentId,
  }) async {
    if (!isApiConfigured) return null;
    final canonicalId =
        AttendanceRepository.instance.canonicalStudentIdForUpload(studentId);
    return _fetchBestConfirmation(
      watchIds: _watchDocIds(sessionKey: sessionId, studentId: canonicalId),
      sessionKey: sessionId,
      studentId: canonicalId,
    );
  }

  static Future<CheckInRtdConfirmation?> awaitTerminal({
    required String sessionId,
    required String studentId,
    Duration timeout = const Duration(seconds: 45),
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    if (!isApiConfigured) return null;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final conf = await fetchOnce(sessionId: sessionId, studentId: studentId);
      if (conf != null && !conf.isPending) return conf;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < pollInterval ? remaining : pollInterval,
      );
    }
    return fetchOnce(sessionId: sessionId, studentId: studentId);
  }

  static List<String> _watchDocIds({
    required String sessionKey,
    required String studentId,
  }) {
    final ids = <String>{};
    final key = sessionKey.trim();
    if (key.isNotEmpty) {
      if (isValidJoinCodeFormat(normalizeSessionCodeInput(key))) {
        ids.add(
          PendingSessionCodeClaimUpload.claimDocId(
            normalizedCode: normalizeSessionCodeInput(key),
            studentId: studentId,
          ),
        );
      } else {
        ids.add(attendanceRecordIdForSessionStudent(key, studentId));
      }
    }
    return ids.toList();
  }

  static Future<CheckInRtdConfirmation?> _fetchBestConfirmation({
    required List<String> watchIds,
    required String sessionKey,
    required String studentId,
  }) async {
    for (final docId in watchIds) {
      if (docId.isEmpty) continue;
      final attempt = await apiStore()
          .collection(ApiCollections.checkInAttempts)
          .doc(docId)
          .get();
      final fromAttempt = _confirmationFromAttempt(attempt);
      if (fromAttempt != null && !fromAttempt.isPending) {
        return fromAttempt;
      }
    }

    final sessionId = isValidJoinCodeFormat(normalizeSessionCodeInput(sessionKey))
        ? null
        : sessionKey.trim();
    if (sessionId != null && sessionId.isNotEmpty) {
      final recordId = attendanceRecordIdForSessionStudent(sessionId, studentId);
      final record = await apiStore()
          .collection(ApiCollections.attendanceRecords)
          .doc(recordId)
          .get();
      final fromRecord = _confirmationFromRecord(record);
      if (fromRecord != null) return fromRecord;
    }

    for (final docId in watchIds) {
      if (docId.isEmpty) continue;
      final attempt = await apiStore()
          .collection(ApiCollections.checkInAttempts)
          .doc(docId)
          .get();
      final fromAttempt = _confirmationFromAttempt(attempt);
      if (fromAttempt != null) return fromAttempt;
    }
    return null;
  }

  static CheckInRtdConfirmation? _confirmationFromAttempt(
    ApiDocumentSnapshot snap,
  ) {
    if (!snap.exists || snap.data() == null) return null;
    return CheckInRtdConfirmation.fromValue(snap.data());
  }

  static CheckInRtdConfirmation? _confirmationFromRecord(
    ApiDocumentSnapshot snap,
  ) {
    if (!snap.exists || snap.data() == null) return null;
    final data = snap.data()!;
    if (data['present'] != true) return null;
    return CheckInRtdConfirmation(
      status: 'accepted',
      present: true,
      verified: data['verified'] == true,
      sessionId: data['sessionId'] as String?,
      studentId: data['studentId'] as String?,
    );
  }
}

abstract final class CheckInRtdAttemptPublish {
  CheckInRtdAttemptPublish._();

  static Future<bool> uploadPending({
    required String recordId,
    required String studentId,
    required String deviceId,
    required DateTime capturedAt,
    required double latitude,
    required double longitude,
    String? sessionId,
    String? listId,
    String? course,
    String? sessionCodeRaw,
    String? registrationNumber,
    String? studentName,
    String? submittedByUid,
    bool awaitingSession = false,
    DateTime? pendingUntil,
    double? gpsAccuracyMeters,
  }) async {
    if (!isApiConfigured) return false;
    await ApiClient.instance.ensureLoaded();
    if (ApiClient.instance.token == null || ApiClient.instance.token!.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          'CheckInRtdAttemptPublish: skip upload for $recordId — not signed in.',
        );
      }
      return false;
    }
    final payload = _attemptPayload(
      studentId: studentId,
      deviceId: deviceId,
      capturedAt: capturedAt,
      latitude: latitude,
      longitude: longitude,
      sessionId: sessionId,
      listId: listId,
      course: course,
      sessionCodeRaw: sessionCodeRaw,
      registrationNumber: registrationNumber,
      studentName: studentName,
      submittedByUid: submittedByUid,
      awaitingSession: awaitingSession,
      pendingUntil: pendingUntil,
      gpsAccuracyMeters: gpsAccuracyMeters,
    );
    try {
      await apiStore()
          .collection(ApiCollections.checkInAttempts)
          .doc(recordId)
          .set(payload, const ApiSetOptions(merge: true));
      return true;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('CheckInRtdAttemptPublish.uploadPending $recordId failed: $e');
        debugPrint('$st');
      }
      return false;
    }
  }

  static Future<bool> existsOnRtd(String recordId) async {
    if (!isApiConfigured) return false;
    try {
      final snap = await apiStore()
          .collection(ApiCollections.checkInAttempts)
          .doc(recordId.trim())
          .get();
      return snap.exists;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> readStatusOnRtd(String recordId) async {
    if (!isApiConfigured) return null;
    try {
      final snap = await apiStore()
          .collection(ApiCollections.checkInAttempts)
          .doc(recordId.trim())
          .get();
      if (!snap.exists) return null;
      return (snap.data()?['status'] as String?)?.trim().toLowerCase();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> patchLinkedSession({
    required String recordId,
    required String sessionId,
    String? listId,
    String? studentId,
    String? sessionCodeRaw,
    String? registrationNumber,
  }) async {
    if (!isApiConfigured) return false;
    final payload = <String, dynamic>{
      'sessionId': sessionId.trim(),
      'awaitingSession': false,
      if (listId != null && listId.trim().isNotEmpty) 'listId': listId.trim(),
      if (studentId != null && studentId.trim().isNotEmpty)
        'studentId': AttendanceRepository.instance
            .canonicalStudentIdForUpload(studentId),
      if (sessionCodeRaw != null && sessionCodeRaw.trim().isNotEmpty)
        'sessionCodeRaw': normalizeSessionCodeInput(sessionCodeRaw),
      if (registrationNumber != null && registrationNumber.trim().isNotEmpty)
        'registrationNumber': registrationNumber.trim().toUpperCase(),
    };
    try {
      await apiStore()
          .collection(ApiCollections.checkInAttempts)
          .doc(recordId.trim())
          .update(payload);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic> _attemptPayload({
    required String studentId,
    required String deviceId,
    required DateTime capturedAt,
    required double latitude,
    required double longitude,
    String? sessionId,
    String? listId,
    String? course,
    String? sessionCodeRaw,
    String? registrationNumber,
    String? studentName,
    String? submittedByUid,
    bool awaitingSession = false,
    DateTime? pendingUntil,
    double? gpsAccuracyMeters,
  }) {
    final canonicalId =
        AttendanceRepository.instance.canonicalStudentIdForUpload(studentId);
    final sid = sessionId?.trim() ?? '';
    final lid = listId?.trim() ?? '';
    final code = sessionCodeRaw?.trim().toUpperCase() ?? '';
    final awaiting = awaitingSession || sid.isEmpty || lid.isEmpty;
    final payload = <String, dynamic>{
      'studentId': canonicalId,
      'deviceId': deviceId.trim(),
      'status': 'pending',
      'capturedAt': apiDateToField(capturedAt),
      'latitude': latitude,
      'longitude': longitude,
      if (gpsAccuracyMeters != null &&
          gpsAccuracyMeters.isFinite &&
          gpsAccuracyMeters > 0)
        'gpsAccuracyMeters': gpsAccuracyMeters,
      'awaitingSession': awaiting,
      if (pendingUntil != null) 'pendingUntil': apiDateToField(pendingUntil),
      if (registrationNumber != null && registrationNumber.trim().isNotEmpty)
        'registrationNumber': registrationNumber.trim().toUpperCase(),
      if (studentName != null && studentName.trim().isNotEmpty)
        'studentName': studentName.trim(),
      if (submittedByUid != null && submittedByUid.trim().isNotEmpty)
        'submittedByUid': submittedByUid.trim(),
      'clientSubmittedAt': ApiFieldValue.serverTimestamp(),
    };
    if (awaiting) {
      if (code.isNotEmpty) payload['sessionCodeRaw'] = code;
    } else {
      payload['sessionId'] = sid;
      payload['listId'] = lid;
      payload['course'] = (course ?? '').trim().isNotEmpty ? course!.trim() : '—';
      if (code.isNotEmpty) payload['sessionCodeRaw'] = code;
    }
    return payload;
  }
}

abstract final class AttendanceRecordRtdSync {
  static const statsRoot = 'attendance_stats';

  static String sessionRecordsPath(String sessionId) =>
      'sessions/${sessionId.trim()}/records';

  static String sessionStatsPath(String sessionId) =>
      '$statsRoot/by_session/${sessionId.trim()}';

  static String studentRecordsPath(String studentId) =>
      'students/${StudentRegistrationNumber.normalize(studentId)}/records';

  static String studentRollStatsPath(String studentId) =>
      '$statsRoot/by_student/${StudentRegistrationNumber.normalize(studentId)}';

  static String studentListRollStatsPath(String studentId, String listId) =>
      '${studentRollStatsPath(studentId)}/by_list/${listId.trim()}';

  static String listSessionStatsPath(String listId, String sessionId) =>
      '$statsRoot/by_list/${listId.trim()}/by_session/${sessionId.trim()}';

  static AttendanceRecord? recordFromRtdValue({
    required String sessionId,
    required String studentId,
    required dynamic value,
    String? recordId,
    String? listIdHint,
    String? studentIdHint,
  }) =>
      null;
}

abstract final class SessionRtdSync {
  static bool get pluginAvailable => isApiConfigured;

  static void markPluginUnavailable(Object error) {}

  static Stream<List<AttendanceSession>> watchByCode(String code) {
    if (!isApiConfigured) {
      return const Stream<List<AttendanceSession>>.empty();
    }
    final normalized = normalizeSessionCodeInput(code);
    return apiStore()
        .collection(ApiCollections.attendanceSessions)
        .where('sessionCode', isEqualTo: normalized)
        .limit(16)
        .snapshots(interval: const Duration(seconds: 3))
        .map(
          (snap) => snap.docs
              .map(AttendanceRepository.trySessionFromApiDoc)
              .whereType<AttendanceSession>()
              .toList(),
        );
  }

  static Future<List<AttendanceSession>> fetchByCode(String code) async {
    if (!isApiConfigured) return const [];
    final normalized = normalizeSessionCodeInput(code);
    final snap = await apiStore()
        .collection(ApiCollections.attendanceSessions)
        .where('sessionCode', isEqualTo: normalized)
        .limit(16)
        .get();
    return snap.docs
        .map(AttendanceRepository.trySessionFromApiDoc)
        .whereType<AttendanceSession>()
        .toList();
  }

  static Future<List<AttendanceSession>> fetchByListId(String listId) async {
    if (!isApiConfigured) return const [];
    final snap = await apiStore()
        .collection(ApiCollections.attendanceSessions)
        .where('listId', isEqualTo: listId.trim())
        .limit(32)
        .get();
    return snap.docs
        .map(AttendanceRepository.trySessionFromApiDoc)
        .whereType<AttendanceSession>()
        .toList();
  }

  static Future<AttendanceSession?> fetchById(String sessionId) async {
    if (!isApiConfigured) return null;
    final snap = await apiStore()
        .collection(ApiCollections.attendanceSessions)
        .doc(sessionId.trim())
        .get();
    return AttendanceRepository.trySessionFromApiDoc(snap);
  }

  static Future<List<AttendanceSession>> fetchActiveByCode(String code) async {
    final sessions = await fetchByCode(code);
    return sessions.where((s) => s.isOpenForCheckIn).toList();
  }

  static Future<bool> isRunningOnRtd(String sessionId) async {
    if (!isApiConfigured) return false;
    final session = await fetchById(sessionId);
    return session != null && session.isActive;
  }

  static Future<bool> publishRunningSession(
    AttendanceSession session, {
    String? createdByUid,
    bool locationMetadataPending = false,
    String? listId,
  }) async {
    if (!isApiConfigured) return false;
    try {
      final map = AttendanceRepository.activeSessionToFirestoreMapForSync(
        session: session,
        createdByUid: createdByUid,
        locationMetadataPending: locationMetadataPending,
      );
      await apiStore()
          .collection(ApiCollections.attendanceSessions)
          .doc(session.id)
          .set(map);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> removeRunningSession(String sessionId) async {}
}

String checkInRtdConfirmationKey({
  required String sessionId,
  String? sessionCodeRaw,
}) {
  final code = sessionCodeRaw?.trim().toUpperCase();
  if (code != null && code.isNotEmpty) return code;
  return sessionId.trim();
}
