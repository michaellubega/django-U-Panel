import 'dart:convert';

import '../../core/auth/student_registration_number.dart';
import '../../features/attendance/models/attendance_models.dart';
import 'attendance_local_queues.dart';
import 'local_json_decode.dart';

/// Persists a copy of [AttendanceStore] after each successful Firestore [loadAll].
///
/// Restored when offline or when the network fetch fails so attendance UI still
/// works from the last sync.
class AttendanceLocalSnapshot {
  AttendanceLocalSnapshot._();

  static const _version = 1;

  static String _hiveKey(String userId, String scopeTag) =>
      'attendance_snapshot_v${_version}_${userId}_$scopeTag';

  /// `staff` for admin/QA; `lec:<uid>` for lecturers; `stu:<reg>` for students.
  static String scopeTagFor({
    String? lecturerScopeUid,
    String? studentRegistration,
  }) {
    final reg = studentRegistration?.trim();
    if (reg != null && reg.isNotEmpty) {
      return 'stu:${StudentRegistrationNumber.normalize(reg)}';
    }
    final u = lecturerScopeUid?.trim();
    if (u != null && u.isNotEmpty) return 'lec:$u';
    return 'staff';
  }

  static Future<void> save({
    required String userId,
    required String scopeTag,
    required int codeCounter,
  }) async {
    final uid = userId.trim();
    if (uid.isEmpty) return;
    final payload = <String, dynamic>{
      'v': _version,
      'syncedAt': DateTime.now().toUtc().toIso8601String(),
      'scope': scopeTag,
      'codeCounter': codeCounter,
      'lists': AttendanceStore.lists.map(_listToJson).toList(),
      'sessions': AttendanceStore.sessions.map(_sessionToJson).toList(),
      'students': AttendanceStore.students.map(_studentToJson).toList(),
      'signIns': AttendanceStore.signIns.map(_signInToJson).toList(),
      'records': AttendanceStore.attendanceRecords.map(_recordToJson).toList(),
    };
    await AttendanceLocalQueues.writeString(
      _hiveKey(uid, scopeTag),
      jsonEncode(payload),
    );
  }

