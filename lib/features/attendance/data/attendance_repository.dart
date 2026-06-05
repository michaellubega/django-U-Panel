import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/auth/auth_repository.dart';
import '../../../core/auth/staff_auth_email.dart';
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import '../../../core/push/push_controller.dart';
import '../../../core/storage/attendance_local_snapshot.dart';
import '../attendance_list_hierarchy.dart';
import '../../notices/data/notices_repository.dart';
import '../check_in_validation.dart';
import '../models/attendance_models.dart';
import 'pending_check_in_queue.dart';
import 'pending_session_code_queue.dart';
import 'pending_session_create_queue.dart';

/// Result of [AttendanceRepository.createSession].
typedef SessionCreateResult = ({
  AttendanceSession session,
  bool syncedToServer,
  String? sessionNoticeError,
});

/// Result of [AttendanceRepository.submitStudentCheckInWithOfflineSupport].
enum StudentOfflineCheckInOutcome {
  success,
  queuedOffline,
  duplicate,
  deviceBlocked,
}

/// Repository that persists attendance data to Firestore and keeps
/// [AttendanceStore] in sync for in-memory reads.
class AttendanceRepository {
  AttendanceRepository._();
  static final AttendanceRepository instance = AttendanceRepository._();

  /// When the signed-in user is a lecturer (not admin), loads are scoped to their lists.
  static String? currentLecturerLoadScopeUid() {
    final a = AuthRepository.instance;
    if (!a.isLoggedIn || !a.adminCheckDone || !a.lecturerCheckDone) return null;
    if (a.isLecturer && !a.isAdmin) {
      return a.currentFirebaseUid;
    }
    return null;
  }

  static const Duration _writeTimeout = Duration(seconds: 6);
  static const Duration _sessionPublishTimeout = Duration(seconds: 4);

  final FirebaseFirestore _firestore = uPanelFirestore();

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  /// True when [AttendanceStore] already has data (memory or restored snapshot).
  bool get hasCachedStore => _isLoaded || !_storeLooksEmpty();

  /// True when the store was filled from disk because Firestore is unavailable.
  bool get isUsingLocalSnapshot => _usingLocalSnapshot;

  /// When [isUsingLocalSnapshot] or after a successful online [loadAll].
  DateTime? get localSnapshotSyncedAt => _localSnapshotSyncedAt;

  bool _usingLocalSnapshot = false;
  DateTime? _localSnapshotSyncedAt;

  /// Bumped on sign-out so in-flight [loadAll] results are ignored.
  int _loadGeneration = 0;

  bool _loadsAllowedForSession(int generationAtStart) =>
      generationAtStart == _loadGeneration &&
      AuthRepository.instance.isLoggedIn;

  /// Clears in-memory attendance after sign-out so the next user does not see stale data.
  void resetForSignOut() {
    _loadGeneration++;
    _loadAllSerialized = Future<void>.value();
    AttendanceStore.lists.clear();
    AttendanceStore.sessions.clear();
    AttendanceStore.students.clear();
    AttendanceStore.signIns.clear();
    AttendanceStore.attendanceRecords.clear();
    AttendanceStore.invalidateLookupCaches();
    _isLoaded = false;
    _loadScopeLecturerUid = null;
    _usingLocalSnapshot = false;
    _localSnapshotSyncedAt = null;
  }

  /// When non-null, [loadAll] last completed a lecturer-scoped fetch for this uid.
  String? _loadScopeLecturerUid;

  /// Ensures two [loadAll] calls never interleave: concurrent reloads can each
  /// replace [AttendanceStore.attendanceRecords] and drop a present row that
  /// another caller just wrote (e.g. offline drain + pending session drain).
  Future<void> _loadAllSerialized = Future<void>.value();

  /// Roll finalize uses this when no course is known; never persist it on a
  /// present row after upgrade — resolve a real course from roster/list.
  static const String _unknownCourseMarker = '\u2014';

  static bool _isPlaceholderCourse(String c) {
    final t = c.trim();
    return t.isEmpty || t == _unknownCourseMarker || t == '-';
  }

  /// Prefer the check-in attempt course; otherwise sign-in, list roster, or
  /// first list course so UI does not show a bare dash for present rows.
  String _resolvePresentCourseForSession(
    String sessionId,
    String studentId,
    String attemptCourse,
  ) {
    if (!_isPlaceholderCourse(attemptCourse)) {
      return attemptCourse.trim();
    }
    final session = AttendanceStore.sessionById(sessionId);
    final listId = session?.listId ?? '';
    if (listId.isEmpty) {
      return 'Course';
    }
    final signed =
        AttendanceStore.signedInCourseForStudentOnList(listId, studentId)
            ?.trim();
    if (signed != null && !_isPlaceholderCourse(signed)) {
      return signed;
    }
    final fromList =
        AttendanceStore.courseForStudentOnList(listId, studentId).trim();
    if (!_isPlaceholderCourse(fromList)) {
      return fromList;
    }
    final list = AttendanceStore.listById(listId);
    final courses = list?.coursesSafe ?? const <String>[];
    if (courses.isNotEmpty) {
      return courses.first;
    }
    return 'Course';
  }

  /// Session ids that still have local-only work — do not finalize roll yet.
  Future<Set<String>> _sessionIdsWithPendingWork() async {
    final ids = <String>{};
    for (final e in await PendingSessionCreateQueue.loadAll()) {
      ids.add(e.sessionId);
    }
    for (final e in await PendingCheckInQueue.loadAll()) {
      ids.add(e.sessionId);
    }
    for (final e in await PendingSessionCodeQueue.loadAll()) {
      final sid = e.sessionId?.trim();
      if (sid != null && sid.isNotEmpty) ids.add(sid);
    }
    return ids;
  }

  /// Present local rows win over remote absent; pending queues overlay as present.
  static AttendanceRecord _pickPreferredAttendanceRecord(
    AttendanceRecord? a,
    AttendanceRecord b,
  ) {
    if (a == null) return b;
    if (a.present && !b.present) return a;
    if (b.present && !a.present) return b;
    return b.timestamp.isAfter(a.timestamp) ? b : a;
  }

  Future<void> _replaceStoreFromRemote({
    required List<AttendanceList> remoteLists,
    required List<AttendanceSession> remoteSessions,
    required List<AttendanceRecord> remoteRecords,
    required List<StudentRecord> remoteStudents,
    required List<SignInRecord> remoteSignIns,
  }) async {
    if (!AuthRepository.instance.isLoggedIn) return;

    final priorLists = List<AttendanceList>.from(AttendanceStore.lists);
    final priorSessions = List<AttendanceSession>.from(AttendanceStore.sessions);
    final priorRecords =
        List<AttendanceRecord>.from(AttendanceStore.attendanceRecords);

    final pendingCreates = await PendingSessionCreateQueue.loadAll();
    final pendingCheckIns = await PendingCheckInQueue.loadAll();
    final pendingCodes = await PendingSessionCodeQueue.loadAll();

    final listsById = {for (final l in remoteLists) l.id: l};
    for (final e in pendingCreates) {
      final prior = priorLists.where((l) => l.id == e.listId).firstOrNull;
      if (prior != null) {
        listsById.putIfAbsent(e.listId, () => prior);
      }
    }

    final sessionsById = {for (final s in remoteSessions) s.id: s};
    for (final e in pendingCreates) {
      final prior =
          priorSessions.where((s) => s.id == e.sessionId).firstOrNull;
      if (prior != null) {
        sessionsById.putIfAbsent(e.sessionId, () => prior);
      } else if (!sessionsById.containsKey(e.sessionId)) {
        sessionsById[e.sessionId] = AttendanceSession(
          id: e.sessionId,
          listId: e.listId,
          sessionCode: e.sessionCode,
          latitude: e.latitude,
          longitude: e.longitude,
          radiusMeters: e.radiusMeters,
          startTime: e.startTime,
          endTime: e.endTime,
          status: SessionStatus.active,
          createdBy: e.createdBy,
          remoteLearning: e.remoteLearning,
        );
      }
    }
    for (final s in priorSessions) {
      final hasPending = pendingCreates.any((e) => e.sessionId == s.id) ||
          pendingCheckIns.any((e) => e.sessionId == s.id) ||
          pendingCodes.any((e) => e.sessionId == s.id);
      if (hasPending) {
        sessionsById.putIfAbsent(s.id, () => s);
      }
    }

    final recordsById = <String, AttendanceRecord>{
      for (final r in remoteRecords) r.id: r,
    };
    for (final r in priorRecords) {
      final existing = recordsById[r.id];
      recordsById[r.id] = _pickPreferredAttendanceRecord(existing, r);
    }
    for (final e in pendingCheckIns) {
      final rec = e.toAttendanceRecord();
      final existing = recordsById[rec.id];
      recordsById[rec.id] = _pickPreferredAttendanceRecord(existing, rec);
    }
    final studentByReg = <String, StudentRecord>{
      for (final s in remoteStudents)
        s.registrationNumber.trim().toUpperCase(): s,
    };
    for (final e in pendingCodes) {
      final sid = e.sessionId?.trim();
      if (sid == null || sid.isEmpty) continue;
      final student = studentByReg[e.registrationNumber.trim().toUpperCase()];
      if (student == null) continue;
      final rec = AttendanceRecord(
        id: attendanceRecordIdForSessionStudent(sid, student.id),
        sessionId: sid,
        studentId: student.id,
        course: '',
        timestamp: e.capturedAt,
        latitude: e.latitude,
        longitude: e.longitude,
        selfieStoragePath: null,
        verified: true,
        present: true,
        deviceId: e.deviceId,
      );
      final existing = recordsById[rec.id];
      recordsById[rec.id] = _pickPreferredAttendanceRecord(existing, rec);
    }

    AttendanceStore.lists
      ..clear()
      ..addAll(listsById.values);
    AttendanceStore.sessions
      ..clear()
      ..addAll(sessionsById.values);
    AttendanceStore.attendanceRecords
      ..clear()
      ..addAll(recordsById.values);
    AttendanceStore.students
      ..clear()
      ..addAll(remoteStudents);
    AttendanceStore.signIns
      ..clear()
      ..addAll(remoteSignIns);
    AttendanceStore.invalidateLookupCaches();
  }

  /// Closes expired-but-still-open sessions and writes absent rows (idempotent).
  Future<void> _finalizeExpiredOpenSessions() async {
    final pendingWork = await _sessionIdsWithPendingWork();
    final expiredOpenIds = AttendanceStore.sessions
        .where((s) =>
            s.isExpired &&
            s.status == SessionStatus.active &&
            !pendingWork.contains(s.id))
        .map((s) => s.id)
        .toList();
    for (final sid in expiredOpenIds) {
      try {
        await closeSessionInFirestore(sid);
        unawaited(_finalizeRollForSessionSafe(sid));
      } catch (_) {}
    }
  }

  Future<void> _finalizeRollForSessionSafe(String sessionId) async {
    try {
      await finalizeRollForSession(sessionId);
    } catch (_) {}
  }

  /// Load all data from Firestore into [AttendanceStore].
  /// Use [force] to refetch (e.g. after QA starts a session so students see it).
  /// On failure, keeps store as-is so attendance works locally without Firebase.
  ///
  /// Invocations are serialized so two overlapping [loadAll] calls cannot each
  /// clear and repopulate the store with stale snapshots.
  /// [scopeToLecturerUid]: when set, only loads lists for that lecturer plus
  /// related sessions, sign-ins, records (batched) and all [students] (MVP).
  Future<void> loadAll({
    bool force = false,
    String? scopeToLecturerUid,
  }) {
    final run = _loadAllSerialized.then(
      (_) => _executeLoadAll(force, scopeToLecturerUid),
    );
    _loadAllSerialized = run.catchError((Object? _, StackTrace? __) {});
    return run;
  }