  /// Returns sync time when a snapshot was applied; null if none / invalid.
  static Future<DateTime?> restore({
    required String userId,
    required String scopeTag,
  }) async {
    final uid = userId.trim();
    if (uid.isEmpty) return null;
    final key = _hiveKey(uid, scopeTag);
    final raw = await AttendanceLocalQueues.readString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = await decodeStoredJson<Map<String, dynamic>>(
        raw: raw,
        storageKey: key,
        removeKey: AttendanceLocalQueues.removeKey,
        parse: (decoded) =>
            decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{},
        debugLabel: 'AttendanceLocalSnapshot',
      );
      if (m == null || m.isEmpty) return null;
      if ((m['v'] as num?)?.toInt() != _version) return null;
      final lists = (m['lists'] as List<dynamic>?)
              ?.map((e) => _listFromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const <AttendanceList>[];
      final sessions = (m['sessions'] as List<dynamic>?)
              ?.map((e) => _sessionFromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const <AttendanceSession>[];
      final students = (m['students'] as List<dynamic>?)
              ?.map((e) => _studentFromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const <StudentRecord>[];
      final signIns = (m['signIns'] as List<dynamic>?)
              ?.map((e) => _signInFromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const <SignInRecord>[];
      final records = (m['records'] as List<dynamic>?)
              ?.map((e) => _recordFromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const <AttendanceRecord>[];
      if (lists.isEmpty &&
          sessions.isEmpty &&
          students.isEmpty &&
          records.isEmpty &&
          signIns.isEmpty) {
        return null;
      }

      AttendanceStore.lists
        ..clear()
        ..addAll(lists);
      AttendanceStore.sessions
        ..clear()
        ..addAll(sessions);
      AttendanceStore.students
        ..clear()
        ..addAll(students);
      AttendanceStore.signIns
        ..clear()
        ..addAll(signIns);
      AttendanceStore.attendanceRecords
        ..clear()
        ..addAll(records);
      AttendanceStore.invalidateLookupCaches();
      final cc = (m['codeCounter'] as num?)?.toInt();
      if (cc != null) {
        AttendanceStore.setCodeCounter(cc);
      }
      final syncedRaw = m['syncedAt'] as String?;
      if (syncedRaw == null) return DateTime.now();
      return DateTime.tryParse(syncedRaw);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _listToJson(AttendanceList l) => {
        'id': l.id,
        'time': l.time,
        'room': l.room,
        'whoTaught': l.whoTaught,
        'dateMs': l.date.millisecondsSinceEpoch,
        'program': l.program.name,
        'courses': l.coursesSafe,
        'year': l.year,
        'sem': l.sem,
        'createdBy': l.createdBy,
        'lecturerUid': l.lecturerUid,
        'expectedParticipants': l.expectedParticipants,
        'status': l.status.name,
        'lecturerSignCode': l.lecturerSignCode,
        'lecturerSignedAtMs': l.lecturerSignedAt?.millisecondsSinceEpoch,
        'courseUnitName': l.courseUnitName,
      };

  static AttendanceList _listFromJson(Map<String, dynamic> m) {
    final dateMs = (m['dateMs'] as num?)?.toInt();
    return AttendanceList(
      id: m['id'] as String? ?? '',
      time: m['time'] as String? ?? '',
      room: m['room'] as String? ?? '',
      whoTaught: m['whoTaught'] as String? ?? '',
      date: dateMs != null
          ? DateTime.fromMillisecondsSinceEpoch(dateMs)
          : DateTime.now(),
      program: AttendanceProgram.fromStorage(m['program'] as String?),
      courses: (m['courses'] as List<dynamic>?)?.cast<String>(),
      year: m['year'] as String? ?? '1',
      sem: m['sem'] as String? ?? '1',
      createdBy: m['createdBy'] as String?,
      lecturerUid: (m['lecturerUid'] as String?)?.trim(),
      expectedParticipants: (m['expectedParticipants'] as num?)?.toInt(),
      status: _listStatusFrom(m['status'] as String?),
      lecturerSignCode: (m['lecturerSignCode'] as String?)?.trim().isEmpty == true
          ? null
          : m['lecturerSignCode'] as String?,
      lecturerSignedAt: (m['lecturerSignedAtMs'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (m['lecturerSignedAtMs'] as num).toInt(),
            )
          : null,
      courseUnitName: (m['courseUnitName'] as String?)?.trim().isEmpty == true
          ? null
          : (m['courseUnitName'] as String?)?.trim(),
    );
  }

  static AttendanceListStatus _listStatusFrom(String? v) {
    if (v == 'active') return AttendanceListStatus.active;
    if (v == 'closed') return AttendanceListStatus.closed;
    return AttendanceListStatus.draft;
  }

  static Map<String, dynamic> _sessionToJson(AttendanceSession s) => {
        'id': s.id,
        'listId': s.listId,
        'sessionCode': s.sessionCode,
        'latitude': s.latitude,
        'longitude': s.longitude,
        'radiusMeters': s.radiusMeters,
        'startTimeMs': s.startTime.millisecondsSinceEpoch,
        'endTimeMs': s.endTime.millisecondsSinceEpoch,
        'status': s.status.name,
        'createdBy': s.createdBy,
        if (s.remoteLearning) 'remoteLearning': true,
      };

  static AttendanceSession _sessionFromJson(Map<String, dynamic> m) {
    final startMs = (m['startTimeMs'] as num?)?.toInt();
    final endMs = (m['endTimeMs'] as num?)?.toInt();
    final start = startMs != null
        ? DateTime.fromMillisecondsSinceEpoch(startMs)
        : DateTime.now();
    final end = endMs != null
        ? DateTime.fromMillisecondsSinceEpoch(endMs)
        : start;
    return AttendanceSession(
      id: m['id'] as String? ?? '',
      listId: m['listId'] as String? ?? '',
      sessionCode: m['sessionCode'] as String? ?? '',
      latitude: (m['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (m['longitude'] as num?)?.toDouble() ?? 0,
      radiusMeters: (m['radiusMeters'] as num?)?.toDouble() ?? 50,
      startTime: start,
      endTime: end,
      status: m['status'] == 'closed'
          ? SessionStatus.closed
          : SessionStatus.active,
      createdBy: m['createdBy'] as String? ?? '',
      remoteLearning: m['remoteLearning'] == true,
    );
  }

  static Map<String, dynamic> _studentToJson(StudentRecord s) => {
        'id': s.id,
        'name': s.name,
        'registrationNumber': s.registrationNumber,
        'threeDigitCode': s.threeDigitCode,
        'initials': s.initials,
      };

  static StudentRecord _studentFromJson(Map<String, dynamic> m) => StudentRecord(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        registrationNumber: m['registrationNumber'] as String? ?? '',
        threeDigitCode: m['threeDigitCode'] as String? ?? '000',
        initials: m['initials'] as String? ?? 'NA',
      );

  static Map<String, dynamic> _signInToJson(SignInRecord s) => {
        'id': s.id,
        'listId': s.listId,
        'studentId': s.studentId,
        'course': s.course,
        'signedInAtMs': s.signedInAt.millisecondsSinceEpoch,
        if (s.studentName != null && s.studentName!.trim().isNotEmpty)
          'studentName': s.studentName!.trim(),
        if (s.registrationNumber != null &&
            s.registrationNumber!.trim().isNotEmpty)
          'registrationNumber': s.registrationNumber!.trim().toUpperCase(),
      };

  static SignInRecord _signInFromJson(Map<String, dynamic> m) => SignInRecord(
        id: m['id'] as String? ?? '',
        listId: m['listId'] as String? ?? '',
        studentId: m['studentId'] as String? ?? '',
        course: m['course'] as String? ?? '',
        signedInAt: (m['signedInAtMs'] as num?) != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (m['signedInAtMs'] as num).toInt(),
              )
            : DateTime.now(),
        studentName: (m['studentName'] as String?)?.trim(),
        registrationNumber: (m['registrationNumber'] as String?)?.trim(),
      );

  static Map<String, dynamic> _recordToJson(AttendanceRecord r) => {
        'id': r.id,
        'sessionId': r.sessionId,
        'studentId': r.studentId,
        'course': r.course,
        'timestampMs': r.timestamp.millisecondsSinceEpoch,
        'latitude': r.latitude,
        'longitude': r.longitude,
        'verified': r.verified,
        'present': r.present,
        'deviceId': r.deviceId,
      };

  static AttendanceRecord _recordFromJson(Map<String, dynamic> m) =>
      AttendanceRecord(
        id: m['id'] as String? ?? '',
        sessionId: m['sessionId'] as String? ?? '',
        studentId: m['studentId'] as String? ?? '',
        course: m['course'] as String? ?? '',
        timestamp: (m['timestampMs'] as num?) != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (m['timestampMs'] as num).toInt(),
              )
            : DateTime.now(),
        latitude: (m['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (m['longitude'] as num?)?.toDouble() ?? 0,
        verified: m['verified'] as bool? ?? false,
        present: m['present'] as bool? ?? true,
        deviceId: m['deviceId'] as String?,
      );
}