  /// Per-value equality queries work with lecturer security rules; [whereIn] often does not.
  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _queryDocsWhereFieldEquals({
    required CollectionReference<Map<String, dynamic>> collection,
    required String field,
    required List<String> values,
  }) async {
    final out = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final value in values) {
      final v = value.trim();
      if (v.isEmpty) continue;
      try {
        final snap = await collection.where(field, isEqualTo: v).get();
        out.addAll(snap.docs);
      } catch (_) {}
    }
    return out;
  }

  String? _snapshotUserId() =>
      AuthRepository.instance.currentFirebaseUid?.trim();

  String _scopeTagFor(String? lecturerScopeUid) =>
      AttendanceLocalSnapshot.scopeTagFor(lecturerScopeUid: lecturerScopeUid);

  Future<bool> _restoreLocalSnapshot(
    String? lecturerScopeUid, {
    required int loadGeneration,
  }) async {
    if (!_loadsAllowedForSession(loadGeneration)) return false;
    final uid = _snapshotUserId();
    if (uid == null || uid.isEmpty) return false;
    final tag = _scopeTagFor(lecturerScopeUid);
    final syncedAt = await AttendanceLocalSnapshot.restore(
      userId: uid,
      scopeTag: tag,
    );
    if (syncedAt == null) return false;
    if (!_loadsAllowedForSession(loadGeneration)) return false;
    _localSnapshotSyncedAt = syncedAt;
    _usingLocalSnapshot = true;
    _isLoaded = true;
    _loadScopeLecturerUid =
        lecturerScopeUid != null && lecturerScopeUid.isNotEmpty
            ? lecturerScopeUid
            : null;
    return true;
  }

  Future<void> _persistLocalSnapshot(String? lecturerScopeUid) async {
    final uid = _snapshotUserId();
    if (uid == null || uid.isEmpty) return;
    int maxCode = 100;
    for (final s in AttendanceStore.students) {
      final n = int.tryParse(s.threeDigitCode);
      if (n != null && n > maxCode) maxCode = n;
    }
    await AttendanceLocalSnapshot.save(
      userId: uid,
      scopeTag: _scopeTagFor(lecturerScopeUid),
      codeCounter: maxCode + 1,
    );
    _localSnapshotSyncedAt = DateTime.now();
    _usingLocalSnapshot = false;
  }

  bool _storeLooksEmpty() =>
      AttendanceStore.lists.isEmpty &&
      AttendanceStore.sessions.isEmpty &&
      AttendanceStore.students.isEmpty &&
      AttendanceStore.attendanceRecords.isEmpty &&
      AttendanceStore.signIns.isEmpty;

  Future<void> _executeLoadAll(bool force, String? scopeToLecturerUid) async {
    final loadGeneration = _loadGeneration;
    if (!_loadsAllowedForSession(loadGeneration)) return;

    final explicitScope = scopeToLecturerUid?.trim();
    final effectiveScope = (explicitScope != null && explicitScope.isNotEmpty)
        ? explicitScope
        : currentLecturerLoadScopeUid();
    if (effectiveScope != null && effectiveScope.isNotEmpty) {
      await _executeLoadAllForLecturer(force, effectiveScope);
      return;
    }

    if (_isLoaded && !force && _loadScopeLecturerUid == null) {
      await _finalizeExpiredOpenSessions();
      return;
    }

    final online = AppConnectivity.instance.isOnline;
    if (_storeLooksEmpty()) {
      await _restoreLocalSnapshot(null, loadGeneration: loadGeneration);
    }
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (!online && _isLoaded && !force) {
      await _finalizeExpiredOpenSessions();
      return;
    }

    try {
      final results = await Future.wait<QuerySnapshot<Map<String, dynamic>>>([
        _firestore.collection(FirestoreCollections.attendanceLists).get(),
        _firestore.collection(FirestoreCollections.attendanceSessions).get(),
        _firestore.collection(FirestoreCollections.attendanceRecords).get(),
        _firestore.collection(FirestoreCollections.students).get(),
        _firestore.collection(FirestoreCollections.signIns).get(),
      ]);
      final listsSnap = results[0];
      final sessionsSnap = results[1];
      final recordsSnap = results[2];
      final studentsSnap = results[3];
      final signInsSnap = results[4];

      if (!_loadsAllowedForSession(loadGeneration)) return;

      await _replaceStoreFromRemote(
        remoteLists: listsSnap.docs.map((d) => _listFromDoc(d)).toList(),
        remoteSessions: sessionsSnap.docs.map((d) => _sessionFromDoc(d)).toList(),
        remoteRecords: recordsSnap.docs.map((d) => _recordFromDoc(d)).toList(),
        remoteStudents: studentsSnap.docs.map((d) => _studentFromDoc(d)).toList(),
        remoteSignIns: signInsSnap.docs.map((d) => _signInFromDoc(d)).toList(),
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;
      _updateCodeCounter();
      _isLoaded = true;
      _loadScopeLecturerUid = null;

      await _finalizeExpiredOpenSessions();
      unawaited(PushController.instance.syncListTopicsFromStore());
      unawaited(_persistLocalSnapshot(null));
    } catch (_) {
      if (!_loadsAllowedForSession(loadGeneration)) return;
      if (!_isLoaded) {
        await _restoreLocalSnapshot(null, loadGeneration: loadGeneration);
      }
      if (!_isLoaded) {
        // Keep prior in-memory rows; do not mark loaded so drain can refetch later.
        _usingLocalSnapshot = false;
      }
    }
  }

  Future<void> _executeLoadAllForLecturer(bool force, String uid) async {
    final loadGeneration = _loadGeneration;
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (_isLoaded &&
        !force &&
        _loadScopeLecturerUid == uid) {
      await _finalizeExpiredOpenSessions();
      return;
    }

    final online = AppConnectivity.instance.isOnline;
    if (_storeLooksEmpty()) {
      await _restoreLocalSnapshot(uid, loadGeneration: loadGeneration);
    }
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (!online && _isLoaded && !force) {
      await _finalizeExpiredOpenSessions();
      return;
    }

    try {
      final listsById = <String, AttendanceList>{};
      try {
        final assignedSnap = await _firestore
            .collection(FirestoreCollections.attendanceLists)
            .where('lecturerUid', isEqualTo: uid)
            .get();
        for (final d in assignedSnap.docs) {
          listsById[d.id] = _listFromDoc(d);
        }
      } catch (_) {}
      try {
        final createdSnap = await _firestore
            .collection(FirestoreCollections.attendanceLists)
            .where('createdBy', isEqualTo: uid)
            .get();
        for (final d in createdSnap.docs) {
          listsById.putIfAbsent(d.id, () => _listFromDoc(d));
        }
      } catch (_) {}
      final lists = listsById.values
          .where((l) => attendanceListAccessibleToLecturer(l, uid))
          .toList();
      final listIds = lists.map((l) => l.id).toList();

      final sessionDocs = await _queryDocsWhereFieldEquals(
        collection: _firestore.collection(FirestoreCollections.attendanceSessions),
        field: 'listId',
        values: listIds,
      );
      final sessions = sessionDocs.map(_sessionFromDoc).toList();

      final signInDocs = await _queryDocsWhereFieldEquals(
        collection: _firestore.collection(FirestoreCollections.signIns),
        field: 'listId',
        values: listIds,
      );
      final signIns = signInDocs.map(_signInFromDoc).toList();

      final sessionIds = sessions.map((s) => s.id).toList();
      final recordDocs = await _queryDocsWhereFieldEquals(
        collection:
            _firestore.collection(FirestoreCollections.attendanceRecords),
        field: 'sessionId',
        values: sessionIds,
      );
      final records = recordDocs.map(_recordFromDoc).toList();

      final studentsSnap =
          await _firestore.collection(FirestoreCollections.students).get();

      if (!_loadsAllowedForSession(loadGeneration)) return;

      await _replaceStoreFromRemote(
        remoteLists: lists,
        remoteSessions: sessions,
        remoteRecords: records,
        remoteSignIns: signIns,
        remoteStudents: studentsSnap.docs.map((d) => _studentFromDoc(d)).toList(),
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;
      _updateCodeCounter();
      _isLoaded = true;
      _loadScopeLecturerUid = uid;

      await _finalizeExpiredOpenSessions();
      unawaited(PushController.instance.syncListTopicsFromStore());
      unawaited(_persistLocalSnapshot(uid));
    } catch (_) {
      if (!_loadsAllowedForSession(loadGeneration)) return;
      if (!_isLoaded) {
        await _restoreLocalSnapshot(uid, loadGeneration: loadGeneration);
      }
      if (!_isLoaded) {
        _usingLocalSnapshot = false;
      }
    }
  }

  void _updateCodeCounter() {
    if (AttendanceStore.students.isEmpty) return;
    int maxCode = 0;
    for (final s in AttendanceStore.students) {
      final n = int.tryParse(s.threeDigitCode);
      if (n != null && n > maxCode) maxCode = n;
    }
    AttendanceStore.setCodeCounter(maxCode + 1);
  }

  static AttendanceListStatus _listStatusFrom(String? v) {
    if (v == 'active') return AttendanceListStatus.active;
    if (v == 'closed') return AttendanceListStatus.closed;
    return AttendanceListStatus.draft;
  }

  static AttendanceList _listFromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data()!;
    final date = (data['date'] as Timestamp?)?.toDate() ?? DateTime.now();
    final courses = data['courses'] as List<dynamic>?;
    final rawLc = (data['lecturerSignCode'] as String?)?.trim() ?? '';
    final lecturerCode =
        rawLc.isEmpty ? null : normalizeSessionCodeInput(rawLc);
    final signedTs = data['lecturerSignedAt'] as Timestamp?;
    return AttendanceList(
      id: d.id,
      time: data['time'] as String? ?? '',
      room: data['room'] as String? ?? '',
      whoTaught: data['whoTaught'] as String? ?? '',
      date: date,
      program: AttendanceProgram.fromStorage(data['program'] as String?),
      courses: courses?.cast<String>(),
      year: data['year'] as String? ?? '1',
      sem: data['sem'] as String? ?? '1',
      createdBy: data['createdBy'] as String?,
      lecturerUid: (data['lecturerUid'] as String?)?.trim(),
      expectedParticipants: data['expectedParticipants'] as int?,
      status: _listStatusFrom(data['status'] as String?),
      lecturerSignCode: lecturerCode,
      lecturerSignedAt: signedTs?.toDate(),
      courseUnitName: (data['courseUnitName'] as String?)?.trim().isEmpty == true
          ? null
          : (data['courseUnitName'] as String?)?.trim(),
    );
  }

  static SessionStatus _sessionStatusFrom(String? v) {
    if (v == 'closed') return SessionStatus.closed;
    return SessionStatus.active;
  }

  static AttendanceSession _sessionFromDoc(
      DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data()!;
    final start = (data['startTime'] as Timestamp?)?.toDate() ?? DateTime.now();
    final end = (data['endTime'] as Timestamp?)?.toDate() ?? start;
    return AttendanceSession(
      id: d.id,
      listId: data['listId'] as String? ?? '',
      sessionCode: data['sessionCode'] as String? ?? '',
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0.0,
      radiusMeters: (data['radiusMeters'] as num?)?.toDouble() ?? 50.0,
      startTime: start,
      endTime: end,
      status: _sessionStatusFrom(data['status'] as String?),
      createdBy: data['createdBy'] as String? ?? '',
      remoteLearning: data['remoteLearning'] == true,
    );
  }

  static AttendanceRecord _recordFromDoc(
      DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data()!;
    final ts = (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
    return AttendanceRecord(
      id: d.id,
      sessionId: data['sessionId'] as String? ?? '',
      studentId: data['studentId'] as String? ?? '',
      course: data['course'] as String? ?? '',
      timestamp: ts,
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0.0,
      selfieStoragePath: data['selfieStoragePath'] as String?,
      verified: data['verified'] as bool? ?? false,
      present: data['present'] as bool? ?? true,
      deviceId: data['deviceId'] as String?,
    );
  }

  static StudentRecord _studentFromDoc(
      DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data()!;
    final name = data['name'] as String? ?? '';
    final rawIni = data['initials'] as String?;
    final initials = (rawIni != null && rawIni.trim().isNotEmpty)
        ? normalizeSessionCodeInput(rawIni)
        : deriveStudentInitialsFromName(name);
    return StudentRecord(
      id: d.id,
      name: name,
      registrationNumber: data['registrationNumber'] as String? ?? '',
      threeDigitCode: data['threeDigitCode'] as String? ?? '000',
      initials: initials,
    );
  }

  static SignInRecord _signInFromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data()!;
    final signedInAt =
        (data['signedInAt'] as Timestamp?)?.toDate() ?? DateTime.now();
    return SignInRecord(
      id: d.id,
      listId: data['listId'] as String? ?? '',
      studentId: data['studentId'] as String? ?? '',
      course: data['course'] as String? ?? '',
      signedInAt: signedInAt,
    );
  }

  /// Firestore map for list docs (used by offline session upload worker).
  static Map<String, dynamic> listToFirestoreMapForSync(AttendanceList list) =>
      _listToMap(list);

  static Map<String, dynamic> _listToMap(AttendanceList list) {
    final map = <String, dynamic>{
      'time': list.time,
      'room': list.room,
      'whoTaught': list.whoTaught,
      'date': Timestamp.fromDate(list.date),
      'program': list.program.name,
      'courses': list.courses ?? list.coursesSafe.toList(),
      'year': list.year,
      'sem': list.sem,
      'status': list.status.name,
    };
    if (list.createdBy != null) map['createdBy'] = list.createdBy!;
    if (list.lecturerUid != null && list.lecturerUid!.trim().isNotEmpty) {
      map['lecturerUid'] = list.lecturerUid!.trim();
    }
    if (list.expectedParticipants != null) {
      map['expectedParticipants'] = list.expectedParticipants!;
    }
    map['lecturerSignCode'] = list.lecturerSignCode ?? '';
    map['lecturerSignedAt'] = list.lecturerSignedAt != null
        ? Timestamp.fromDate(list.lecturerSignedAt!)
        : null;
    final unit = list.effectiveCourseUnitName;
    if (unit.isNotEmpty) {
      map['courseUnitName'] = unit;
    }
    return map;
  }

  Future<void> addList(AttendanceList list) async {
    AttendanceStore.addList(list);
    try {
      await _firestore
          .collection(FirestoreCollections.attendanceLists)
          .doc(list.id)
          .set(_listToMap(list))
          .timeout(_writeTimeout);
    } catch (e) {
      // Avoid phantom lists that look created locally but do not exist remotely.
      AttendanceStore.removeList(list.id);
      throw Exception('Could not create class list online: $e');
    }
  }

  Future<void> updateList(AttendanceList list) async {
    AttendanceStore.updateList(list);
    try {
      await _firestore
          .collection(FirestoreCollections.attendanceLists)
          .doc(list.id)
          .set(_listToMap(list));
    } catch (_) {}
  }

  /// Resolves a registered lecturer account uid from manual `KIU-####` input.
  Future<String?> resolveLecturerUidByStaffNumber(
    String rawStaffNumber, {
    Iterable<({String uid, String staffNumber})>? knownRows,
  }) async {
    final sn = StaffAuthEmail.normalizeStaffNumberFlexible(rawStaffNumber);
    if (sn == null) return null;

    if (knownRows != null) {
      for (final row in knownRows) {
        if (row.staffNumber.trim().toUpperCase() == sn) {
          return row.uid;
        }
      }
    }

    try {
      final staffSnap = await _firestore
          .collection(FirestoreCollections.staffNumbers)
          .doc(sn)
          .get();
      final fromStaff = (staffSnap.data()?['uid'] as String?)?.trim();
      if (fromStaff != null && fromStaff.isNotEmpty) {
        return fromStaff;
      }
    } catch (_) {}

    try {
      final lectSnap = await _firestore
          .collection(FirestoreCollections.lecturers)
          .where('staffNumber', isEqualTo: sn)
          .limit(1)
          .get();
      if (lectSnap.docs.isNotEmpty) {
        return lectSnap.docs.first.id;
      }
    } catch (_) {}

    return null;
  }

  /// Admin: assigned lecturer from manual KIU staff ID.
  Future<({String? uid, String? error})> resolveAssignedLecturerForAdmin({
    String? selectedUid,
    String manualStaffNumberRaw = '',
    Iterable<({String uid, String staffNumber})>? knownRows,
  }) async {
    final manual = manualStaffNumberRaw.trim();
    if (manual.isEmpty) {
      return (
        uid: null,
        error: 'Enter the assigned lecturer KIU staff ID.',
      );
    }
    final normalized = StaffAuthEmail.normalizeStaffNumberFlexible(manual);
    if (normalized == null) {
      return (
        uid: null,
        error: 'Enter a valid KIU staff ID (e.g. KIU-0042 or 0042).',
      );
    }
    final uid = await resolveLecturerUidByStaffNumber(
      manual,
      knownRows: knownRows,
    );
    if (uid == null) {
      return (
        uid: null,
        error:
            'No lecturer account for $normalized. Register them under Staff & accounts first.',
      );
    }
    return (uid: uid, error: null);
  }

  /// Generate a 3-digit join code not already used by an active session.
  String generateUniqueSessionCode() {
    String code;
    int attempts = 0;
    do {
      code = generateSessionCode();
      final exists = AttendanceStore.sessions.any((s) =>
          s.sessionCode.toUpperCase() == code.toUpperCase() && s.isActive);
      if (!exists) return code;
      attempts++;
    } while (attempts < 50);
    return code; // fallback
  }

  /// Latest active session for [listId], if any (by [AttendanceSession.startTime]).
  AttendanceSession? _activeSessionForList(String listId) {
    AttendanceSession? best;
    for (final s in AttendanceStore.sessions) {
      if (s.listId != listId || !s.isActive) {
        continue;
      }
      if (best == null || s.startTime.isAfter(best.startTime)) {
        best = s;
      }
    }
    return best;
  }

  /// Creates a new active session for [listId], or returns the existing active
  /// session for that list if one is already in [AttendanceStore] (avoids
  /// duplicates from double taps or slow GPS before the first write completes).
  Future<SessionCreateResult> createSession({
    required String listId,
    required String createdBy,
    required double latitude,
    required double longitude,
    required double radiusMeters,
    required Duration durationMinutes,
    bool remoteLearning = false,
  }) async {
    final existing = _activeSessionForList(listId);
    if (existing != null) {
      return (
        session: existing,
        syncedToServer: true,
        sessionNoticeError: null,
      );
    }

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final sessionCode = generateUniqueSessionCode();
    final startTime = DateTime.now();
    final endTime = startTime.add(durationMinutes);
    final session = AttendanceSession(
      id: id,
      listId: listId,
      sessionCode: sessionCode,
      latitude: latitude,
      longitude: longitude,
      radiusMeters: radiusMeters,
      startTime: startTime,
      endTime: endTime,
      status: SessionStatus.active,
      createdBy: createdBy,
      remoteLearning: remoteLearning,
    );
    AttendanceStore.addSession(session);
    unawaited(_persistLocalSnapshot(currentLecturerLoadScopeUid()));
    final online = AppConnectivity.instance.isOnline;
    final list = AttendanceStore.listById(listId);
    if (list != null && list.status != AttendanceListStatus.closed) {
      final updated = AttendanceList(
        id: list.id,
        time: list.time,
        room: list.room,
        whoTaught: list.whoTaught,
        date: list.date,
        program: list.program,
        courses: list.courses ?? list.coursesSafe.toList(),
        year: list.year,
        sem: list.sem,
        createdBy: list.createdBy,
        lecturerUid: list.lecturerUid,
        expectedParticipants: list.expectedParticipants,
        status: AttendanceListStatus.active,
        lecturerSignCode: list.lecturerSignCode,
        lecturerSignedAt: list.lecturerSignedAt,
        courseUnitName: list.courseUnitName,
      );
      AttendanceStore.updateList(updated);
      if (online) {
        try {
          await _firestore
              .collection(FirestoreCollections.attendanceLists)
              .doc(listId)
              .set(_listToMap(updated))
              .timeout(_sessionPublishTimeout);
        } catch (_) {}
      }
    }
    final creatorUid = AuthRepository.instance.currentFirebaseUid?.trim();
    var sessionSynced = false;
    if (online) {
      try {
        final sessionMap = <String, dynamic>{
          'listId': listId,
          'sessionCode': sessionCode,
          'latitude': latitude,
          'longitude': longitude,
          'radiusMeters': radiusMeters,
          'startTime': Timestamp.fromDate(startTime),
          'endTime': Timestamp.fromDate(endTime),
          'status': SessionStatus.active.name,
          'createdBy': createdBy,
        };
        if (creatorUid != null && creatorUid.isNotEmpty) {
          sessionMap['createdByUid'] = creatorUid;
        }
        if (remoteLearning) {
          sessionMap['remoteLearning'] = true;
        }
        await _firestore
            .collection(FirestoreCollections.attendanceSessions)
            .doc(id)
            .set(sessionMap)
            .timeout(_sessionPublishTimeout);
        sessionSynced = true;
        await PendingSessionCreateQueue.removeBySessionId(id);
      } catch (_) {
        await PendingSessionCreateQueue.enqueue(
          PendingSessionCreateEntry(
            sessionId: id,
            listId: listId,
            sessionCode: sessionCode,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            startTime: startTime,
            endTime: endTime,
            createdBy: createdBy,
            remoteLearning: remoteLearning,
            enqueuedAt: DateTime.now(),
          ),
        );
      }
    } else {
      await PendingSessionCreateQueue.enqueue(
        PendingSessionCreateEntry(
          sessionId: id,
          listId: listId,
          sessionCode: sessionCode,
          latitude: latitude,
          longitude: longitude,
          radiusMeters: radiusMeters,
          startTime: startTime,
          endTime: endTime,
          createdBy: createdBy,
          remoteLearning: remoteLearning,
          enqueuedAt: DateTime.now(),
        ),
      );
    }
    String? sessionNoticeError;
    if (sessionSynced && !remoteLearning) {
      final listForNotice = AttendanceStore.listById(listId);
      if (listForNotice != null) {
        sessionNoticeError =
            await NoticesRepository.instance.publishSessionStartNotice(
          list: listForNotice,
          session: session,
          createdBy: createdBy,
        );
      }
    }
    unawaited(
      _persistLocalSnapshot(currentLecturerLoadScopeUid()),
    );
    return (
      session: session,
      syncedToServer: sessionSynced,
      sessionNoticeError: sessionNoticeError,
    );
  }

  /// Returns session if code is valid, active, and not expired. Null otherwise.
  AttendanceSession? validateSessionCode(String code) {
    return AttendanceStore.sessionByCode(normalizeSessionCodeInput(code));
  }

  /// Fetches session documents matching [rawCode] from Firestore and merges them
  /// into [AttendanceStore]. Use when [validateSessionCode] is null after
  /// [loadAll] (session started after load, or first targeted fetch).
  Future<AttendanceSession?> resolveSessionByCode(String rawCode) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) return null;
    try {
      final snap = await _firestore
          .collection(FirestoreCollections.attendanceSessions)
          .where('sessionCode', isEqualTo: code)
          .limit(8)
          .get();
      AttendanceSession? best;
      for (final d in snap.docs) {
        final session = _sessionFromDoc(d);
        final i =
            AttendanceStore.sessions.indexWhere((s) => s.id == session.id);
        if (i >= 0) {
          AttendanceStore.updateSession(session);
        } else {
          AttendanceStore.addSession(session);
        }
        if (session.isActive &&
            (best == null || session.endTime.isAfter(best.endTime))) {
          best = session;
        }
      }
      if (best != null) {
        await _ensureListLoaded(best.listId);
      }
      return best ?? AttendanceStore.sessionByCode(code);
    } catch (_) {
      return AttendanceStore.sessionByCode(code);
    }
  }

  /// Resolves the latest session for [rawCode] regardless of active/expired.
  ///
  /// Useful for UX decisions (e.g. distinguishing "expired" from "not found")
  /// when online sign-in cannot find an active session.
  Future<AttendanceSession?> resolveLatestSessionByCode(String rawCode) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) return null;
    try {
      final snap = await _firestore
          .collection(FirestoreCollections.attendanceSessions)
          .where('sessionCode', isEqualTo: code)
          .limit(16)
          .get();
      AttendanceSession? latest;
      for (final d in snap.docs) {
        final session = _sessionFromDoc(d);
        final i =
            AttendanceStore.sessions.indexWhere((s) => s.id == session.id);
        if (i >= 0) {
          AttendanceStore.updateSession(session);
        } else {
          AttendanceStore.addSession(session);
        }
        if (latest == null || session.endTime.isAfter(latest.endTime)) {
          latest = session;
        }
      }
      final localLatest = AttendanceStore.sessions
          .where((s) => normalizeSessionCodeInput(s.sessionCode) == code)
          .fold<AttendanceSession?>(
            null,
            (best, s) =>
                best == null || s.endTime.isAfter(best.endTime) ? s : best,
          );
      final picked = latest ?? localLatest;
      if (picked != null) {
        await _ensureListLoaded(picked.listId);
      }
      return picked;
    } catch (_) {
      return AttendanceStore.sessions
          .where((s) => normalizeSessionCodeInput(s.sessionCode) == code)
          .fold<AttendanceSession?>(
            null,
            (best, s) =>
                best == null || s.endTime.isAfter(best.endTime) ? s : best,
          );
    }
  }

  /// Resolves a session by join code for an event captured at [capturedAt].
  ///
  /// Unlike [resolveSessionByCode], this can return ended/closed sessions when
  /// [capturedAt] falls inside their start/end bounds. This is used by offline
  /// queue replay so delayed sync still validates against the original capture
  /// time instead of "active right now".
  Future<AttendanceSession?> resolveSessionByCodeAtTime({
    required String rawCode,
    required DateTime capturedAt,
  }) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) return null;
    try {
      final snap = await _firestore
          .collection(FirestoreCollections.attendanceSessions)
          .where('sessionCode', isEqualTo: code)
          .limit(16)
          .get();
      AttendanceSession? bounded;
      AttendanceSession? bestActive;
      for (final d in snap.docs) {
        final session = _sessionFromDoc(d);
        final i =
            AttendanceStore.sessions.indexWhere((s) => s.id == session.id);
        if (i >= 0) {
          AttendanceStore.updateSession(session);
        } else {
          AttendanceStore.addSession(session);
        }
        if (isTimestampWithinSessionBounds(session, capturedAt)) {
          if (bounded == null || session.endTime.isAfter(bounded.endTime)) {
            bounded = session;
          }
        }
        if (session.isActive &&
            (bestActive == null ||
                session.endTime.isAfter(bestActive.endTime))) {
          bestActive = session;
        }
      }
      final localCandidates = AttendanceStore.sessions
          .where((s) => normalizeSessionCodeInput(s.sessionCode) == code)
          .toList();
      for (final session in localCandidates) {
        if (isTimestampWithinSessionBounds(session, capturedAt)) {
          if (bounded == null || session.endTime.isAfter(bounded.endTime)) {
            bounded = session;
          }
        }
      }
      final picked = bounded ?? bestActive;
      if (picked != null) {
        await _ensureListLoaded(picked.listId);
      }
      return picked;
    } catch (_) {
      AttendanceSession? bounded;
      for (final session in AttendanceStore.sessions) {
        if (normalizeSessionCodeInput(session.sessionCode) != code) continue;
        if (isTimestampWithinSessionBounds(session, capturedAt)) {
          if (bounded == null || session.endTime.isAfter(bounded.endTime)) {
            bounded = session;
          }
        }
      }
      return bounded ?? AttendanceStore.sessionByCode(code);
    }
  }

  Future<void> _ensureListLoaded(String listId) async {
    if (AttendanceStore.listById(listId) != null) return;
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.attendanceLists)
          .doc(listId)
          .get();
      if (!doc.exists) return;
      final list = _listFromDoc(doc);
      final i = AttendanceStore.lists.indexWhere((l) => l.id == list.id);
      if (i >= 0) {
        AttendanceStore.updateList(list);
      } else {
        AttendanceStore.addList(list);
      }
    } catch (_) {}
  }

  /// Best-effort targeted fetch for one class list.
  Future<AttendanceList?> resolveListById(String listId) async {
    await _ensureListLoaded(listId);
    return AttendanceStore.listById(listId);
  }

  /// Marks the session closed in memory so UI and offline logic stop treating it
  /// as live before Firestore confirms.
  void closeSessionLocally(String sessionId) {
    AttendanceStore.closeSession(sessionId);
  }

  Future<void> _syncSessionClosedToFirestore(String sessionId) async {
    try {
      await _firestore
          .collection(FirestoreCollections.attendanceSessions)
          .doc(sessionId)
          .update(<String, dynamic>{
            'status': SessionStatus.closed.name,
            // Cloud Functions finalize roll + missed notices when this is false.
            'finalized': false,
          });
    } catch (_) {}
  }

  Future<void> closeSessionInFirestore(String sessionId) async {
    if (AttendanceStore.sessionById(sessionId) == null) return;
    closeSessionLocally(sessionId);
    await _syncSessionClosedToFirestore(sessionId);
  }

  /// After the UI has dismissed, push closed status and finalize the roll.
  Future<void> syncClosedSessionAndFinalizeRoll(String sessionId) async {
    if (AttendanceStore.sessionById(sessionId) == null) return;
    await _syncSessionClosedToFirestore(sessionId);
    await _finalizeRollForSessionSafe(sessionId);
  }

  /// Closes the session then writes absent rows for roster students who did not
  /// check in (one row per student per session, id `sessionId_studentId`).
  ///
  /// When [dismissImmediately] is true, the caller should pop UI right after this
  /// returns (local close only); remote close + roll run in the background.
  ///
  /// When [finalizeInBackground] is true (and not [dismissImmediately]), only the
  /// session status update is awaited before finalize runs in the background.
  Future<void> closeSessionAndFinalizeRoll(
    String sessionId, {
    bool finalizeInBackground = false,
    bool dismissImmediately = false,
  }) async {
    if (AttendanceStore.sessionById(sessionId) == null) return;
    if (dismissImmediately) {
      closeSessionLocally(sessionId);
      unawaited(syncClosedSessionAndFinalizeRoll(sessionId));
      return;
    }
    await closeSessionInFirestore(sessionId);
    if (finalizeInBackground) {
      unawaited(_finalizeRollForSessionSafe(sessionId));
      return;
    }
    await finalizeRollForSession(sessionId);
  }

  /// For everyone on the list roster (sign-ins) plus anyone who checked in,
  /// ensures an [AttendanceRecord] exists. Missing rows are marked absent.
  Future<void> finalizeRollForSession(String sessionId) async {
    final session = AttendanceStore.sessionById(sessionId);
    if (session == null) return;
    final pendingWork = await _sessionIdsWithPendingWork();
    if (pendingWork.contains(sessionId)) return;

    final listId = session.listId;
    final studentIds =
        AttendanceStore.studentIdsForSessionRoll(listId, sessionId);

    final presentStudentIds = <String>{};
    for (final e in await PendingCheckInQueue.loadAll()) {
      if (e.sessionId == sessionId) {
        presentStudentIds.add(e.studentId);
      }
    }
    for (final e in await PendingSessionCodeQueue.loadAll()) {
      if (e.sessionId != sessionId) continue;
      final student =
          AttendanceStore.findStudentByReg(e.registrationNumber);
      if (student != null) presentStudentIds.add(student.id);
    }
    for (final r in AttendanceStore.attendanceRecords) {
      if (r.sessionId == sessionId && r.present) {
        presentStudentIds.add(r.studentId);
      }
    }

    if (AppConnectivity.instance.isOnline) {
      try {
        final snap = await _firestore
            .collection(FirestoreCollections.attendanceRecords)
            .where('sessionId', isEqualTo: sessionId)
            .get();
        for (final d in snap.docs) {
          final data = d.data();
          if (data['present'] != true) continue;
          final sid = (data['studentId'] as String?)?.trim();
          if (sid != null && sid.isNotEmpty) {
            presentStudentIds.add(sid);
          }
        }
      } catch (_) {}
    }

    final pending = <AttendanceRecord>[];
    final ts = DateTime.now();
    for (final studentId in studentIds) {
      if (presentStudentIds.contains(studentId)) continue;
      if (AttendanceStore.isPresentForSession(sessionId, studentId)) continue;
      if (AttendanceStore.hasCheckedIn(sessionId, studentId)) continue;
      var course = AttendanceStore.courseForStudentOnList(listId, studentId);
      if (course.isEmpty) course = '—';
      final record = AttendanceRecord(
        id: attendanceRecordIdForSessionStudent(sessionId, studentId),
        sessionId: sessionId,
        studentId: studentId,
        course: course,
        timestamp: ts,
        latitude: 0,
        longitude: 0,
        selfieStoragePath: null,
        verified: false,
        present: false,
        deviceId: null,
      );
      if (!AttendanceStore.addAttendanceRecordIfAbsent(record)) continue;
      pending.add(record);
    }

    if (pending.isEmpty) return;
    if (!AppConnectivity.instance.isOnline) return;

    await _commitAttendanceRecordsBatch(pending);
  }

  Future<void> _commitAttendanceRecordsBatch(
    List<AttendanceRecord> records,
  ) async {
    const chunkSize = 400;
    for (var i = 0; i < records.length; i += chunkSize) {
      final end = math.min(i + chunkSize, records.length);
      final chunk = records.sublist(i, end);
      final batch = _firestore.batch();
      for (final record in chunk) {
        batch.set(
          _firestore
              .collection(FirestoreCollections.attendanceRecords)
              .doc(record.id),
          _attendanceRecordWritePayload(record),
          SetOptions(merge: true),
        );
      }
      try {
        await batch.commit();
      } catch (_) {}
    }
  }

  Map<String, dynamic> _attendanceRecordToFirestoreMap(
      AttendanceRecord record) {
    return {
      'sessionId': record.sessionId,
      'studentId': record.studentId,
      'course': record.course,
      'timestamp': Timestamp.fromDate(record.timestamp),
      'latitude': record.latitude,
      'longitude': record.longitude,
      'selfieStoragePath': record.selfieStoragePath,
      'verified': record.verified,
      'present': record.present,
      if (record.deviceId != null && record.deviceId!.trim().isNotEmpty)
        'deviceId': record.deviceId!.trim(),
    };
  }

  /// Client attendance fields plus [serverReceivedAt] (Firestore server time).
  /// [SetOptions.merge] on write preserves optional server-only fields not sent here.
  Map<String, dynamic> _attendanceRecordWritePayload(AttendanceRecord record) {
    return {
      ..._attendanceRecordToFirestoreMap(record),
      'serverReceivedAt': FieldValue.serverTimestamp(),
    };
  }

  /// Prevents absent writes when a present row already exists remotely.
  Future<bool> _remoteRecordIsPresent(String recordId) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.attendanceRecords)
          .doc(recordId)
          .get();
      if (!doc.exists) return false;
      final data = doc.data();
      if (data == null) return false;
      return data['present'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Writes [record] to Firestore only; does not modify [AttendanceStore].
  Future<bool> tryWriteAttendanceRecordDocument(AttendanceRecord record) async {
    try {
      await _firestore
          .collection(FirestoreCollections.attendanceRecords)
          .doc(record.id)
          .set(
            _attendanceRecordWritePayload(record),
            SetOptions(merge: true),
          );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Present check-in: adds to [AttendanceStore], then Firestore. On network
  /// failure, keeps the local row and enqueues for [AttendanceOfflineSync.drain].
  Future<StudentOfflineCheckInOutcome> submitStudentCheckInWithOfflineSupport(
    AttendanceRecord record,
  ) async {
    if (record.present) {
      final d = record.deviceId?.trim() ?? '';
      if (d.isNotEmpty &&
          AttendanceStore.hasPresentCheckInForDevice(
            record.sessionId,
            d,
            record.studentId,
          )) {
        return StudentOfflineCheckInOutcome.deviceBlocked;
      }
    }
    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      record.sessionId,
      record.studentId,
    );
    if (existing != null) {
      if (existing.present) {
        return StudentOfflineCheckInOutcome.duplicate;
      }
      final resolvedCourse = _resolvePresentCourseForSession(
        record.sessionId,
        record.studentId,
        record.course,
      );
      final upgraded = AttendanceRecord(
        id: existing.id,
        sessionId: record.sessionId,
        studentId: record.studentId,
        course: resolvedCourse,
        timestamp: record.timestamp,
        latitude: record.latitude,
        longitude: record.longitude,
        selfieStoragePath: record.selfieStoragePath,
        verified: record.verified,
        present: true,
        deviceId: record.deviceId,
      );
      // Upgrade a previously auto-marked absent row to present when delayed
      // offline validation succeeds for the same student/session.
      AttendanceStore.updateAttendanceRecord(upgraded);
      unawaited(_persistLocalSnapshot(currentLecturerLoadScopeUid()));
      final upgradedWritten = await tryWriteAttendanceRecordDocument(upgraded);
      if (upgradedWritten) {
        unawaited(_persistLocalSnapshot(currentLecturerLoadScopeUid()));
        return StudentOfflineCheckInOutcome.success;
      }
      final session = AttendanceStore.sessionById(record.sessionId);
      final listId = session?.listId ?? '';
      await PendingCheckInQueue.enqueue(
        PendingCheckInEntry(
          id: upgraded.id,
          sessionId: record.sessionId,
          studentId: record.studentId,
          listId: listId,
          course: resolvedCourse,
          capturedAt: record.timestamp,
          latitude: record.latitude,
          longitude: record.longitude,
          deviceId: record.deviceId?.trim() ?? '',
          pendingSince: DateTime.now(),
        ),
      );
      return StudentOfflineCheckInOutcome.queuedOffline;
    }
    // Present check-ins only: never persist [present: false] on a new row here.
    final presentRow = record.present
        ? record
        : AttendanceRecord(
            id: record.id,
            sessionId: record.sessionId,
            studentId: record.studentId,
            course: record.course,
            timestamp: record.timestamp,
            latitude: record.latitude,
            longitude: record.longitude,
            selfieStoragePath: record.selfieStoragePath,
            verified: record.verified,
            present: true,
            deviceId: record.deviceId,
          );
    final normalizedRecord = _isPlaceholderCourse(presentRow.course)
        ? AttendanceRecord(
            id: presentRow.id,
            sessionId: presentRow.sessionId,
            studentId: presentRow.studentId,
            course: _resolvePresentCourseForSession(
              presentRow.sessionId,
              presentRow.studentId,
              presentRow.course,
            ),
            timestamp: presentRow.timestamp,
            latitude: presentRow.latitude,
            longitude: presentRow.longitude,
            selfieStoragePath: presentRow.selfieStoragePath,
            verified: presentRow.verified,
            present: true,
            deviceId: presentRow.deviceId,
          )
        : presentRow;
    if (!AttendanceStore.addAttendanceRecordIfAbsent(normalizedRecord)) {
      return StudentOfflineCheckInOutcome.duplicate;
    }
    unawaited(_persistLocalSnapshot(currentLecturerLoadScopeUid()));
    final written = await tryWriteAttendanceRecordDocument(normalizedRecord);
    if (written) {
      unawaited(_persistLocalSnapshot(currentLecturerLoadScopeUid()));
      return StudentOfflineCheckInOutcome.success;
    }
    final session = AttendanceStore.sessionById(record.sessionId);
    final listId = session?.listId ?? '';
    await PendingCheckInQueue.enqueue(
      PendingCheckInEntry(
        id: normalizedRecord.id,
        sessionId: record.sessionId,
        studentId: record.studentId,
        listId: listId,
        course: normalizedRecord.course,
        capturedAt: record.timestamp,
        latitude: record.latitude,
        longitude: record.longitude,
        deviceId: record.deviceId?.trim() ?? '',
        pendingSince: DateTime.now(),
      ),
    );
    unawaited(_persistLocalSnapshot(currentLecturerLoadScopeUid()));
    return StudentOfflineCheckInOutcome.queuedOffline;
  }

  /// Persists a new session check-in. Returns `false` if this student already
  /// had a record for this session (duplicate guard), or if another student
  /// already used this device for a present row in the same session. On
  /// Firestore failure, rolls back the in-memory add so the user can retry.
  Future<bool> submitAttendanceRecord(AttendanceRecord record) async {
    if (record.present) {
      final d = record.deviceId?.trim() ?? '';
      if (d.isNotEmpty &&
          AttendanceStore.hasPresentCheckInForDevice(
            record.sessionId,
            d,
            record.studentId,
          )) {
        return false;
      }
    }
    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      record.sessionId,
      record.studentId,
    );
    if (existing != null) {
      if (!existing.present && record.present) {
        final resolvedCourse = _resolvePresentCourseForSession(
          record.sessionId,
          record.studentId,
          record.course,
        );
        final upgraded = AttendanceRecord(
          id: existing.id,
          sessionId: record.sessionId,
          studentId: record.studentId,
          course: resolvedCourse,
          timestamp: record.timestamp,
          latitude: record.latitude,
          longitude: record.longitude,
          selfieStoragePath: record.selfieStoragePath,
          verified: record.verified,
          present: true,
          deviceId: record.deviceId,
        );
        AttendanceStore.updateAttendanceRecord(upgraded);
        try {
          await _firestore
              .collection(FirestoreCollections.attendanceRecords)
              .doc(upgraded.id)
              .set(
                _attendanceRecordWritePayload(upgraded),
                SetOptions(merge: true),
              );
          return true;
        } catch (e) {
          AttendanceStore.updateAttendanceRecord(existing);
          rethrow;
        }
      }
      return false;
    }
    final toPersist = record.present && _isPlaceholderCourse(record.course)
        ? AttendanceRecord(
            id: record.id,
            sessionId: record.sessionId,
            studentId: record.studentId,
            course: _resolvePresentCourseForSession(
              record.sessionId,
              record.studentId,
              record.course,
            ),
            timestamp: record.timestamp,
            latitude: record.latitude,
            longitude: record.longitude,
            selfieStoragePath: record.selfieStoragePath,
            verified: record.verified,
            present: record.present,
            deviceId: record.deviceId,
          )
        : record;
    if (!AttendanceStore.addAttendanceRecordIfAbsent(toPersist)) {
      return false;
    }
    try {
      await _firestore
          .collection(FirestoreCollections.attendanceRecords)
          .doc(toPersist.id)
          .set(
            _attendanceRecordWritePayload(toPersist),
            SetOptions(merge: true),
          );
    } catch (e) {
      AttendanceStore.removeAttendanceRecordById(toPersist.id);
      rethrow;
    }
    return true;
  }

  Future<void> updateRecordVerified(String recordId, bool verified) async {
    final idx =
        AttendanceStore.attendanceRecords.indexWhere((r) => r.id == recordId);
    if (idx >= 0) {
      final r = AttendanceStore.attendanceRecords[idx];
      AttendanceStore.updateAttendanceRecord(AttendanceRecord(
        id: r.id,
        sessionId: r.sessionId,
        studentId: r.studentId,
        course: r.course,
        timestamp: r.timestamp,
        latitude: r.latitude,
        longitude: r.longitude,
        selfieStoragePath: r.selfieStoragePath,
        verified: verified,
        present: r.present,
        deviceId: r.deviceId,
      ));
    }
    try {
      await _firestore
          .collection(FirestoreCollections.attendanceRecords)
          .doc(recordId)
          .update(<String, dynamic>{
        'verified': verified,
        'serverReceivedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<void> removeList(String id) async {
    AttendanceStore.removeList(id);
    try {
      final signIns = await _firestore
          .collection(FirestoreCollections.signIns)
          .where('listId', isEqualTo: id)
          .get();
      final batch = _firestore.batch();
      for (final d in signIns.docs) batch.delete(d.reference);
      batch.delete(
          _firestore.collection(FirestoreCollections.attendanceLists).doc(id));
      await batch.commit();
    } catch (_) {}
  }

  Future<StudentRecord> registerStudent(
    String name,
    String registrationNumber,
    String initials,
  ) async {
    final existing = AttendanceStore.findStudentByReg(registrationNumber);
    if (existing != null) {
      return existing;
    }
    final record =
        AttendanceStore.registerStudent(name, registrationNumber, initials);
    try {
      await _firestore
          .collection(FirestoreCollections.students)
          .doc(record.id)
          .set({
        'name': record.name,
        'registrationNumber': record.registrationNumber,
        'threeDigitCode': record.threeDigitCode,
        'initials': record.initials,
      });
    } catch (_) {}
    return record;
  }

  Future<void> addSignIn(String listId, String studentId, String course) async {
    final record = SignInRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      listId: listId,
      studentId: studentId,
      course: course,
      signedInAt: DateTime.now(),
    );
    AttendanceStore.addSignInRecord(record);
    try {
      await _firestore
          .collection(FirestoreCollections.signIns)
          .doc(record.id)
          .set({
        'listId': record.listId,
        'studentId': record.studentId,
        'course': record.course,
        'signedInAt': Timestamp.fromDate(record.signedInAt),
      });
      unawaited(PushController.instance.syncListTopicsFromStore());
    } catch (_) {}
  }

  /// Records list enrollment (if new) and writes absent rows for completed
  /// sessions on that list **after** the student first joined the list, where
  /// they still have no row—so roll history matches without retroactive absences.
  Future<void> ensureSignInAndBackfillPastAbsents({
    required String listId,
    required String studentId,
    required String course,
  }) async {
    if (!AttendanceStore.hasSignedIn(listId, studentId, course)) {
      await addSignIn(listId, studentId, course);
    }
    await backfillPastAbsentsForStudentOnList(listId, studentId);
  }

  /// Idempotent: only creates missing absent rows for ended sessions that
  /// ended on or after this student's first sign-in on [listId].
  Future<void> backfillPastAbsentsForStudentOnList(
    String listId,
    String studentId,
  ) async {
    final enrolledAt =
        AttendanceStore.earliestSignInAtForStudentOnList(listId, studentId);
    for (final sess in AttendanceStore.sessionsForListNewestFirst(listId)) {
      if (!sess.countsTowardRollStats) continue;
      if (enrolledAt != null && sess.endTime.isBefore(enrolledAt)) continue;
      if (AttendanceStore.hasCheckedIn(sess.id, studentId)) continue;
      final recordId = attendanceRecordIdForSessionStudent(sess.id, studentId);
      if (await _remoteRecordIsPresent(recordId)) continue;
      var course = AttendanceStore.courseForStudentOnList(listId, studentId);
      if (course.isEmpty) {
        final list = AttendanceStore.listById(listId);
        course = (list != null && list.coursesSafe.isNotEmpty)
            ? list.coursesSafe.first
            : '—';
      }
      final record = AttendanceRecord(
        id: recordId,
        sessionId: sess.id,
        studentId: studentId,
        course: course,
        timestamp: DateTime.now(),
        latitude: 0,
        longitude: 0,
        selfieStoragePath: null,
        verified: false,
        present: false,
        deviceId: null,
      );
      try {
        await submitAttendanceRecord(record);
      } catch (_) {}
    }
  }
}
