import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../core/auth/auth_repository.dart';
import '../../../core/auth/staff_auth_email.dart';
import '../../../core/auth/student_registration_number.dart';
import '../../../core/auth/user_role.dart';
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/device/device_student_registration_lock.dart';
import '../../../core/connectivity/online_first_persist.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import '../../../core/notifications/notification_maintenance_coordinator.dart';
import '../../../core/push/push_controller.dart';
import '../../../core/storage/attendance_local_snapshot.dart';
import '../../../core/storage/staff_number_directory_cache.dart';
import '../attendance_list_hierarchy.dart';
import '../../notices/data/notices_repository.dart';
import '../check_in_outcome.dart';
import '../check_in_rejection.dart';
import '../check_in_validation.dart';
import '../models/attendance_models.dart';
import '../roll_cell_status.dart'
    show
        pendingCheckInMissingMetadataForPending,
        pendingSessionCodeMissingMetadataForPending,
        rollGracePeriodExpired,
        sessionStudentCheckInMetadataIncomplete;
import 'attendance_list_purge.dart';
import 'attendance_remote_list_watch.dart';
import 'attendance_remote_record_watch.dart';
import 'pending_check_in_queue.dart';
import 'pending_list_create_queue.dart';
import 'pending_retention.dart';
import 'pending_session_code_queue.dart';
import 'pending_session_code_claim_upload.dart';
import 'pending_session_code_sync.dart';
import 'pending_session_create_queue.dart';
import 'pending_session_create_sync.dart';

/// Result of [AttendanceRepository.addList].
typedef ListCreateResult = ({
  AttendanceList list,
  bool syncedToServer,
});

/// Result of [AttendanceRepository.createSession].
typedef SessionCreateResult = ({
  AttendanceSession session,
  bool syncedToServer,
  bool publishingInBackground,
  String? sessionNoticeError,
});

/// Outcome when adding a student to a class list before check-in.
enum StudentListEnrollOutcome {
  alreadyEnrolled,
  enrolled,
  needsCourseChoice,
  noCourses,
  deviceBlocked,
}

/// Result of pulling one [attendanceRecords] doc from Firebase.
enum OfficialRecordRefreshResult {
  verifiedPresent,
  officialAbsent,
  notFound,
}

enum _CheckInAttemptUploadResult {
  submitted,
  permissionDenied,
  failed,
}

/// Repository that persists attendance data to Firestore and keeps
/// [AttendanceStore] in sync for in-memory reads.
class AttendanceRepository extends ChangeNotifier {
  AttendanceRepository._();
  static final AttendanceRepository instance = AttendanceRepository._();

  void _notifyStoreUpdated() {
    unawaited(AttendanceRemoteRecordWatch.instance.refreshIfNeeded());
    notifyListeners();
  }

  /// Notifies profile / attendance UI after session validation or record refresh.
  void notifyAttendanceStoreUpdated() => _notifyStoreUpdated();

  /// When the signed-in user is a lecturer (not admin), loads are scoped to their lists.
  static String? currentLecturerLoadScopeUid() {
    final a = AuthRepository.instance;
    if (!a.isLoggedIn || !a.adminCheckDone || !a.lecturerCheckDone) return null;
    if (a.isLecturer && !a.isAdmin) {
      return a.currentFirebaseUid;
    }
    if (a.isKiuAdmin) {
      return a.currentFirebaseUid;
    }
    return null;
  }

  /// True when [loadAll] should fetch only the signed-in student's own rows.
  static bool isStudentScopedUser() {
    final a = AuthRepository.instance;
    if (!a.isLoggedIn || !a.adminCheckDone || !a.lecturerCheckDone) {
      return false;
    }
    return a.resolvedRole == UserRole.student;
  }

  static String? currentStudentLoadRegistration() {
    if (!isStudentScopedUser()) return null;
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) return null;
    return StudentRegistrationNumber.normalize(reg);
  }

  /// Device proxy prevention runs per attendance session at check-in
  /// ([isDeviceBlockedForStudentSession]), not at login or list enrollment.
  static bool shouldEnforceDeviceStudentRegistrationLock() => false;

  /// Blocks proxy registration / check-in for another student on this phone.
  Future<String?> deviceRegistrationBlockReason(String registrationNumber) async {
    if (!shouldEnforceDeviceStudentRegistrationLock()) return null;
    return DeviceStudentRegistrationLock.blockReasonFor(registrationNumber);
  }

  Future<void> _bindDeviceRegistrationIfNeeded(String registrationNumber) async {
    if (!shouldEnforceDeviceStudentRegistrationLock()) return;
    await DeviceStudentRegistrationLock.bindRegistration(registrationNumber);
  }

  /// Avoids staff-scoped Firestore reads before [AuthRepository.roleCheckDone].
  static Future<void> _awaitRoleChecksDone({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!AuthRepository.instance.roleCheckDone) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  static const Duration _sessionPublishTimeout = Duration(seconds: 4);

  /// Sessions uploading to Firestore after an optimistic local start.
  static final Set<String> _publishingSessionIds = <String>{};
  static const Duration _onlineFirestoreTimeout = Duration(seconds: 12);

  final Map<String, bool> _sessionPublishedOnServerCache = {};
  DateTime? _sessionPublishedCacheAt;
  static const Duration _sessionPublishedCacheTtl = Duration(seconds: 3);
  Set<String>? _awaitingUploadSessionIdsCache;
  DateTime? _awaitingUploadCacheAt;

  /// Live listeners on in-flight check-in attempts (accepted → verify locally).
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>
      _checkInAttemptWatchSubs = {};

  /// Prefer Firestore server reads when online; fall back to cache when offline.
  GetOptions _loadQueryOptions({required bool force}) {
    final c = AppConnectivity.instance;
    if (force || c.isOnline) {
      return const GetOptions(source: Source.server);
    }
    return const GetOptions(source: Source.serverAndCache);
  }

  /// Shared short timeout for offline-first list/session Firestore writes.
  static Duration get listPublishTimeout => _sessionPublishTimeout;

  FirebaseFirestore? get _firestoreIfReady => tryUPanelFirestore();

  FirebaseFirestore get _firestore {
    final db = _firestoreIfReady;
    if (db == null) {
      throw StateError('Firestore is not available');
    }
    return db;
  }

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  /// True when [AttendanceStore] already has data (memory or restored snapshot).
  bool get hasCachedStore => _isLoaded || !_storeLooksEmpty();

  /// Restores the last on-device attendance snapshot so UI can paint before Firestore.
  Future<bool> warmFromLocalSnapshot() async {
    if (!AuthRepository.instance.isLoggedIn) return false;

    final loadGeneration = _loadGeneration;
    final uid = _snapshotUserId();
    if (uid == null || uid.isEmpty) return false;

    // Try likely scope tags before role hydration so list cards appear instantly.
    final rawReg = AuthRepository.instance.currentRegistrationNumber?.trim();
    final normalizedReg = rawReg != null && rawReg.isNotEmpty
        ? StudentRegistrationNumber.normalize(rawReg)
        : null;
    if (normalizedReg != null) {
      _loadScopeStudentReg = normalizedReg;
      final studentDataReady = hasCachedStore &&
          _loadScopeStudentReg == normalizedReg &&
          AttendanceStore.hasStudentSessionHistoryForRegistrationNormalized(
            normalizedReg,
          );
      if (!studentDataReady) {
        if (await _restoreLocalSnapshot(null, loadGeneration: loadGeneration)) {
          return true;
        }
      } else if (hasCachedStore) {
        return true;
      }
      if (!hasCachedStore) {
        _loadScopeStudentReg = null;
      }
    } else if (hasCachedStore) {
      return true;
    }

    if (await _restoreLocalSnapshot(uid, loadGeneration: loadGeneration)) {
      return true;
    }
    if (await _restoreLocalSnapshot(null, loadGeneration: loadGeneration)) {
      return true;
    }

    await _awaitRoleChecksDone(timeout: const Duration(milliseconds: 800));
    if (!AuthRepository.instance.roleCheckDone) return false;

    if (isStudentScopedUser()) {
      final studentReg = currentStudentLoadRegistration();
      if (studentReg == null || studentReg.isEmpty) return false;
      _loadScopeStudentReg = studentReg;
      _loadScopeLecturerUid = null;
      return _restoreLocalSnapshot(null, loadGeneration: loadGeneration);
    }
    return _restoreLocalSnapshot(
      currentLecturerLoadScopeUid(),
      loadGeneration: loadGeneration,
    );
  }

  /// Pull attendance list metadata first — skips role hydration when possible.
  Future<void> loadAttendanceListsFirst({bool force = false}) {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn) return Future<void>.value();
    if (_likelyStudentBeforeRoleCheck()) return Future<void>.value();
    final uid = auth.currentFirebaseUid?.trim();
    return loadAll(
      force: force,
      listsOnly: true,
      scopeToLecturerUid: uid,
    );
  }

  bool _likelyStudentBeforeRoleCheck() {
    final auth = AuthRepository.instance;
    if (auth.adminCheckDone && auth.isAdmin) return false;
    if (auth.lecturerCheckDone && auth.isLecturer) return false;
    if (auth.lecturerCheckDone && auth.isKiuAdmin) return false;
    final reg = auth.currentRegistrationNumber?.trim();
    return reg != null && reg.isNotEmpty;
  }

  /// Student profile / sign-in: same local snapshot model as lecturers (`stu:REG`).
  Future<void> loadStudentAttendanceForProfile({bool force = false}) async {
    if (!AuthRepository.instance.isLoggedIn) return;
    if (!_likelyStudentBeforeRoleCheck() && !isStudentScopedUser()) return;

    _ensureSnapshotStudentScope();
    await warmFromLocalSnapshot();

    final reg = _normalizedStudentRegistrationForCache();
    final sessionHistoryReady = reg != null &&
        AttendanceStore.hasStudentSessionHistoryForRegistrationNormalized(reg);

    if (!AppConnectivity.instance.isOnline && !force) {
      if (reg != null) {
        await _keepStudentStoreFromLocalSnapshot(reg, _loadGeneration);
        await _rehydrateStudentPendingWorkIntoStore();
      }
      return;
    }

    // Cached sessions on disk — paint immediately; network refresh in background.
    if (!force && sessionHistoryReady) {
      _isLoaded = true;
      _loadScopeStudentReg = reg;
      _loadScopeLecturerUid = null;
      _notifyStoreUpdated();
      if (AppConnectivity.instance.isOnline) {
        unawaited(_refreshStudentEnrolledListDetails(force: false));
      }
      return;
    }

    await _refreshStudentEnrolledListDetails(force: force);
  }

  /// Pulls student attendance with batched Firestore queries and persists locally.
  Future<void> _refreshStudentEnrolledListDetails({required bool force}) async {
    if (!isStudentScopedUser() && !_likelyStudentBeforeRoleCheck()) return;
    _ensureSnapshotStudentScope();

    if (!AppConnectivity.instance.isOnline && !force) {
      final reg = _normalizedStudentRegistrationForCache();
      if (reg != null) {
        await _keepStudentStoreFromLocalSnapshot(reg, _loadGeneration);
      }
      return;
    }

    final reg = _normalizedStudentRegistrationForCache();
    if (!force &&
        reg != null &&
        AttendanceStore.hasStudentSessionHistoryForRegistrationNormalized(reg) &&
        _localSnapshotSyncedAt != null &&
        DateTime.now().difference(_localSnapshotSyncedAt!) <
            const Duration(minutes: 3)) {
      return;
    }

    await loadAll(force: force);
    if (!AuthRepository.instance.isLoggedIn) return;
    _isLoaded = true;
    try {
      await _persistScopedLocalSnapshot();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AttendanceRepository student snapshot persist failed: $e');
        debugPrint('$st');
      }
    }
    _notifyStoreUpdated();
  }

  /// One scoped [loadAll] for shell bootstrap — avoids duplicate tab init loads.
  Future<void> bootstrapLoadIfNeeded({bool force = false}) {
    if (_bootstrapLoad != null) return _bootstrapLoad!;
    _bootstrapLoad = _runBootstrapLoad(force: force).whenComplete(() {
      _bootstrapLoad = null;
    });
    return _bootstrapLoad!;
  }

  Future<void>? _bootstrapLoad;

  Future<void> _runBootstrapLoad({required bool force}) async {
    await warmFromLocalSnapshot();

    if (!force &&
        _isLoaded &&
        hasCachedStore &&
        AttendanceStore.lists.isNotEmpty &&
        _lecturerScopeIncludesSessions) {
      return;
    }

    if (!_likelyStudentBeforeRoleCheck()) {
      await loadAttendanceListsFirst(force: force);
    }

    await _awaitRoleChecksDone();
    if (!AuthRepository.instance.roleCheckDone) return;

    final student = isStudentScopedUser();
    if (student) {
      unawaited(loadStudentAttendanceForProfile(force: force));
      return;
    }

    if (AppConnectivity.instance.isOnline) {
      unawaited(reconcileDeletedListsAgainstRemote());
    }

    if (!force && _lecturerScopeIncludesSessions && _isLoaded) return;

    // Staff: list metadata only at bootstrap — records load per list when displayed.
  }

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

  /// Waits until role flags are hydrated (for realtime list watchers).
  Future<void> awaitRoleChecksForWatch({
    Duration timeout = const Duration(seconds: 5),
  }) =>
      _awaitRoleChecksDone(timeout: timeout);

  /// Student roster ids currently in [AttendanceStore] (for sign-in listeners).
  Set<String> studentIdsForCurrentUserInStore() {
    final reg = currentStudentLoadRegistration();
    if (reg == null || reg.isEmpty) return const {};
    final key = reg.trim().toUpperCase();
    final ids = AttendanceStore.students
        .where((s) => s.registrationNumber.trim().toUpperCase() == key)
        .map((s) => s.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isNotEmpty) return ids;
    final student = AttendanceStore.findStudentByReg(reg);
    final id = student?.id.trim() ?? '';
    if (id.isEmpty) return const {};
    return {id};
  }

  /// Purges local rows for [listIds] removed from authoritative remote state.
  Future<bool> purgeListsRemovedFromRemote(Set<String> listIds) async {
    if (listIds.isEmpty) return false;
    var purged = false;
    for (final raw in listIds) {
      final id = raw.trim();
      if (id.isEmpty) continue;
      if (!AttendanceStore.lists.any((l) => l.id == id)) continue;
      await _purgeListLocally(id);
      purged = true;
    }
    if (!purged) return false;
    unawaited(PushController.instance.syncListTopicsFromStore());
    unawaited(_persistScopedLocalSnapshot());
    _notifyStoreUpdated();
    return true;
  }

  /// Compares on-device lists with remote membership and purges orphans.
  Future<bool> reconcileDeletedListsAgainstRemote({bool force = false}) async {
    if (!AuthRepository.instance.isLoggedIn) return false;
    if (!AppConnectivity.instance.isOnline) return false;
    if (_firestoreIfReady == null) return false;
    await _awaitRoleChecksDone();
    if (!AuthRepository.instance.roleCheckDone) return false;

    final remoteIds = await _fetchAuthoritativeRemoteListIds(force: force);
    if (remoteIds == null) return false;
    return reconcileLocalListsAgainstRemoteIds(remoteIds);
  }

  /// Purges local lists absent from [remoteListIds] (minus in-flight enrollments).
  Future<bool> reconcileLocalListsAgainstRemoteIds(
    Set<String> remoteListIds,
  ) async {
    final authoritativeIds = {
      ...remoteListIds,
      ...(await _localEnrollmentListIds()),
    };
    final localIds = AttendanceStore.lists.map((l) => l.id).toSet();
    final orphans = localIds.difference(authoritativeIds);
    if (orphans.isEmpty) return false;
    return purgeListsRemovedFromRemote(orphans);
  }

  String _signInDedupKey(SignInRecord r) =>
      '${r.listId}|${r.studentId}|${r.course}';

  /// List IDs kept locally while enrollment or check-in is still in flight.
  Future<Set<String>> _localEnrollmentListIds() async {
    final ids = <String>{
      for (final s in AttendanceStore.signIns)
        if (s.listId.trim().isNotEmpty) s.listId.trim(),
    };
    for (final e in await PendingListCreateQueue.loadAll()) {
      ids.add(e.list.id);
    }
    for (final e in await PendingCheckInQueue.loadAll()) {
      final id = e.listId.trim();
      if (id.isNotEmpty) ids.add(id);
    }
    for (final e in await PendingSessionCodeQueue.loadAll()) {
      final id = e.listId?.trim() ?? '';
      if (id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  /// Clears in-memory attendance after sign-out so the next user does not see stale data.
  void resetForSignOut() {
    unawaited(AttendanceRemoteListWatch.instance.stop());
    unawaited(AttendanceRemoteRecordWatch.instance.stop());
    unawaited(PendingSessionCodeSync.stopSessionPublishWatches());
    _stopAllCheckInAttemptWatches();
    _invalidateSessionPublishedCache();
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
    _lecturerScopeIncludesSessions = false;
    _loadScopeStudentReg = null;
    _usingLocalSnapshot = false;
    _localSnapshotSyncedAt = null;
    _loadedListDetailIds.clear();
    _listDetailLoads.clear();
    _notifyStoreUpdated();
  }

  /// List ids whose sessions/records/sign-ins have been fetched (or restored).
  final Set<String> _loadedListDetailIds = {};
  final Map<String, Future<void>> _listDetailLoads = {};

  /// True when sessions, sign-ins, or records for [listId] are in the store.
  bool listDetailReady(String listId) {
    final id = listId.trim();
    if (id.isEmpty) return false;
    if (_loadedListDetailIds.contains(id)) return true;
    return AttendanceStore.sessions.any((s) => s.listId == id) ||
        AttendanceStore.signIns.any((si) => si.listId == id) ||
        AttendanceStore.attendanceRecords.any(
          (r) => AttendanceStore.sessionById(r.sessionId)?.listId == id,
        );
  }

  void _markAllStoreListsDetailLoaded() {
    _loadedListDetailIds.addAll(AttendanceStore.lists.map((l) => l.id));
  }

  /// Loads sessions, sign-ins, records, and roster students for one list.
  Future<void> loadListAttendanceData(String listId, {bool force = false}) {
    final id = listId.trim();
    if (id.isEmpty) return Future<void>.value();
    if (force) {
      _loadedListDetailIds.remove(id);
    } else if (_loadedListDetailIds.contains(id)) {
      return Future<void>.value();
    }
    final inFlight = _listDetailLoads[id];
    if (inFlight != null && !force) return inFlight;

    final run = _loadAllSerialized.then(
      (_) => _executeLoadListDetail(id, force: force),
    );
    final safe = run.catchError((Object? _, StackTrace? __) {});
    _loadAllSerialized = safe;
    _listDetailLoads[id] = safe.whenComplete(() {
      _listDetailLoads.remove(id);
    });
    return safe;
  }

  /// Fire-and-forget per-list detail loads (e.g. when a program page opens).
  void prefetchListAttendanceData(Iterable<String> listIds) {
    for (final raw in listIds) {
      unawaited(loadListAttendanceData(raw));
    }
  }

  /// When non-null, [loadAll] last completed a lecturer-scoped fetch for this uid.
  String? _loadScopeLecturerUid;

  /// True after a lecturer-scoped load included sessions/sign-ins (not [listsOnly]).
  bool _lecturerScopeIncludesSessions = false;

  /// When non-null, [loadAll] last completed a student-scoped fetch for this reg.
  String? _loadScopeStudentReg;

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

  /// True when the lecturer session doc is on Firestore (not only local / queued).
  Future<bool> isLecturerSessionPublishedOnServer(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) return false;
    if ((await _sessionIdsAwaitingUpload()).contains(id)) return false;
    if (!AppConnectivity.instance.hasNetworkInterface) return false;

    final cacheFresh = _sessionPublishedCacheAt != null &&
        DateTime.now().difference(_sessionPublishedCacheAt!) <
            _sessionPublishedCacheTtl;
    if (cacheFresh && _sessionPublishedOnServerCache.containsKey(id)) {
      return _sessionPublishedOnServerCache[id]!;
    }

    try {
      final doc = await _firestore
          .collection(FirestoreCollections.attendanceSessions)
          .doc(id)
          .get(_loadQueryOptions(force: false));
      final exists = doc.exists;
      _sessionPublishedOnServerCache[id] = exists;
      _sessionPublishedCacheAt = DateTime.now();
      return exists;
    } catch (_) {
      return false;
    }
  }

  void _invalidateSessionPublishedCache([String? sessionId]) {
    if (sessionId != null) {
      _sessionPublishedOnServerCache.remove(sessionId.trim());
    } else {
      _sessionPublishedOnServerCache.clear();
    }
    _sessionPublishedCacheAt = null;
    _awaitingUploadSessionIdsCache = null;
    _awaitingUploadCacheAt = null;
  }

  /// Session ids waiting for Firestore upload — roll stays pending, not absent.
  Future<Set<String>> _sessionIdsAwaitingUpload() async {
    final cacheFresh = _awaitingUploadCacheAt != null &&
        DateTime.now().difference(_awaitingUploadCacheAt!) <
            _sessionPublishedCacheTtl;
    if (cacheFresh && _awaitingUploadSessionIdsCache != null) {
      return _awaitingUploadSessionIdsCache!;
    }
    final ids = <String>{};
    for (final e in await PendingSessionCreateQueue.loadAll()) {
      ids.add(e.sessionId);
    }
    _awaitingUploadSessionIdsCache = ids;
    _awaitingUploadCacheAt = DateTime.now();
    return ids;
  }

  /// True when a queued session-code capture matches [session] (any queue status).
  static bool pendingSessionCodeMatchesSession({
    required PendingSessionCodeEntry entry,
    required AttendanceSession session,
    required String studentRegistrationNumber,
  }) {
    if (entry.sessionId != null &&
        entry.sessionId!.trim().isNotEmpty &&
        entry.sessionId != session.id) {
      return false;
    }
    if (normalizeSessionCodeInput(entry.sessionCodeRaw) !=
        normalizeSessionCodeInput(session.sessionCode)) {
      return false;
    }
    final reg = entry.registrationNumber.trim().toUpperCase();
    final studentReg = studentRegistrationNumber.trim().toUpperCase();
    if (studentReg.isNotEmpty && reg != studentReg) return false;
    return isTimestampWithinSessionBounds(session, entry.capturedAt) &&
        isPositionWithinSession(session, entry.latitude, entry.longitude);
  }

  /// Like [pendingSessionCodeMatchesSession] but accepts correction GPS rules.
  static bool pendingSessionCodeMatchesSessionForCorrection({
    required PendingSessionCodeEntry entry,
    required AttendanceSession session,
    required String studentRegistrationNumber,
  }) {
    if (entry.sessionId != null &&
        entry.sessionId!.trim().isNotEmpty &&
        entry.sessionId != session.id) {
      return false;
    }
    if (normalizeSessionCodeInput(entry.sessionCodeRaw) !=
        normalizeSessionCodeInput(session.sessionCode)) {
      return false;
    }
    final reg = entry.registrationNumber.trim().toUpperCase();
    final studentReg = studentRegistrationNumber.trim().toUpperCase();
    if (studentReg.isNotEmpty && reg != studentReg) return false;
    return isTimestampWithinSessionBounds(session, entry.capturedAt) &&
        positionQualifiesForPresentCorrection(
          session,
          entry.latitude,
          entry.longitude,
        );
  }

  /// True when queued check-in evidence matches [session] + list scope.
  static bool pendingCheckInMatchesSession(
    PendingCheckInEntry entry,
    AttendanceSession session,
  ) {
    if (entry.listId.isNotEmpty && entry.listId != session.listId) {
      return false;
    }
    return isTimestampWithinSessionBounds(session, entry.capturedAt) &&
        isPositionWithinSession(session, entry.latitude, entry.longitude);
  }

  static bool pendingCheckInMatchesSessionForCorrection(
    PendingCheckInEntry entry,
    AttendanceSession session,
  ) {
    if (entry.listId.isNotEmpty && entry.listId != session.listId) {
      return false;
    }
    return isTimestampWithinSessionBounds(session, entry.capturedAt) &&
        positionQualifiesForPresentCorrection(
          session,
          entry.latitude,
          entry.longitude,
        );
  }

  /// Merges local/queued present while verification is pending. Verified server
  /// present wins; premature server absent does not override queued present.
  static void _applyPendingPresentIfNotOfficial(
    Map<String, AttendanceRecord> recordsById,
    AttendanceRecord pending,
  ) {
    if (!pending.present) return;
    final existing = recordsById[pending.id];
    if (existing == null) {
      recordsById[pending.id] = pending;
      return;
    }
    if (existing.present && existing.verified) return;
    recordsById[pending.id] = pending;
  }

  /// Drops optimistic present rows after the server has resolved the attempt.
  Future<void> clearLocalUnverifiedPresentForCheckIn(
    String recordId, {
    bool force = false,
  }) async {
    final id = recordId.trim();
    if (id.isEmpty) return;
    if (!force && await PendingCheckInQueue.containsRecordId(id)) return;
    final existing = AttendanceStore.attendanceRecords
        .where((r) => r.id == id)
        .firstOrNull;
    if (existing != null && existing.present && !existing.verified) {
      AttendanceStore.removeAttendanceRecordById(id);
      AttendanceStore.invalidateLookupCaches();
      unawaited(_persistScopedLocalSnapshot());
    }
  }

  /// Record ids ({sessionId}_{studentId}) whose [checkInAttempts] doc is rejected.
  Future<Set<String>> _fetchRejectedCheckInRecordIds(
    Iterable<String> recordIds,
  ) async {
    final ids = recordIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (ids.isEmpty || !AppConnectivity.instance.isOnline) return const {};
    final rejected = <String>{};
    final batch = <Future<void>>[];
    for (final id in ids) {
      batch.add(() async {
        try {
          final doc = await _firestore
              .collection(FirestoreCollections.checkInAttempts)
              .doc(id)
              .get()
              .timeout(_onlineFirestoreTimeout);
          if (!doc.exists) return;
          if (doc.data()?['status'] == 'rejected') {
            rejected.add(id);
          }
        } catch (_) {}
      }());
    }
    await Future.wait(batch);
    return rejected;
  }

  Future<bool> isCheckInAttemptRejected(String recordId) async {
    final reason = await fetchCheckInAttemptRejectionReason(recordId);
    return reason != null;
  }

  /// Non-null when [checkInAttempts] doc exists with `status: rejected`.
  Future<String?> fetchCheckInAttemptRejectionReason(String recordId) async {
    final id = recordId.trim();
    if (id.isEmpty) return null;
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.checkInAttempts)
          .doc(id)
          .get()
          .timeout(_onlineFirestoreTimeout);
      if (!doc.exists) return null;
      if (doc.data()?['status'] != 'rejected') return null;
      final reason = (doc.data()?['rejectionReason'] as String?)?.trim();
      return reason == null || reason.isEmpty ? 'Check-in rejected.' : reason;
    } catch (_) {
      return null;
    }
  }

  /// Waits briefly for Cloud Functions to write [rejectionReason].
  Future<String?> fetchCheckInAttemptRejectionReasonWithRetry(
    String recordId, {
    int attempts = 5,
  }) async {
    for (var i = 0; i < attempts; i++) {
      final reason = await fetchCheckInAttemptRejectionReason(recordId);
      if (reason != null &&
          reason.trim().isNotEmpty &&
          reason.trim().toLowerCase() != 'check-in rejected.') {
        return reason;
      }
      if (i + 1 < attempts) {
        await Future<void>.delayed(Duration(milliseconds: 100 * (i + 1)));
      }
    }
    return fetchCheckInAttemptRejectionReason(recordId);
  }

  /// Local present rows + offline queues + Firestore for the same session/code.
  Future<bool> isDeviceBlockedForStudentSession({
    required String sessionId,
    required String studentId,
    required String deviceId,
    String? sessionCodeRaw,
  }) async {
    final d = deviceId.trim();
    final sid = studentId.trim();
    if (d.isEmpty) return false;
    final code = sessionCodeRaw != null
        ? normalizeSessionCodeInput(sessionCodeRaw)
        : normalizeSessionCodeInput(
            AttendanceStore.sessionById(sessionId)?.sessionCode ?? '',
          );

    if (_localDeviceUsedByOtherStudent(
          deviceId: d,
          studentId: sid,
          sessionId: sessionId,
          sessionCode: code,
        ) ||
        await _localDeviceQueuesUsedByOtherStudent(
          deviceId: d,
          studentId: sid,
          sessionId: sessionId,
          sessionCode: code,
        )) {
      return true;
    }

    if (await _firestoreDeviceUsedByOtherStudent(
      deviceId: d,
      studentId: sid,
      sessionId: sessionId,
      sessionCode: code,
    )) {
      return true;
    }
    return false;
  }

  bool _localDeviceUsedByOtherStudent({
    required String deviceId,
    required String studentId,
    required String sessionId,
    required String sessionCode,
  }) {
    final d = deviceId.trim();
    final sid = studentId.trim();
    if (d.isEmpty) return false;

    if (sessionId.trim().isNotEmpty &&
        AttendanceStore.hasPresentCheckInForDevice(
          sessionId.trim(),
          d,
          sid,
        )) {
      return true;
    }

    if (sessionCode.isNotEmpty && isValidJoinCodeFormat(sessionCode)) {
      for (final sess in AttendanceStore.sessions) {
        if (normalizeSessionCodeInput(sess.sessionCode) != sessionCode) {
          continue;
        }
        if (AttendanceStore.hasPresentCheckInForDevice(sess.id, d, sid)) {
          return true;
        }
      }
    }

    return false;
  }

  Future<bool> _localDeviceQueuesUsedByOtherStudent({
    required String deviceId,
    required String studentId,
    required String sessionId,
    required String sessionCode,
  }) async {
    final d = deviceId.trim();
    final sid = studentId.trim();
    if (d.isEmpty) return false;
    final sidFilter = sessionId.trim();

    for (final e in await PendingCheckInQueue.loadAll()) {
      if (e.deviceId.trim() != d || e.studentId.trim() == sid) continue;
      if (sidFilter.isNotEmpty && e.sessionId.trim() == sidFilter) return true;
      if (sessionCode.isNotEmpty && isValidJoinCodeFormat(sessionCode)) {
        final sess = AttendanceStore.sessionById(e.sessionId);
        if (sess != null &&
            normalizeSessionCodeInput(sess.sessionCode) == sessionCode) {
          return true;
        }
      }
    }

    for (final e in await PendingSessionCodeQueue.loadAll()) {
      if (e.deviceId.trim() != d) continue;
      if (e.status == PendingSessionCodeStatus.deviceBlocked) continue;
      final other = AttendanceStore.findStudentByReg(e.registrationNumber);
      if (other != null && other.id.trim() == sid) continue;
      final entrySessionId = e.sessionId?.trim() ?? '';
      if (sidFilter.isNotEmpty &&
          entrySessionId.isNotEmpty &&
          entrySessionId == sidFilter) {
        return true;
      }
      if (sessionCode.isNotEmpty &&
          isValidJoinCodeFormat(sessionCode) &&
          normalizeSessionCodeInput(e.sessionCodeRaw) == sessionCode) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _firestoreDeviceUsedByOtherStudent({
    required String deviceId,
    required String studentId,
    required String sessionId,
    required String sessionCode,
  }) async {
    if (_firestoreIfReady == null) return false;
    if (!AppConnectivity.instance.hasNetworkInterface) return false;

    final d = deviceId.trim();
    final sid = studentId.trim();
    if (d.isEmpty || sid.isEmpty) return false;

    final timeout = AppConnectivity.instance.isOnline
        ? _onlineFirestoreTimeout
        : _sessionPublishTimeout;

    try {
      if (sessionCode.isNotEmpty && isValidJoinCodeFormat(sessionCode)) {
        final byCode = await _firestore
            .collection(FirestoreCollections.checkInAttempts)
            .where('deviceId', isEqualTo: d)
            .where('sessionCodeRaw', isEqualTo: sessionCode)
            .where('status', whereIn: ['pending', 'accepted'])
            .limit(12)
            .get()
            .timeout(timeout);
        final ownRecordId =
            attendanceRecordIdForSessionStudent(sessionId, sid);
        for (final doc in byCode.docs) {
          if (doc.id == ownRecordId) continue;
          final other = (doc.data()['studentId'] as String?)?.trim() ?? '';
          if (other.isNotEmpty && other != sid) return true;
        }
      }

      final resolvedSessionId = sessionId.trim();
      if (resolvedSessionId.isNotEmpty) {
        final bySession = await _firestore
            .collection(FirestoreCollections.checkInAttempts)
            .where('deviceId', isEqualTo: d)
            .where('sessionId', isEqualTo: resolvedSessionId)
            .where('status', whereIn: ['pending', 'accepted'])
            .limit(12)
            .get()
            .timeout(timeout);
        for (final doc in bySession.docs) {
          final other = (doc.data()['studentId'] as String?)?.trim() ?? '';
          if (other.isNotEmpty && other != sid) return true;
        }

        final presentSnap = await _firestore
            .collection(FirestoreCollections.attendanceRecords)
            .where('sessionId', isEqualTo: resolvedSessionId)
            .where('present', isEqualTo: true)
            .get()
            .timeout(timeout);
        for (final doc in presentSnap.docs) {
          final data = doc.data();
          final otherDevice = (data['deviceId'] as String?)?.trim() ?? '';
          final otherStudent = (data['studentId'] as String?)?.trim() ?? '';
          if (otherDevice == d &&
              otherStudent.isNotEmpty &&
              otherStudent != sid) {
            return true;
          }
        }
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AttendanceRepository._firestoreDeviceUsedByOtherStudent: $e');
        debugPrint('$st');
      }
    }
    return false;
  }

  Future<StudentOfflineCheckInOutcome> _outcomeForRejectedAttempt(
    String recordId, {
    String? sessionId,
    String? studentId,
    String? deviceId,
    String? sessionCodeRaw,
  }) async {
    if (await _isCheckInAttemptAccepted(recordId)) {
      return StudentOfflineCheckInOutcome.success;
    }
    final reason =
        await fetchCheckInAttemptRejectionReasonWithRetry(recordId);
    final outcome = outcomeFromRejectionReason(reason);
    if (outcome == StudentOfflineCheckInOutcome.deviceBlocked) {
      await clearLocalUnverifiedPresentForCheckIn(recordId, force: true);
      return outcome;
    }
    final sid = sessionId?.trim() ?? '';
    final stu = studentId?.trim() ?? '';
    final dev = deviceId?.trim() ?? '';
    if (sid.isNotEmpty &&
        stu.isNotEmpty &&
        dev.isNotEmpty &&
        await isDeviceBlockedForStudentSession(
          sessionId: sid,
          studentId: stu,
          deviceId: dev,
          sessionCodeRaw: sessionCodeRaw,
        )) {
      await clearLocalUnverifiedPresentForCheckIn(recordId, force: true);
      return StudentOfflineCheckInOutcome.deviceBlocked;
    }
    return outcome;
  }

  Future<bool> isCheckInAttemptAcceptedForSessionStudent({
    required String sessionId,
    required String studentId,
  }) =>
      _isCheckInAttemptAccepted(
        attendanceRecordIdForSessionStudent(sessionId, studentId),
      );

  Future<bool> _isCheckInDeviceBlocked({
    required String sessionId,
    required String studentId,
    required String deviceId,
    String? sessionCodeRaw,
  }) async {
    final d = deviceId.trim();
    if (d.isEmpty) return false;
    return AttendanceStore.hasPresentCheckInForDevice(
          sessionId,
          d,
          studentId,
        ) ||
        await isDeviceBlockedForStudentSession(
          sessionId: sessionId,
          studentId: studentId,
          deviceId: d,
          sessionCodeRaw: sessionCodeRaw,
        );
  }

  void _applyLocalPresentCheckInRow(
    AttendanceRecord localRow, {
    AttendanceRecord? existing,
    required String sessionId,
    required String studentId,
  }) {
    if (existing != null) {
      AttendanceStore.updateAttendanceRecord(localRow);
    } else if (!AttendanceStore.addAttendanceRecordIfAbsent(localRow)) {
      final prior = AttendanceStore.attendanceRecordForSessionStudent(
        sessionId,
        studentId,
      );
      if (prior != null && prior.present && prior.verified) return;
      AttendanceStore.updateAttendanceRecord(localRow);
    }
    _notifyStoreUpdated();
    unawaited(_persistScopedLocalSnapshot());
    watchCheckInAttemptForStudent(
      recordId: localRow.id,
      sessionId: sessionId,
      studentId: studentId,
    );
    unawaited(AttendanceRemoteRecordWatch.instance.start());
  }

  Future<void> _replaceStoreFromRemote({
    required List<AttendanceList> remoteLists,
    required List<AttendanceSession> remoteSessions,
    required List<AttendanceRecord> remoteRecords,
    required List<StudentRecord> remoteStudents,
    required List<SignInRecord> remoteSignIns,
  }) async {
    if (!AuthRepository.instance.isLoggedIn) return;

    final pendingCreates = await PendingSessionCreateQueue.loadAll();
    final pendingListCreates = await PendingListCreateQueue.loadAll();
    var pendingCheckIns = await PendingCheckInQueue.loadAll();
    final pendingCodes = await PendingSessionCodeQueue.loadAll();

    // Snapshot local store after queue reads; refreshed again after async rejection scan.
    var priorLists = List<AttendanceList>.from(AttendanceStore.lists);
    var priorSessions = List<AttendanceSession>.from(AttendanceStore.sessions);
    var priorRecords =
        List<AttendanceRecord>.from(AttendanceStore.attendanceRecords);
    var priorSignIns = List<SignInRecord>.from(AttendanceStore.signIns);

    final authoritativeListIds = <String>{
      for (final l in remoteLists) l.id,
      for (final l in priorLists) l.id,
      for (final e in pendingListCreates) e.list.id,
      for (final s in remoteSignIns) s.listId,
      for (final s in remoteSessions) s.listId,
      for (final s in priorSignIns) s.listId,
      for (final e in pendingCheckIns)
        if (e.listId.trim().isNotEmpty) e.listId.trim(),
      for (final e in pendingCodes)
        if ((e.listId?.trim() ?? '').isNotEmpty) e.listId!.trim(),
    };
    for (final l in priorLists) {
      if (!authoritativeListIds.contains(l.id)) {
        await _purgeListLocally(l.id);
      }
    }

    final filteredRemoteSessions = remoteSessions
        .where((s) => authoritativeListIds.contains(s.listId))
        .toList();
    final filteredRemoteSignIns = remoteSignIns
        .where((s) => authoritativeListIds.contains(s.listId))
        .toList();
    final filteredRemoteSessionIds =
        filteredRemoteSessions.map((s) => s.id).toSet();
    final filteredRemoteRecords = remoteRecords
        .where((r) => filteredRemoteSessionIds.contains(r.sessionId))
        .toList();

    final remoteSignInKeys = {
      for (final s in filteredRemoteSignIns) _signInDedupKey(s),
    };
    final mergedSignIns = [
      for (final s in filteredRemoteSignIns)
        _mergeSignInWithLocal(s, priorSignIns),
      for (final s in priorSignIns)
        if (!remoteSignInKeys.contains(_signInDedupKey(s)) &&
            authoritativeListIds.contains(s.listId))
          s,
    ];

    final pendingRecordIds = <String>{};
    for (final r in priorRecords) {
      if (r.present && !r.verified) pendingRecordIds.add(r.id);
    }
    for (final e in pendingCheckIns) {
      pendingRecordIds.add(e.id);
    }

    final rejectedIds =
        await _fetchRejectedCheckInRecordIds(pendingRecordIds);
    if (rejectedIds.isNotEmpty) {
      final keptCheckIns =
          pendingCheckIns.where((e) => !rejectedIds.contains(e.id)).toList();
      if (keptCheckIns.length != pendingCheckIns.length) {
        await PendingCheckInQueue.saveAll(keptCheckIns);
        pendingCheckIns = keptCheckIns;
      }
    }

    final freshRecords =
        List<AttendanceRecord>.from(AttendanceStore.attendanceRecords);
    final freshSignIns = List<SignInRecord>.from(AttendanceStore.signIns);
    if (freshRecords.length > priorRecords.length ||
        freshSignIns.length > priorSignIns.length) {
    }
    priorRecords = freshRecords;
    priorSignIns = freshSignIns;
    priorSessions = List<AttendanceSession>.from(AttendanceStore.sessions);
    priorLists = List<AttendanceList>.from(AttendanceStore.lists);

    final listsById = {for (final l in remoteLists) l.id: l};
    for (final e in pendingListCreates) {
      listsById[e.list.id] = e.list;
    }
    for (final e in pendingCreates) {
      if (!authoritativeListIds.contains(e.listId)) continue;
      final prior = priorLists.where((l) => l.id == e.listId).firstOrNull;
      if (prior != null) {
        listsById.putIfAbsent(e.listId, () => prior);
      }
    }

    final sessionsById = {for (final s in filteredRemoteSessions) s.id: s};
    for (final e in pendingCreates) {
      if (!authoritativeListIds.contains(e.listId)) continue;
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
      if (!authoritativeListIds.contains(s.listId)) continue;
      final hasPending = pendingCreates.any((e) => e.sessionId == s.id) ||
          pendingCheckIns.any((e) => e.sessionId == s.id) ||
          pendingCodes.any((e) => e.sessionId == s.id);
      final remote = sessionsById[s.id];
      if (remote != null &&
          s.status == SessionStatus.active &&
          !s.isExpired &&
          remote.status == SessionStatus.closed) {
        // Background sync can return `closed` before the lecturer's live timer ends.
        sessionsById[s.id] = s;
        continue;
      }
      if (hasPending || s.isActive) {
        sessionsById.putIfAbsent(s.id, () => s);
      }
    }

    for (final l in priorLists) {
      if (!authoritativeListIds.contains(l.id)) continue;
      if (sessionsById.values.any((s) => s.listId == l.id)) {
        listsById.putIfAbsent(l.id, () => l);
      }
    }

    final recordsById = <String, AttendanceRecord>{
      for (final r in filteredRemoteRecords) r.id: r,
    };
    for (final r in priorRecords) {
      if (r.present && !r.verified) {
        if (rejectedIds.contains(r.id)) continue;
        _applyPendingPresentIfNotOfficial(recordsById, r);
      } else if (r.present && r.verified) {
        final existing = recordsById[r.id];
        if (existing == null || !existing.present || !existing.verified) {
          recordsById[r.id] = r;
        }
      } else {
        recordsById.putIfAbsent(r.id, () => r);
      }
    }
    for (final e in pendingCheckIns) {
      if (rejectedIds.contains(e.id)) continue;
      if (!authoritativeListIds.contains(e.listId)) continue;
      _applyPendingPresentIfNotOfficial(recordsById, e.toAttendanceRecord());
    }
    Iterable<AttendanceSession> sessionsForPendingCode(PendingSessionCodeEntry e) {
      final hint = e.sessionId?.trim();
      if (hint != null && hint.isNotEmpty) {
        final session = sessionsById[hint] ??
            priorSessions.where((s) => s.id == hint).firstOrNull;
        return session != null ? [session] : const [];
      }
      final code = normalizeSessionCodeInput(e.sessionCodeRaw);
      if (code.isEmpty) return const [];
      final seen = <String>{};
      final out = <AttendanceSession>[];
      for (final s in [...sessionsById.values, ...priorSessions]) {
        if (!authoritativeListIds.contains(s.listId)) continue;
        if (normalizeSessionCodeInput(s.sessionCode) != code) continue;
        if (seen.add(s.id)) out.add(s);
      }
      return out;
    }

    for (final e in pendingCodes) {
      final student = AttendanceStore.findStudentByReg(e.registrationNumber);
      if (student == null) continue;
      final reg = student.registrationNumber.trim().toUpperCase();
      for (final session in sessionsForPendingCode(e)) {
        final matches = pendingSessionCodeMatchesSession(
              entry: e,
              session: session,
              studentRegistrationNumber: reg,
            ) ||
            pendingSessionCodeMatchesSessionForCorrection(
              entry: e,
              session: session,
              studentRegistrationNumber: reg,
            );
        if (!matches) continue;
        final list = listsById[session.listId];
        final course = list != null
            ? resolveCourseForStudentCheckIn(list, student.id)
            : '—';
        _applyPendingPresentIfNotOfficial(
          recordsById,
          AttendanceRecord(
            id: '${session.id}_${student.id}',
            sessionId: session.id,
            studentId: student.id,
            course: course,
            timestamp: e.capturedAt,
            latitude: e.latitude,
            longitude: e.longitude,
            verified: false,
            present: true,
            deviceId: e.deviceId,
          ),
        );
      }
    }
    recordsById.removeWhere((_, r) {
      final session = sessionsById[r.sessionId];
      return session == null ||
          !authoritativeListIds.contains(session.listId);
    });
    final studentsById = <String, StudentRecord>{
      for (final s in remoteStudents) s.id: s,
    };
    for (final s in AttendanceStore.students) {
      studentsById.putIfAbsent(s.id, () => s);
    }
    final mergedStudents = await _augmentRosterStudents(
      signIns: mergedSignIns,
      fetched: studentsById.values.toList(),
    );

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
      ..addAll(mergedStudents);
    AttendanceStore.signIns
      ..clear()
      ..addAll(mergedSignIns);
    AttendanceStore.invalidateLookupCaches();
    unawaited(NotificationMaintenanceCoordinator.onAttendanceStoreUpdated());
  }

  /// Closes expired-but-still-open sessions and writes absent rows (idempotent).
  ///
  /// Students must not run this — they can load lecturer sessions for check-in
  /// and must not push `closed` to Firestore based on local clock/skew.
  Future<void> _finalizeExpiredOpenSessions() async {
    if (isStudentScopedUser()) return;
    final awaitingUpload = await _sessionIdsAwaitingUpload();
    final expiredOpenIds = AttendanceStore.sessions
        .where((s) =>
            s.isExpired &&
            s.status == SessionStatus.active &&
            !awaitingUpload.contains(s.id))
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

  /// Writes absent rows for ended sessions whose 7-day verification window elapsed.
  Future<void> finalizeGraceExpiredSessions() async {
    final now = DateTime.now();
    for (final s in AttendanceStore.sessions) {
      if (!s.countsTowardRollStats) continue;
      if (!PendingRetention.sessionGraceExpired(s.endTime, now)) continue;
      await _finalizeRollForSessionSafe(s.id);
    }
  }

  /// Load all data from Firestore into [AttendanceStore].
  /// Use [force] to refetch (e.g. after QA starts a session so students see it).
  /// On failure, keeps store as-is so attendance works locally without Firebase.
  ///
  /// Invocations are serialized so two overlapping [loadAll] calls cannot each
  /// clear and repopulate the store with stale snapshots.
  /// [scopeToLecturerUid]: when set, only loads lists for that lecturer plus
  /// related sessions, sign-ins, records (batched) and all [students] (MVP).
  /// [listsOnly]: refresh attendance list metadata only (faster hub pull-to-refresh).
  Future<void> loadAll({
    bool force = false,
    String? scopeToLecturerUid,
    bool listsOnly = false,
  }) {
    final run = _loadAllSerialized.then(
      (_) => _executeLoadAll(force, scopeToLecturerUid, listsOnly: listsOnly),
    );
    final safe = run.catchError((Object? _, StackTrace? __) {});
    _loadAllSerialized = safe;
    return safe;
  }

  /// Fast list refresh for lecturer / QA attendance hub.
  Future<void> refreshAttendanceLists({bool force = true}) => loadAll(
        force: force,
        listsOnly: true,
        scopeToLecturerUid: currentLecturerLoadScopeUid(),
      );

  Future<void> _executeLoadListDetail(String listId, {required bool force}) async {
    final loadGeneration = _loadGeneration;
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (_firestoreIfReady == null) return;
    if (!force && _loadedListDetailIds.contains(listId)) return;

    if (AttendanceStore.listById(listId) == null) {
      final resolved = await resolveListById(listId);
      if (resolved == null) return;
    }

    final online = AppConnectivity.instance.isOnline;
    if (!online && !force) {
      if (listDetailReady(listId)) {
        _loadedListDetailIds.add(listId);
      }
      return;
    }

    try {
      final queryOptions = _loadQueryOptions(force: force);
      final sessionAndSignInDocs = await Future.wait([
        _queryDocsWhereFieldEquals(
          collection:
              _firestore.collection(FirestoreCollections.attendanceSessions),
          field: 'listId',
          values: [listId],
          options: queryOptions,
        ),
        _queryDocsWhereFieldEquals(
          collection: _firestore.collection(FirestoreCollections.signIns),
          field: 'listId',
          values: [listId],
          options: queryOptions,
        ),
      ]);
      if (!_loadsAllowedForSession(loadGeneration)) return;

      final sessions =
          sessionAndSignInDocs[0].map(_sessionFromDoc).toList();
      var signIns = sessionAndSignInDocs[1].map(_signInFromDoc).toList();
      final sessionIds = sessions.map((s) => s.id).toList();

      final scopedStudentIds = _scopedStudentIdsForListDetail();
      if (scopedStudentIds != null && scopedStudentIds.isNotEmpty) {
        signIns = signIns
            .where((s) => scopedStudentIds.contains(s.studentId))
            .toList();
      }

      var records = <AttendanceRecord>[];
      if (scopedStudentIds != null && scopedStudentIds.isNotEmpty) {
        final recordDocs = await _queryDocsWhereFieldEquals(
          collection:
              _firestore.collection(FirestoreCollections.attendanceRecords),
          field: 'studentId',
          values: scopedStudentIds.toList(),
          options: queryOptions,
        );
        records = recordDocs
            .map(_recordFromDoc)
            .where((r) => sessionIds.contains(r.sessionId))
            .toList();
      } else if (sessionIds.isNotEmpty) {
        final recordDocs = await _queryDocsWhereFieldEquals(
          collection:
              _firestore.collection(FirestoreCollections.attendanceRecords),
          field: 'sessionId',
          values: sessionIds,
          options: queryOptions,
        );
        records = recordDocs.map(_recordFromDoc).toList();
      }
      if (!_loadsAllowedForSession(loadGeneration)) return;

      final studentIds = scopedStudentIds ??
          _studentIdsFromRoster(
            signIns: signIns,
            records: records,
          );
      final regByStudentId = _regByStudentIdFromSignIns(signIns);
      final students = await _fetchStudentsByIds(
        studentIds,
        force: force,
        regByStudentId: regByStudentId,
      );
      final rosterStudents = await _augmentRosterStudents(
        signIns: signIns,
        fetched: students,
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;

      await _mergeListDetailIntoStore(
        listId: listId,
        listSessions: sessions,
        listSignIns: signIns,
        listRecords: records,
        listStudents: rosterStudents,
      );
      _loadedListDetailIds.add(listId);
      await _finalizeExpiredOpenSessions();
      unawaited(_persistScopedLocalSnapshot());
      _notifyStoreUpdated();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AttendanceRepository loadListAttendanceData($listId): $e');
        debugPrint('$st');
      }
      if (listDetailReady(listId)) {
        _loadedListDetailIds.add(listId);
        _notifyStoreUpdated();
      }
    }
  }

  Future<void> _mergeListDetailIntoStore({
    required String listId,
    required List<AttendanceSession> listSessions,
    required List<SignInRecord> listSignIns,
    required List<AttendanceRecord> listRecords,
    required List<StudentRecord> listStudents,
  }) async {
    final listSessionIds = listSessions.map((s) => s.id).toSet();
    final otherSessions =
        AttendanceStore.sessions.where((s) => s.listId != listId).toList();
    final otherRecords = AttendanceStore.attendanceRecords
        .where((r) => !listSessionIds.contains(r.sessionId))
        .toList();
    final otherSignIns =
        AttendanceStore.signIns.where((si) => si.listId != listId).toList();

    await _replaceStoreFromRemote(
      remoteLists: List<AttendanceList>.from(AttendanceStore.lists),
      remoteSessions: [...otherSessions, ...listSessions],
      remoteRecords: [...otherRecords, ...listRecords],
      remoteStudents: listStudents,
      remoteSignIns: [...otherSignIns, ...listSignIns],
    );
  }

  /// Per-value equality queries work with lecturer security rules; [whereIn] often does not.
  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _queryDocsWhereFieldEquals({
    required CollectionReference<Map<String, dynamic>> collection,
    required String field,
    required List<String> values,
    GetOptions? options,
  }) async {
    final trimmed = [
      for (final value in values)
        if (value.trim().isNotEmpty) value.trim(),
    ];
    if (trimmed.isEmpty) return const [];

    const batchSize = 6;
    final out = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (var i = 0; i < trimmed.length; i += batchSize) {
      final chunk = trimmed.skip(i).take(batchSize).toList();
      final snaps = await Future.wait(
        chunk.map((v) async {
          try {
            return options == null
                ? await collection.where(field, isEqualTo: v).get()
                : await collection.where(field, isEqualTo: v).get(options);
          } catch (_) {
            return null;
          }
        }),
      );
      for (final snap in snaps) {
        if (snap != null) out.addAll(snap.docs);
      }
    }
    return out;
  }

  String? _snapshotUserId() =>
      AuthRepository.instance.currentFirebaseUid?.trim();

  String? _normalizedStudentRegistrationForCache() {
    final scoped = _loadScopeStudentReg?.trim();
    if (scoped != null && scoped.isNotEmpty) return scoped;
    final fromAuth = currentStudentLoadRegistration();
    if (fromAuth != null && fromAuth.isNotEmpty) return fromAuth;
    final raw = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (raw == null || raw.isEmpty) return null;
    return StudentRegistrationNumber.normalize(raw);
  }

  void _ensureSnapshotStudentScope() {
    if (_loadScopeStudentReg != null && _loadScopeStudentReg!.isNotEmpty) {
      return;
    }
    final reg = _normalizedStudentRegistrationForCache();
    if (reg != null) {
      _loadScopeStudentReg = reg;
      _loadScopeLecturerUid = null;
    }
  }

  Future<bool> _restoreStudentScopedSnapshot(String normalizedReg) async {
    _loadScopeStudentReg = normalizedReg;
    _loadScopeLecturerUid = null;
    return _restoreLocalSnapshot(null, loadGeneration: _loadGeneration);
  }

  Set<String>? _scopedStudentIdsForListDetail() {
    if (isStudentScopedUser()) {
      final ids = studentIdsForCurrentUserInStore();
      return ids.isEmpty ? null : ids;
    }
    if (_likelyStudentBeforeRoleCheck()) {
      final reg = _normalizedStudentRegistrationForCache();
      if (reg == null) return null;
      final ids = AttendanceStore.studentIdsForRegistrationNormalized(reg);
      return ids.isEmpty ? null : ids;
    }
    return null;
  }

  /// Lecturers persist under `lec:<uid>`; students under `stu:<reg>` — same snapshot format.
  Future<void> _persistScopedLocalSnapshot() async {
    if (isStudentScopedUser() || _normalizedStudentRegistrationForCache() != null) {
      _ensureSnapshotStudentScope();
      await _persistLocalSnapshot(null);
      return;
    }
    await _persistLocalSnapshot(currentLecturerLoadScopeUid());
  }

  String _scopeTagFor(String? lecturerScopeUid) =>
      AttendanceLocalSnapshot.scopeTagFor(
        lecturerScopeUid: lecturerScopeUid,
        studentRegistration: _loadScopeStudentReg,
      );

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
    if (tag.startsWith('stu:')) {
      _loadScopeStudentReg =
          StudentRegistrationNumber.normalize(tag.substring(4));
      _loadScopeLecturerUid = null;
      unawaited(_rehydrateStudentPendingWorkIntoStore());
    } else {
      _loadScopeLecturerUid =
          lecturerScopeUid != null && lecturerScopeUid.isNotEmpty
              ? lecturerScopeUid
              : null;
    }
    _lecturerScopeIncludesSessions = true;
    await PendingListCreateQueue.rehydrateIntoStore();
    _reconcileLegacyStudentIdsInStore();
    _markAllStoreListsDetailLoaded();
    _notifyStoreUpdated();
    return true;
  }

  Future<void> _replaceListsOnly(List<AttendanceList> remoteLists) async {
    if (!AuthRepository.instance.isLoggedIn) return;
    // Wrong-scope or in-flight list refresh can return empty before role hydration;
    // keep visible lists until a non-empty server response arrives.
    if (remoteLists.isEmpty && AttendanceStore.lists.isNotEmpty) return;
    final listsById = {for (final l in remoteLists) l.id: l};
    for (final e in await PendingListCreateQueue.loadAll()) {
      listsById[e.list.id] = e.list;
    }
    final nextIds = listsById.keys.toSet();
    for (final l in AttendanceStore.lists) {
      if (!nextIds.contains(l.id)) {
        await _purgeListLocally(l.id);
      }
    }
    AttendanceStore.replaceLists(listsById.values.toList());
  }

  Future<List<AttendanceList>> _fetchLecturerLists(
    String uid, {
    required bool force,
  }) async {
    final queryOptions = _loadQueryOptions(force: force);
    final listsById = <String, AttendanceList>{};

    Future<void> mergeAssigned() async {
      try {
        final assignedSnap = await _firestore
            .collection(FirestoreCollections.attendanceLists)
            .where('lecturerUid', isEqualTo: uid)
            .get(queryOptions);
        for (final d in assignedSnap.docs) {
          listsById[d.id] = _listFromDoc(d);
        }
      } catch (_) {}
    }

    Future<void> mergeCreated() async {
      try {
        final createdSnap = await _firestore
            .collection(FirestoreCollections.attendanceLists)
            .where('createdBy', isEqualTo: uid)
            .get(queryOptions);
        for (final d in createdSnap.docs) {
          listsById.putIfAbsent(d.id, () => _listFromDoc(d));
        }
      } catch (_) {}
    }

    await Future.wait([mergeAssigned(), mergeCreated()]);
    return listsById.values
        .where((l) => attendanceListAccessibleToLecturer(l, uid))
        .toList();
  }

  Future<void> _persistLocalSnapshot(String? lecturerScopeUid) async {
    final uid = _snapshotUserId();
    if (uid == null || uid.isEmpty) return;
    _ensureSnapshotStudentScope();
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

  /// Remote list ids for the signed-in role (null when role is not ready).
  Future<Set<String>?> _fetchAuthoritativeRemoteListIds({
    required bool force,
  }) async {
    if (!AuthRepository.instance.roleCheckDone) return null;
    final options = _loadQueryOptions(force: force);

    Future<Set<String>> withLocalEnrollment(Set<String> remote) async =>
        {...remote, ...(await _localEnrollmentListIds())};

    if (isStudentScopedUser()) {
      final reg = currentStudentLoadRegistration();
      if (reg == null || reg.isEmpty) return withLocalEnrollment({});
      final roster = await _fetchStudentsForRegistration(reg, force: force);
      final studentIds = roster.map((s) => s.id).where((id) => id.isNotEmpty);
      if (studentIds.isEmpty) return withLocalEnrollment({});
      final signInDocs = await _queryDocsWhereFieldEquals(
        collection: _firestore.collection(FirestoreCollections.signIns),
        field: 'studentId',
        values: studentIds.toList(),
        options: options,
      );
      final remoteIds = signInDocs
          .map((d) => (d.data()['listId'] as String?)?.trim() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      return withLocalEnrollment(remoteIds);
    }

    final auth = AuthRepository.instance;
    final lecturerScope = currentLecturerLoadScopeUid();
    if (lecturerScope != null && lecturerScope.isNotEmpty) {
      final lists = await _fetchLecturerLists(lecturerScope, force: force);
      return withLocalEnrollment(lists.map((l) => l.id).toSet());
    }

    if (auth.adminCheckDone && auth.isAdmin) {
      try {
        final snap = await _firestore
            .collection(FirestoreCollections.attendanceLists)
            .get(options);
        return withLocalEnrollment(snap.docs.map((d) => d.id).toSet());
      } catch (_) {
        return null;
      }
    }

    return withLocalEnrollment({});
  }

  Future<List<AttendanceList>> _fetchListsByIds(
    Set<String> listIds, {
    required bool force,
  }) async {
    if (listIds.isEmpty) return const [];
    final options = _loadQueryOptions(force: force);
    final out = <AttendanceList>[];
    for (final id in listIds) {
      final trimmed = id.trim();
      if (trimmed.isEmpty) continue;
      try {
        final d = await _firestore
            .collection(FirestoreCollections.attendanceLists)
            .doc(trimmed)
            .get(options);
        if (d.exists) out.add(_listFromDoc(d));
      } catch (_) {}
    }
    return out;
  }

  Future<List<AttendanceSession>> _fetchSessionsByIds(
    Set<String> sessionIds, {
    required bool force,
  }) async {
    if (sessionIds.isEmpty) return const [];
    final options = _loadQueryOptions(force: force);
    final out = <AttendanceSession>[];
    for (final id in sessionIds) {
      final trimmed = id.trim();
      if (trimmed.isEmpty) continue;
      try {
        final d = await _firestore
            .collection(FirestoreCollections.attendanceSessions)
            .doc(trimmed)
            .get(options);
        if (d.exists) out.add(_sessionFromDoc(d));
      } catch (_) {}
    }
    return out;
  }

  Map<String, String> _regByStudentIdFromSignIns(Iterable<SignInRecord> signIns) {
    final out = <String, String>{};
    for (final si in signIns) {
      final sid = si.studentId.trim();
      final reg = si.registrationNumber?.trim().toUpperCase() ?? '';
      if (sid.isEmpty || reg.isEmpty) continue;
      out.putIfAbsent(sid, () => reg);
    }
    return out;
  }

  Future<StudentRecord?> _fetchStudentDocByIdOrReg(
    String studentId, {
    String? registrationNumber,
    required GetOptions? options,
  }) async {
    final trimmedId = studentId.trim();
    if (trimmedId.isEmpty) return null;

    if (isStudentScopedUser()) {
      final ownReg = currentStudentLoadRegistration()?.trim().toUpperCase();
      if (ownReg == null || ownReg.isEmpty) return null;
      final hintedReg = registrationNumber?.trim().toUpperCase() ?? '';
      final reg = hintedReg.isNotEmpty ? hintedReg : ownReg;
      if (reg != ownReg) return null;
      try {
        final byReg = await _firestore
            .collection(FirestoreCollections.students)
            .doc(reg)
            .get(options);
        if (byReg.exists) return _studentFromDoc(byReg);
      } catch (_) {}
      return null;
    }

    final regHint = registrationNumber?.trim().toUpperCase() ?? '';
    if (regHint.isNotEmpty) {
      try {
        final byReg = await _firestore
            .collection(FirestoreCollections.students)
            .doc(regHint)
            .get(options);
        if (byReg.exists) return _studentFromDoc(byReg);
      } catch (_) {}
    }

    if (StudentRegistrationNumber.isCanonicalFormat(trimmedId)) {
      try {
        final byIdReg = await _firestore
            .collection(FirestoreCollections.students)
            .doc(trimmedId)
            .get(options);
        if (byIdReg.exists) return _studentFromDoc(byIdReg);
      } catch (_) {}
      return null;
    }

    try {
      final primary = await _firestore
          .collection(FirestoreCollections.students)
          .doc(trimmedId)
          .get(options);
      if (primary.exists) return _studentFromDoc(primary);
    } catch (_) {}
    return null;
  }

  Future<List<StudentRecord>> _fetchStudentsByIds(
    Set<String> studentIds, {
    required bool force,
    Map<String, String>? regByStudentId,
  }) async {
    if (studentIds.isEmpty) return const [];
    final options = _loadQueryOptions(force: force);
    final out = <StudentRecord>[];
    final seenIds = <String>{};
    for (final id in studentIds) {
      final trimmed = id.trim();
      if (trimmed.isEmpty || seenIds.contains(trimmed)) continue;
      final student = await _fetchStudentDocByIdOrReg(
        trimmed,
        registrationNumber: regByStudentId?[trimmed],
        options: options,
      );
      if (student != null) {
        out.add(student);
        seenIds.add(trimmed);
        final reg = student.registrationNumber.trim().toUpperCase();
        if (reg.isNotEmpty) seenIds.add(reg);
      }
    }
    return out;
  }

  Set<String> _studentIdsForRegistrationLoad(
    String normalizedReg,
    Iterable<StudentRecord> rosterStudents,
  ) {
    final key = normalizedReg.trim().toUpperCase();
    final ids = <String>{
      if (StudentRegistrationNumber.isCanonicalFormat(key)) key,
      for (final s in rosterStudents)
        if (s.id.trim().isNotEmpty) s.id.trim(),
    };
    for (final s in AttendanceStore.students) {
      if (s.registrationNumber.trim().toUpperCase() != key) continue;
      if (s.id.trim().isNotEmpty) ids.add(s.id.trim());
    }
    for (final si in AttendanceStore.signIns) {
      final sid = si.studentId.trim();
      if (sid.isEmpty) continue;
      final siReg = si.registrationNumber?.trim().toUpperCase() ?? '';
      if (siReg == key || ids.contains(sid)) ids.add(sid);
    }
    ids.removeWhere((id) => id.isEmpty);
    return ids;
  }

  Set<String> _studentIdsFromRoster({
    required Iterable<SignInRecord> signIns,
    required Iterable<AttendanceRecord> records,
  }) {
    return {
      ...signIns.map((s) => s.studentId),
      ...records.map((r) => r.studentId),
    }..removeWhere((id) => id.trim().isEmpty);
  }

  Future<List<StudentRecord>> _fetchStudentsForRegistration(
    String reg, {
    required bool force,
  }) async {
    final normalized = reg.trim().toUpperCase();
    if (normalized.isEmpty) return const [];
    try {
      final snap = await _firestore
          .collection(FirestoreCollections.students)
          .where('registrationNumber', isEqualTo: normalized)
          .get(_loadQueryOptions(force: force));
      return snap.docs.map(_studentFromDoc).toList();
    } catch (_) {
      return const [];
    }
  }

  void _markStoreSyncedFromServer() {
    _usingLocalSnapshot = false;
  }

  Future<void> _executeLoadAll(
    bool force,
    String? scopeToLecturerUid, {
    bool listsOnly = false,
  }) async {
    final loadGeneration = _loadGeneration;
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (_firestoreIfReady == null) return;

    if (listsOnly) {
      await _executeLoadListsFast(
        force,
        scopeToLecturerUid,
        loadGeneration,
      );
      return;
    }

    await _awaitRoleChecksDone();
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (!AuthRepository.instance.roleCheckDone) return;

    if (isStudentScopedUser()) {
      final reg = currentStudentLoadRegistration();
      if (reg != null && reg.isNotEmpty) {
        await _executeLoadAllForStudent(force, reg, loadGeneration);
      }
      return;
    }

    final explicitScope = scopeToLecturerUid?.trim();
    final effectiveScope = (explicitScope != null && explicitScope.isNotEmpty)
        ? explicitScope
        : currentLecturerLoadScopeUid();
    if (effectiveScope != null && effectiveScope.isNotEmpty) {
      await _executeLoadAllForLecturer(
        force,
        effectiveScope,
        listsOnly: listsOnly,
      );
      return;
    }

    final auth = AuthRepository.instance;
    if (auth.adminCheckDone && auth.isAdmin) {
      await _executeLoadAllForStaff(
        force,
        loadGeneration,
        listsOnly: listsOnly,
      );
    }
  }

  Future<void> _executeLoadListsFast(
    bool force,
    String? scopeToLecturerUid,
    int loadGeneration,
  ) async {
    if (!_loadsAllowedForSession(loadGeneration)) return;
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn) return;

    final explicitScope = scopeToLecturerUid?.trim();
    final uid = auth.currentFirebaseUid?.trim();
    final lecturerScope = (explicitScope != null && explicitScope.isNotEmpty)
        ? explicitScope
        : uid;

    if (lecturerScope != null && lecturerScope.isNotEmpty) {
      await _executeLoadAllForLecturer(
        force,
        lecturerScope,
        listsOnly: true,
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;
      if (AttendanceStore.lists.isNotEmpty) return;
    }

    if (auth.adminCheckDone && auth.isAdmin) {
      await _executeLoadAllForStaff(force, loadGeneration, listsOnly: true);
      return;
    }

    if (!auth.roleCheckDone) {
      await _awaitRoleChecksDone(timeout: const Duration(seconds: 2));
    }
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (!auth.roleCheckDone) return;

    if (isStudentScopedUser()) return;

    if (auth.isAdmin) {
      await _executeLoadAllForStaff(force, loadGeneration, listsOnly: true);
      return;
    }

    final scope = currentLecturerLoadScopeUid();
    if (scope != null && scope.isNotEmpty) {
      await _executeLoadAllForLecturer(force, scope, listsOnly: true);
    }
  }

  Future<bool> _keepStudentStoreFromLocalSnapshot(
    String normalizedReg,
    int loadGeneration,
  ) async {
    if (!AttendanceStore.hasStudentSessionHistoryForRegistrationNormalized(
          normalizedReg,
        ) ||
        !AttendanceStore.hasAttendanceDataForRegistrationNormalized(
          normalizedReg,
        )) {
      await _restoreStudentScopedSnapshot(normalizedReg);
    }
    if (!_loadsAllowedForSession(loadGeneration)) return false;
    if (!AttendanceStore.hasAttendanceDataForRegistrationNormalized(
      normalizedReg,
    )) {
      return false;
    }
    _isLoaded = true;
    _usingLocalSnapshot = true;
    _loadScopeStudentReg = normalizedReg;
    _loadScopeLecturerUid = null;
    _markAllStoreListsDetailLoaded();
    await _rehydrateStudentPendingWorkIntoStore();
    _notifyStoreUpdated();
    return true;
  }

  /// Merges queued offline check-ins into [AttendanceStore] so profile/history
  /// screens can show present rows after restart without waiting for sync.
  Future<void> _rehydrateStudentPendingWorkIntoStore() async {
    if (!AuthRepository.instance.isLoggedIn) return;
    final pendingCheckIns = await PendingCheckInQueue.loadAll();
    if (pendingCheckIns.isEmpty) return;

    var changed = false;
    for (final e in pendingCheckIns) {
      final row = e.toAttendanceRecord();
      final existing = AttendanceStore.attendanceRecordForSessionStudent(
        row.sessionId,
        row.studentId,
      );
      if (existing != null && existing.present && existing.verified) continue;
      if (existing != null) {
        AttendanceStore.updateAttendanceRecord(row);
      } else {
        AttendanceStore.addAttendanceRecordIfAbsent(row);
      }
      changed = true;
    }
    if (!changed) return;
    AttendanceStore.invalidateLookupCaches();
    _notifyStoreUpdated();
    unawaited(_persistScopedLocalSnapshot());
  }

  Future<void> _executeLoadAllForStudent(
    bool force,
    String normalizedReg,
    int loadGeneration,
  ) async {
    if (!_loadsAllowedForSession(loadGeneration)) return;

    _ensureSnapshotStudentScope();
    _loadScopeStudentReg = normalizedReg;
    _loadScopeLecturerUid = null;

    final online = AppConnectivity.instance.isOnline;
    if (!online && !force) {
      if (await _keepStudentStoreFromLocalSnapshot(
        normalizedReg,
        loadGeneration,
      )) {
        await _finalizeExpiredOpenSessions();
      }
      return;
    }

    final sessionHistoryReady =
        AttendanceStore.hasStudentSessionHistoryForRegistrationNormalized(
      normalizedReg,
    );
    if (_isLoaded &&
        !force &&
        _loadScopeStudentReg == normalizedReg &&
        sessionHistoryReady) {
      if (online) {
        await reconcileDeletedListsAgainstRemote();
      }
      await _finalizeExpiredOpenSessions();
      return;
    }

    if (_storeLooksEmpty() && !online && !force) {
      await _restoreLocalSnapshot(null, loadGeneration: loadGeneration);
    }
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (!online && _isLoaded && !force) {
      await _finalizeExpiredOpenSessions();
      return;
    }

    try {
      _reconcileLegacyStudentIdsInStore();
      final rosterStudents =
          await _fetchStudentsForRegistration(normalizedReg, force: force);
      if (!_loadsAllowedForSession(loadGeneration)) return;

      final studentIds =
          _studentIdsForRegistrationLoad(normalizedReg, rosterStudents);
      if (studentIds.isEmpty) {
        if (!online ||
            AttendanceStore.hasAttendanceDataForRegistrationNormalized(
              normalizedReg,
            )) {
          if (await _keepStudentStoreFromLocalSnapshot(
            normalizedReg,
            loadGeneration,
          )) {
            return;
          }
        }
        if (!online) {
          _notifyStoreUpdated();
          return;
        }
        await _replaceStoreFromRemote(
          remoteLists: const [],
          remoteSessions: const [],
          remoteRecords: const [],
          remoteStudents: const [],
          remoteSignIns: const [],
        );
        _isLoaded = true;
        unawaited(_persistScopedLocalSnapshot());
        _notifyStoreUpdated();
        return;
      }

      final queryOptions = _loadQueryOptions(force: force);
      final signInDocs = await _queryDocsWhereFieldEquals(
        collection: _firestore.collection(FirestoreCollections.signIns),
        field: 'studentId',
        values: studentIds.toList(),
        options: queryOptions,
      );
      final signIns = signInDocs.map(_signInFromDoc).toList();
      final listIds = signIns.map((s) => s.listId).toSet();

      final recordDocs = await _queryDocsWhereFieldEquals(
        collection:
            _firestore.collection(FirestoreCollections.attendanceRecords),
        field: 'studentId',
        values: studentIds.toList(),
        options: queryOptions,
      );
      final records = recordDocs.map(_recordFromDoc).toList();

      if (!_loadsAllowedForSession(loadGeneration)) return;
      await _replaceStoreFromRemote(
        remoteLists: List<AttendanceList>.from(AttendanceStore.lists),
        remoteSessions: List<AttendanceSession>.from(AttendanceStore.sessions),
        remoteRecords: records,
        remoteStudents: rosterStudents,
        remoteSignIns: signIns,
      );
      _isLoaded = true;
      _notifyStoreUpdated();

      final listIdsFromSignIns = Set<String>.from(listIds);
      var sessions = <AttendanceSession>[];
      if (listIds.isNotEmpty) {
        final sessionDocs = await _queryDocsWhereFieldEquals(
          collection:
              _firestore.collection(FirestoreCollections.attendanceSessions),
          field: 'listId',
          values: listIds.toList(),
          options: queryOptions,
        );
        sessions = sessionDocs.map(_sessionFromDoc).toList();
      }

      final loadedSessionIds = sessions.map((s) => s.id).toSet();
      final recordSessionIds = records.map((r) => r.sessionId).toSet();
      final missingRecordSessionIds = recordSessionIds
          .where((id) => !loadedSessionIds.contains(id))
          .toSet();
      if (missingRecordSessionIds.isNotEmpty) {
        final extraSessions = await _fetchSessionsByIds(
          missingRecordSessionIds,
          force: force,
        );
        for (final sess in extraSessions) {
          if (loadedSessionIds.add(sess.id)) {
            sessions.add(sess);
          }
          listIds.add(sess.listId);
        }
      }

      final listIdsNeedingFullSessions =
          listIds.difference(listIdsFromSignIns);
      if (listIdsNeedingFullSessions.isNotEmpty) {
        final extraListSessionDocs = await _queryDocsWhereFieldEquals(
          collection:
              _firestore.collection(FirestoreCollections.attendanceSessions),
          field: 'listId',
          values: listIdsNeedingFullSessions.toList(),
          options: queryOptions,
        );
        for (final doc in extraListSessionDocs) {
          final sess = _sessionFromDoc(doc);
          if (loadedSessionIds.add(sess.id)) {
            sessions.add(sess);
          }
        }
      }

      if (!_loadsAllowedForSession(loadGeneration)) return;
      await _replaceStoreFromRemote(
        remoteLists: List<AttendanceList>.from(AttendanceStore.lists),
        remoteSessions: sessions,
        remoteRecords: records,
        remoteStudents: rosterStudents,
        remoteSignIns: signIns,
      );
      _notifyStoreUpdated();

      final lists = await _fetchListsByIds(listIds, force: force);

      if (!_loadsAllowedForSession(loadGeneration)) return;

      await _replaceStoreFromRemote(
        remoteLists: lists,
        remoteSessions: sessions,
        remoteRecords: records,
        remoteStudents: rosterStudents,
        remoteSignIns: signIns,
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;
      _updateCodeCounter();
      _isLoaded = true;
      _markStoreSyncedFromServer();
      _markAllStoreListsDetailLoaded();

      await _finalizeExpiredOpenSessions();
      unawaited(PushController.instance.syncListTopicsFromStore());
      try {
        await _persistScopedLocalSnapshot();
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint(
            'AttendanceRepository student loadAll snapshot persist failed: $e',
          );
          debugPrint('$st');
        }
      }
      unawaited(AttendanceRemoteListWatch.instance.start());
      unawaited(AttendanceRemoteRecordWatch.instance.start());
      unawaited(correctMetadataMatchedAbsentRollForSignedInLists());
      _notifyStoreUpdated();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AttendanceRepository student loadAll failed: $e');
        debugPrint('$st');
      }
      if (!_loadsAllowedForSession(loadGeneration)) return;
      if (!_isLoaded) {
        await _restoreLocalSnapshot(null, loadGeneration: loadGeneration);
      }
      if (!_isLoaded) {
        _usingLocalSnapshot = false;
      } else {
        _notifyStoreUpdated();
      }
    }
  }

  Future<void> _executeLoadAllForStaff(
    bool force,
    int loadGeneration, {
    bool listsOnly = false,
  }) async {
    if (!_loadsAllowedForSession(loadGeneration)) return;

    _loadScopeStudentReg = null;

    final online = AppConnectivity.instance.isOnline;
    if (_isLoaded && !force && _loadScopeLecturerUid == null && !listsOnly) {
      if (online) {
        await reconcileDeletedListsAgainstRemote();
      }
      await _finalizeExpiredOpenSessions();
      return;
    }
    if (_storeLooksEmpty() && !online && !force) {
      await _restoreLocalSnapshot(null, loadGeneration: loadGeneration);
    }
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (!online && _isLoaded && !force) {
      await PendingListCreateQueue.rehydrateIntoStore();
      await _finalizeExpiredOpenSessions();
      _notifyStoreUpdated();
      return;
    }

    try {
      final queryOptions = _loadQueryOptions(force: force);
      final listsSnap = await _firestore
          .collection(FirestoreCollections.attendanceLists)
          .get(queryOptions);
      final remoteLists = listsSnap.docs.map((d) => _listFromDoc(d)).toList();

      if (listsOnly) {
        await _replaceListsOnly(remoteLists);
        if (!_loadsAllowedForSession(loadGeneration)) return;
        _isLoaded = true;
        _loadScopeLecturerUid = null;
        _markStoreSyncedFromServer();
        await _finalizeExpiredOpenSessions();
        unawaited(PushController.instance.syncListTopicsFromStore());
        unawaited(_persistLocalSnapshot(null));
        _notifyStoreUpdated();
        return;
      }

      if (remoteLists.isEmpty) {
        await _replaceStoreFromRemote(
          remoteLists: const [],
          remoteSessions: const [],
          remoteRecords: const [],
          remoteStudents: const [],
          remoteSignIns: const [],
        );
        if (!_loadsAllowedForSession(loadGeneration)) return;
        _isLoaded = true;
        _loadScopeLecturerUid = null;
        _markStoreSyncedFromServer();
        await _finalizeExpiredOpenSessions();
        unawaited(PushController.instance.syncListTopicsFromStore());
        unawaited(_persistLocalSnapshot(null));
        _notifyStoreUpdated();
        return;
      }

      final results = await Future.wait<QuerySnapshot<Map<String, dynamic>>>([
        _firestore
            .collection(FirestoreCollections.attendanceSessions)
            .get(queryOptions),
        _firestore
            .collection(FirestoreCollections.attendanceRecords)
            .get(queryOptions),
        _firestore.collection(FirestoreCollections.signIns).get(queryOptions),
      ]);
      final sessionsSnap = results[0];
      final recordsSnap = results[1];
      final signInsSnap = results[2];

      if (!_loadsAllowedForSession(loadGeneration)) return;

      final signIns = signInsSnap.docs.map((d) => _signInFromDoc(d)).toList();
      final records = recordsSnap.docs.map((d) => _recordFromDoc(d)).toList();
      final studentIds = _studentIdsFromRoster(
        signIns: signIns,
        records: records,
      );
      final students = await _fetchStudentsByIds(
        studentIds,
        force: force,
        regByStudentId: _regByStudentIdFromSignIns(signIns),
      );

      await _replaceStoreFromRemote(
        remoteLists: remoteLists,
        remoteSessions:
            sessionsSnap.docs.map((d) => _sessionFromDoc(d)).toList(),
        remoteRecords: records,
        remoteStudents: students,
        remoteSignIns: signIns,
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;
      _updateCodeCounter();
      _isLoaded = true;
      _loadScopeLecturerUid = null;
      _markStoreSyncedFromServer();
      _markAllStoreListsDetailLoaded();

      await _finalizeExpiredOpenSessions();
      unawaited(PushController.instance.syncListTopicsFromStore());
      unawaited(_persistLocalSnapshot(null));
      unawaited(AttendanceRemoteListWatch.instance.start());
      unawaited(AttendanceRemoteRecordWatch.instance.start());
      _notifyStoreUpdated();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AttendanceRepository staff loadAll failed: $e');
        debugPrint('$st');
      }
      if (!_loadsAllowedForSession(loadGeneration)) return;
      if (!_isLoaded) {
        await _restoreLocalSnapshot(null, loadGeneration: loadGeneration);
      }
      if (!_isLoaded) {
        _usingLocalSnapshot = false;
      } else {
        _notifyStoreUpdated();
      }
    }
  }

  Future<void> _executeLoadAllForLecturer(
    bool force,
    String uid, {
    bool listsOnly = false,
  }) async {
    final loadGeneration = _loadGeneration;
    if (!_loadsAllowedForSession(loadGeneration)) return;
    final online = AppConnectivity.instance.isOnline;
    if (_isLoaded && !force && _loadScopeLecturerUid == uid) {
      if (listsOnly) {
        if (AttendanceStore.lists.isNotEmpty) {
          if (online) {
            await reconcileDeletedListsAgainstRemote();
          }
          await _finalizeExpiredOpenSessions();
          return;
        }
      } else if (_lecturerScopeIncludesSessions) {
        if (online) {
          await reconcileDeletedListsAgainstRemote();
        }
        await _finalizeExpiredOpenSessions();
        return;
      }
    }
    if (_storeLooksEmpty() && !force) {
      await _restoreLocalSnapshot(uid, loadGeneration: loadGeneration);
    }
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (!online && _isLoaded && !force) {
      await PendingListCreateQueue.rehydrateIntoStore();
      await _finalizeExpiredOpenSessions();
      _notifyStoreUpdated();
      return;
    }

    try {
      final queryOptions = _loadQueryOptions(force: force);
      final lists = await _fetchLecturerLists(uid, force: force);

      if (listsOnly) {
        await _replaceListsOnly(lists);
        if (!_loadsAllowedForSession(loadGeneration)) return;
        _isLoaded = true;
        _loadScopeLecturerUid = uid;
        _lecturerScopeIncludesSessions = false;
        _loadScopeStudentReg = null;
        _markStoreSyncedFromServer();
        await _finalizeExpiredOpenSessions();
        unawaited(PushController.instance.syncListTopicsFromStore());
        unawaited(_persistLocalSnapshot(uid));
        _notifyStoreUpdated();
        return;
      }

      if (lists.isEmpty) {
        await _replaceStoreFromRemote(
          remoteLists: const [],
          remoteSessions: const [],
          remoteRecords: const [],
          remoteStudents: const [],
          remoteSignIns: const [],
        );
        if (!_loadsAllowedForSession(loadGeneration)) return;
        _isLoaded = true;
        _loadScopeLecturerUid = uid;
        _lecturerScopeIncludesSessions = true;
        _loadScopeStudentReg = null;
        _markStoreSyncedFromServer();
        await _finalizeExpiredOpenSessions();
        unawaited(PushController.instance.syncListTopicsFromStore());
        unawaited(_persistLocalSnapshot(uid));
        _notifyStoreUpdated();
        return;
      }

      final listIds = lists.map((l) => l.id).toList();

      final sessionAndSignInDocs = await Future.wait([
        _queryDocsWhereFieldEquals(
          collection:
              _firestore.collection(FirestoreCollections.attendanceSessions),
          field: 'listId',
          values: listIds,
          options: queryOptions,
        ),
        _queryDocsWhereFieldEquals(
          collection: _firestore.collection(FirestoreCollections.signIns),
          field: 'listId',
          values: listIds,
          options: queryOptions,
        ),
      ]);
      final sessions =
          sessionAndSignInDocs[0].map(_sessionFromDoc).toList();
      final signIns = sessionAndSignInDocs[1].map(_signInFromDoc).toList();

      final sessionIds = sessions.map((s) => s.id).toList();
      final recordDocs = await _queryDocsWhereFieldEquals(
        collection:
            _firestore.collection(FirestoreCollections.attendanceRecords),
        field: 'sessionId',
        values: sessionIds,
        options: queryOptions,
      );
      final records = recordDocs.map(_recordFromDoc).toList();

      final studentIds = _studentIdsFromRoster(
        signIns: signIns,
        records: records,
      );
      final students = await _fetchStudentsByIds(
        studentIds,
        force: force,
        regByStudentId: _regByStudentIdFromSignIns(signIns),
      );

      if (!_loadsAllowedForSession(loadGeneration)) return;

      await _replaceStoreFromRemote(
        remoteLists: lists,
        remoteSessions: sessions,
        remoteRecords: records,
        remoteSignIns: signIns,
        remoteStudents: students,
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;
      _updateCodeCounter();
      _isLoaded = true;
      _loadScopeLecturerUid = uid;
      _lecturerScopeIncludesSessions = true;
      _loadScopeStudentReg = null;
      _markStoreSyncedFromServer();
      _markAllStoreListsDetailLoaded();

      await _finalizeExpiredOpenSessions();
      unawaited(PushController.instance.syncListTopicsFromStore());
      unawaited(_persistLocalSnapshot(uid));
      unawaited(AttendanceRemoteListWatch.instance.start());
      unawaited(AttendanceRemoteRecordWatch.instance.start());
      _notifyStoreUpdated();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AttendanceRepository lecturer loadAll failed: $e');
        debugPrint('$st');
      }
      if (!_loadsAllowedForSession(loadGeneration)) return;
      if (!_isLoaded) {
        await _restoreLocalSnapshot(uid, loadGeneration: loadGeneration);
      }
      if (!_isLoaded) {
        _usingLocalSnapshot = false;
      } else {
        _notifyStoreUpdated();
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
    return recordFromFirestoreDoc(d);
  }

  /// Public parser for realtime attendance record listeners.
  static AttendanceRecord recordFromFirestoreDoc(
    DocumentSnapshot<Map<String, dynamic>> d,
  ) {
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
      studentName: (data['studentName'] as String?)?.trim(),
      registrationNumber: (data['registrationNumber'] as String?)?.trim(),
    );
  }

  SignInRecord _mergeSignInWithLocal(
    SignInRecord remote,
    List<SignInRecord> prior,
  ) {
    final local = prior
        .where((s) => _signInDedupKey(s) == _signInDedupKey(remote))
        .firstOrNull;
    if (local == null) return remote;
    final remoteName = remote.studentName?.trim() ?? '';
    final remoteReg = remote.registrationNumber?.trim().toUpperCase() ?? '';
    if (remoteName.isNotEmpty && remoteReg.isNotEmpty) return remote;
    return remote.copyWith(
      studentName: remoteName.isNotEmpty ? remote.studentName : local.studentName,
      registrationNumber:
          remoteReg.isNotEmpty ? remote.registrationNumber : local.registrationNumber,
    );
  }

  StudentRecord? _studentRecordForId(String studentId) {
    final trimmed = studentId.trim();
    if (trimmed.isEmpty) return null;
    return AttendanceStore.studentMapById()[trimmed] ??
        AttendanceStore.students.where((s) => s.id == trimmed).firstOrNull;
  }

  StudentRecord _upgradeStudentIfNeeded(
    StudentRecord existing,
    String name,
    String initials,
  ) {
    final trimmedName = name.trim();
    final trimmedIni = normalizeSessionCodeInput(initials);
    final nameBetter = trimmedName.isNotEmpty &&
        (existing.name.trim().isEmpty || existing.name.trim() == 'Unknown');
    final iniBetter =
        trimmedIni.isNotEmpty && existing.initials.trim().isEmpty;
    if (!nameBetter && !iniBetter) return existing;
    final upgraded = StudentRecord(
      id: existing.id,
      name: nameBetter ? trimmedName : existing.name,
      registrationNumber: existing.registrationNumber,
      threeDigitCode: existing.threeDigitCode,
      initials: iniBetter ? trimmedIni : existing.initials,
    );
    AttendanceStore.upsertStudent(upgraded);
    return upgraded;
  }

  Map<String, dynamic> _studentToFirestoreMap(StudentRecord record) =>
      <String, dynamic>{
        'name': record.name,
        'registrationNumber': record.registrationNumber,
        'threeDigitCode': record.threeDigitCode,
        'initials': record.initials,
      };

  Future<void> _persistStudentRecord(
    StudentRecord record, {
    bool awaitWhenOnline = false,
  }) async {
    if (_firestoreIfReady == null) return;
    final reg = record.registrationNumber.trim().toUpperCase();
    final payload = _studentToFirestoreMap(record);

    Future<void> upload() async {
      await _firestore
          .collection(FirestoreCollections.students)
          .doc(record.id)
          .set(payload, SetOptions(merge: true));
      if (reg.isNotEmpty && reg != record.id.trim()) {
        await _firestore
            .collection(FirestoreCollections.students)
            .doc(reg)
            .set(payload, SetOptions(merge: true));
      }
    }

    if (!AppConnectivity.instance.hasNetworkInterface) {
      unawaited(upload().catchError((_) {}));
      return;
    }
    if (awaitWhenOnline) {
      try {
        await upload().timeout(_sessionPublishTimeout);
      } catch (_) {}
    } else {
      unawaited(upload().catchError((_) {}));
    }
  }

  /// Fills roster gaps when student docs are missing but sign-ins carry metadata.
  Future<List<StudentRecord>> _augmentRosterStudents({
    required List<SignInRecord> signIns,
    required List<StudentRecord> fetched,
  }) async {
    final byId = <String, StudentRecord>{for (final s in fetched) s.id: s};
    final out = List<StudentRecord>.from(fetched);

    for (final si in signIns) {
      final sid = si.studentId.trim();
      if (sid.isEmpty) continue;

      final existing = byId[sid];
      var name = si.studentName?.trim() ?? '';
      var reg = si.registrationNumber?.trim().toUpperCase() ?? '';

      if (existing != null) {
        if (name.isEmpty) name = existing.name.trim();
        if (reg.isEmpty) {
          reg = existing.registrationNumber.trim().toUpperCase();
        }
        if (name.isEmpty && reg.isNotEmpty) {
          name = await _lookupFullNameOnRegistrationDoc(reg) ?? '';
        }
        if (name.isNotEmpty &&
            (existing.name.trim().isEmpty ||
                existing.name.trim() == 'Unknown')) {
          final upgraded = _upgradeStudentIfNeeded(
            existing,
            name,
            deriveStudentInitialsFromName(name),
          );
          byId[sid] = upgraded;
          final idx = out.indexWhere((s) => s.id == sid);
          if (idx >= 0) {
            out[idx] = upgraded;
          }
        }
        continue;
      }

      if (!isStudentScopedUser() && (name.isEmpty || reg.isEmpty)) {
        final remote = await _fetchStudentDocByIdOrReg(
          sid,
          registrationNumber: reg.isNotEmpty ? reg : null,
          options: null,
        );
        if (remote != null) {
          byId[sid] = remote;
          out.add(remote);
          continue;
        }
      }

      if (isStudentScopedUser() && reg.isEmpty) {
        final ownReg = currentStudentLoadRegistration()?.trim().toUpperCase();
        if (ownReg != null && ownReg.isNotEmpty) reg = ownReg;
      }

      if (name.isEmpty && reg.isNotEmpty) {
        name = await _lookupFullNameOnRegistrationDoc(reg) ?? '';
      }
      if (name.isEmpty && reg.isEmpty) continue;

      final synthetic = StudentRecord(
        id: sid,
        name: name.isNotEmpty ? name : 'Unknown',
        registrationNumber: reg.isNotEmpty ? reg : '—',
        threeDigitCode: '000',
        initials: name.isNotEmpty
            ? deriveStudentInitialsFromName(name)
            : '??',
      );
      byId[sid] = synthetic;
      out.add(synthetic);
    }
    return out;
  }

  Future<String?> _lookupFullNameOnRegistrationDoc(String reg) async {
    final normalized = StudentRegistrationNumber.normalize(reg);
    if (normalized.isEmpty) return null;
    try {
      final snap = await _firestore
          .collection(FirestoreCollections.studentRegistrations)
          .doc(normalized)
          .get();
      if (!snap.exists || snap.data() == null) return null;
      final name = (snap.data()!['fullName'] as String?)?.trim();
      return (name != null && name.isNotEmpty) ? name : null;
    } catch (_) {
      return null;
    }
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

  Future<ListCreateResult> addList(
    AttendanceList list, {
    String? pendingLecturerStaffNumber,
  }) async {
    AttendanceStore.addList(list);
    return persistOnlineFirst(
      timeout: _sessionPublishTimeout,
      persistOnline: () async {
        await _firestore
            .collection(FirestoreCollections.attendanceLists)
            .doc(list.id)
            .set(_listToMap(list));
        await PendingListCreateQueue.removeByListId(list.id);
        unawaited(_persistScopedLocalSnapshot());
        return (list: list, syncedToServer: true);
      },
      persistOffline: () async {
        await PendingListCreateQueue.enqueue(
          list,
          pendingLecturerStaffNumber: pendingLecturerStaffNumber,
        );
        unawaited(_persistScopedLocalSnapshot());
        return (list: list, syncedToServer: false);
      },
    );
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

    final cachedUid = await StaffNumberDirectoryCache.lookup(sn);
    if (cachedUid != null && cachedUid.isNotEmpty) {
      return cachedUid;
    }

    final offline = !AppConnectivity.instance.isOnline;
    final cacheOptions =
        const GetOptions(source: Source.serverAndCache);

    try {
      final staffSnap = await _firestore
          .collection(FirestoreCollections.staffNumbers)
          .doc(sn)
          .get(offline ? cacheOptions : const GetOptions());
      final fromStaff = (staffSnap.data()?['uid'] as String?)?.trim();
      if (fromStaff != null && fromStaff.isNotEmpty) {
        unawaited(StaffNumberDirectoryCache.remember(sn, fromStaff));
        return fromStaff;
      }
    } catch (_) {}

    try {
      final lectSnap = await _firestore
          .collection(FirestoreCollections.lecturers)
          .where('staffNumber', isEqualTo: sn)
          .limit(1)
          .get(offline ? cacheOptions : const GetOptions());
      if (lectSnap.docs.isNotEmpty) {
        final uid = lectSnap.docs.first.id;
        unawaited(StaffNumberDirectoryCache.remember(sn, uid));
        return uid;
      }
    } catch (_) {}

    return null;
  }

  /// Admin: assigned lecturer from manual KIU staff ID.
  Future<
      ({
        String? uid,
        String? error,
        String? deferredStaffNumber,
      })> resolveAssignedLecturerForAdmin({
    String? selectedUid,
    String manualStaffNumberRaw = '',
    Iterable<({String uid, String staffNumber})>? knownRows,
  }) async {
    final manual = manualStaffNumberRaw.trim();
    if (manual.isEmpty) {
      return (
        uid: null,
        error: 'Enter the assigned lecturer KIU staff ID.',
        deferredStaffNumber: null,
      );
    }
    final normalized = StaffAuthEmail.normalizeStaffNumberFlexible(manual);
    if (normalized == null) {
      return (
        uid: null,
        error: 'Enter a valid KIU staff ID (e.g. KIU-0042 or 0042).',
        deferredStaffNumber: null,
      );
    }
    final mergedKnownRows = [
      ...?knownRows,
      ...(await StaffNumberDirectoryCache.knownRows()),
    ];
    final uid = await resolveLecturerUidByStaffNumber(
      manual,
      knownRows: mergedKnownRows,
    );
    if (uid == null) {
      if (!AppConnectivity.instance.isOnline) {
        return (
          uid: null,
          error: null,
          deferredStaffNumber: normalized,
        );
      }
      return (
        uid: null,
        error:
            'No lecturer account for $normalized. Register them under Staff & accounts first.',
        deferredStaffNumber: null,
      );
    }
    return (uid: uid, error: null, deferredStaffNumber: null);
  }

  /// Generate a join code (letter + 2 digits + letter) not used by an active session (local).
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

  /// Join code unique among local + server-active sessions when online.
  Future<String> generateUniqueSessionCodeOnlineAware() async {
    for (var attempt = 0; attempt < 50; attempt++) {
      final code = generateSessionCode();
      final normalized = normalizeSessionCodeInput(code);
      final localActive = AttendanceStore.sessions.any(
        (s) =>
            normalizeSessionCodeInput(s.sessionCode) == normalized && s.isActive,
      );
      if (localActive) continue;
      if (AppConnectivity.instance.hasNetworkInterface &&
          await _joinCodeActiveOnServer(normalized)) {
        continue;
      }
      return normalized;
    }
    return generateUniqueSessionCode();
  }

  Future<bool> _joinCodeActiveOnServer(String normalizedCode) async {
    try {
      final sessions =
          await _fetchJoinCodeSessionsFromServer(normalizedCode, limit: 12);
      return sessions.any((s) => s.isOpenForCheckIn);
    } catch (_) {
      // Fail closed: assume clash when server cannot be queried.
      return true;
    }
  }

  /// True when another open session already uses this join code.
  Future<bool> _joinCodeClashesWithOtherSession(
    String normalizedCode,
    String sessionId,
  ) async {
    final localClash = AttendanceStore.sessions.any(
      (s) =>
          s.id != sessionId &&
          normalizeSessionCodeInput(s.sessionCode) == normalizedCode &&
          s.isOpenForCheckIn,
    );
    if (localClash) return true;
    if (!AppConnectivity.instance.hasNetworkInterface) return false;
    try {
      final remote =
          await _fetchJoinCodeSessionsFromServer(normalizedCode, limit: 12);
      return remote.any((s) => s.id != sessionId && s.isOpenForCheckIn);
    } catch (_) {
      return true;
    }
  }

  /// Regenerates the join code when another open session already owns it.
  Future<String> ensureJoinCodeForSessionUpload({
    required String sessionId,
    required String sessionCode,
  }) async {
    var code = normalizeSessionCodeInput(sessionCode);
    for (var attempt = 0; attempt < 30; attempt++) {
      if (!await _joinCodeClashesWithOtherSession(code, sessionId)) {
        if (attempt > 0) {
          final existing = AttendanceStore.sessionById(sessionId);
          if (existing != null) {
            AttendanceStore.updateSession(
              AttendanceSession(
                id: existing.id,
                listId: existing.listId,
                sessionCode: code,
                latitude: existing.latitude,
                longitude: existing.longitude,
                radiusMeters: existing.radiusMeters,
                startTime: existing.startTime,
                endTime: existing.endTime,
                status: existing.status,
                createdBy: existing.createdBy,
                remoteLearning: existing.remoteLearning,
              ),
            );
            _notifyStoreUpdated();
          }
        }
        return code;
      }
      code = normalizeSessionCodeInput(generateSessionCode());
    }
    return code;
  }

  Future<List<AttendanceSession>> _fetchJoinCodeSessionsFromServer(
    String normalizedCode, {
    int limit = 16,
  }) async {
    final byId = <String, AttendanceSession>{};

    void mergeSession(AttendanceSession session) {
      final i = AttendanceStore.sessions.indexWhere((s) => s.id == session.id);
      if (i >= 0) {
        AttendanceStore.updateSession(session);
      } else {
        AttendanceStore.addSession(session);
      }
      byId[session.id] = session;
    }

    // Prefer active docs so a live session is not hidden behind many closed
    // rows sharing the same join code (Firestore limit() is unordered).
    try {
      final activeSnap = await _firestore
          .collection(FirestoreCollections.attendanceSessions)
          .where('sessionCode', isEqualTo: normalizedCode)
          .where('status', isEqualTo: SessionStatus.active.name)
          .limit(8)
          .get(_loadQueryOptions(force: true));
      for (final d in activeSnap.docs) {
        mergeSession(_sessionFromDoc(d));
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '_fetchJoinCodeSessionsFromServer active query failed: $e',
        );
      }
    }

    if (byId.length < limit) {
      final snap = await _firestore
          .collection(FirestoreCollections.attendanceSessions)
          .where('sessionCode', isEqualTo: normalizedCode)
          .limit(limit)
          .get(_loadQueryOptions(force: true));
      for (final d in snap.docs) {
        mergeSession(_sessionFromDoc(d));
      }
    }

    for (final session in AttendanceStore.sessions) {
      if (normalizeSessionCodeInput(session.sessionCode) != normalizedCode) {
        continue;
      }
      byId.putIfAbsent(session.id, () => session);
    }

    final out = byId.values.toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    return out;
  }

  AttendanceSession? _pickActiveJoinSession(
    Iterable<AttendanceSession> sessions,
  ) {
    AttendanceSession? best;
    for (final session in sessions) {
      if (!session.isOpenForCheckIn) continue;
      if (best == null || session.startTime.isAfter(best.startTime)) {
        best = session;
      }
    }
    return best;
  }

  /// True while a session started on this device is still publishing to Firestore.
  Future<bool> isSessionAwaitingServerPublish(String sessionId) async {
    if (_publishingSessionIds.contains(sessionId)) return true;
    return (await PendingSessionCreateQueue.loadAll())
        .any((e) => e.sessionId == sessionId);
  }

  Future<void> _publishNewSessionInBackground({
    required String sessionId,
    required String listId,
    required PendingSessionCreateEntry pendingEntry,
    required String sessionCode,
    required double latitude,
    required double longitude,
    required double radiusMeters,
    required DateTime startTime,
    required DateTime endTime,
    required String createdBy,
    required String? creatorUid,
    required bool remoteLearning,
    required AttendanceSession session,
  }) async {
    _publishingSessionIds.add(sessionId);
    _notifyStoreUpdated();
    try {
      final uploaded = await _uploadNewSessionToFirestore(
        sessionId: sessionId,
        listId: listId,
        pendingEntry: pendingEntry,
        sessionCode: sessionCode,
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters,
        startTime: startTime,
        endTime: endTime,
        createdBy: createdBy,
        creatorUid: creatorUid,
        remoteLearning: remoteLearning,
        session: session,
      );
      if (uploaded) {
        _invalidateSessionPublishedCache(sessionId);
        unawaited(PendingSessionCreateSync.drainUrgent());
        unawaited(prefetchSessionsForPendingCodes());
        unawaited(PendingSessionCodeSync.drainUrgent());
      }
    } finally {
      _publishingSessionIds.remove(sessionId);
      unawaited(_persistScopedLocalSnapshot());
      _notifyStoreUpdated();
    }
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

  Future<bool> _uploadNewSessionToFirestore({
    required String sessionId,
    required String listId,
    required PendingSessionCreateEntry pendingEntry,
    required String sessionCode,
    required double latitude,
    required double longitude,
    required double radiusMeters,
    required DateTime startTime,
    required DateTime endTime,
    required String createdBy,
    required String? creatorUid,
    required bool remoteLearning,
    required AttendanceSession session,
  }) async {
    final uploadCode = await ensureJoinCodeForSessionUpload(
      sessionId: sessionId,
      sessionCode: sessionCode,
    );
    final uploadSession = uploadCode == session.sessionCode
        ? session
        : AttendanceSession(
            id: session.id,
            listId: session.listId,
            sessionCode: uploadCode,
            latitude: session.latitude,
            longitude: session.longitude,
            radiusMeters: session.radiusMeters,
            startTime: session.startTime,
            endTime: session.endTime,
            status: session.status,
            createdBy: session.createdBy,
            remoteLearning: session.remoteLearning,
          );
    final sessionMap = <String, dynamic>{
      'listId': listId,
      'sessionCode': uploadCode,
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
    final sessionMetadataReady =
        remoteLearning || isSessionGeofenceConfigured(uploadSession);
    sessionMap['awaitingStudentMetadata'] = !sessionMetadataReady;
    if (!sessionMetadataReady) {
      sessionMap['metadataPendingUntil'] = Timestamp.fromDate(
        startTime.add(PendingRetention.unverifiedPending),
      );
    }
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
          await AppConnectivity.instance.ensureReachable(
            timeout: const Duration(seconds: 4),
          );
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        }
        try {
          await _firestore
              .collection(FirestoreCollections.attendanceSessions)
              .doc(sessionId)
              .set(sessionMap)
              .timeout(_sessionPublishTimeout);
          await PendingSessionCreateQueue.removeBySessionId(sessionId);
          if (!remoteLearning) {
            final listForNotice = AttendanceStore.listById(listId);
            if (listForNotice != null) {
              unawaited(
                NoticesRepository.instance
                    .publishSessionStartNotice(
                      list: listForNotice,
                      session: uploadSession,
                      createdBy: createdBy,
                    )
                    .then((err) {
                  if (err != null && kDebugMode) {
                    debugPrint('createSession: notice publish failed: $err');
                  }
                }),
              );
            }
          }
          return true;
        } catch (e) {
          if (attempt >= 2) rethrow;
        }
      }
      return false;
    } catch (_) {
      await PendingSessionCreateQueue.enqueue(pendingEntry);
      await PendingSessionCreateSync.drainUrgent();
      return false;
    }
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
    DateTime? startIntentAt,
  }) async {
    final existing = _activeSessionForList(listId);
    if (existing != null) {
      final awaitingUpload = (await PendingSessionCreateQueue.loadAll())
          .any((e) => e.sessionId == existing.id);
      return (
        session: existing,
        syncedToServer: !awaitingUpload,
        publishingInBackground:
            awaitingUpload || _publishingSessionIds.contains(existing.id),
        sessionNoticeError: null,
      );
    }

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final sessionCode = generateUniqueSessionCode();
    final startTime = startIntentAt ?? DateTime.now();
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
    _notifyStoreUpdated();
    unawaited(_persistScopedLocalSnapshot());
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
      if (AppConnectivity.instance.hasNetworkInterface) {
        unawaited(
          _firestore
              .collection(FirestoreCollections.attendanceLists)
              .doc(listId)
              .set(_listToMap(updated))
              .timeout(_sessionPublishTimeout)
              .catchError((_) {}),
        );
      }
    }
    final creatorUid = AuthRepository.instance.currentFirebaseUid?.trim();
    final pendingEntry = PendingSessionCreateEntry(
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
    );
    if (!AppConnectivity.instance.hasNetworkInterface) {
      await PendingSessionCreateQueue.enqueue(pendingEntry);
      unawaited(_persistScopedLocalSnapshot());
      return (
        session: session,
        syncedToServer: false,
        publishingInBackground: false,
        sessionNoticeError: null,
      );
    }

    unawaited(
      _publishNewSessionInBackground(
        sessionId: id,
        listId: listId,
        pendingEntry: pendingEntry,
        sessionCode: sessionCode,
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters,
        startTime: startTime,
        endTime: endTime,
        createdBy: createdBy,
        creatorUid: creatorUid,
        remoteLearning: remoteLearning,
        session: session,
      ),
    );
    unawaited(_persistScopedLocalSnapshot());
    return (
      session: session,
      syncedToServer: true,
      publishingInBackground: true,
      sessionNoticeError: null,
    );
  }

  /// Returns session if code is valid and the lecturer has not closed it.
  AttendanceSession? validateSessionCode(String code) {
    return AttendanceStore.sessionByCodeOpenForCheckIn(
      normalizeSessionCodeInput(code),
    );
  }

  /// Online sign-in: local store first, then server fetch with retries.
  Future<AttendanceSession?> resolveActiveSessionByCodeForSignIn(
    String rawCode,
  ) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) return null;

    var session = validateSessionCode(code);
    if (session != null && session.isOpenForCheckIn) return session;

    if (!AppConnectivity.instance.hasNetworkInterface) {
      return null;
    }
    if (!AppConnectivity.instance.isOnline) {
      await AppConnectivity.instance.ensureReachable(
        timeout: const Duration(seconds: 2),
      );
    }

    const attempts = 3;
    for (var i = 0; i < attempts; i++) {
      final byCode = resolveSessionByCode(rawCode);
      final byTime = resolveSessionByCodeAtTime(
        rawCode: rawCode,
        capturedAt: DateTime.now(),
      );
      final results = await Future.wait([
        byCode,
        byTime,
      ]);
      session = results[0];
      if (session != null && session.isOpenForCheckIn) return session;
      session = results[1];
      if (session != null && session.isOpenForCheckIn) return session;
      if (i + 1 < attempts) {
        await Future<void>.delayed(Duration(milliseconds: 200 * (i + 1)));
      }
    }
    return null;
  }

  /// True when Firestore has session docs for [rawCode] but none are joinable now,
  /// and the newest session by start time was explicitly closed by the lecturer.
  Future<bool> serverHasOnlyInactiveSessionForCode(String rawCode) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) return false;
    if (!AppConnectivity.instance.hasNetworkInterface) return false;
    try {
      final sessions = await _fetchJoinCodeSessionsFromServer(code, limit: 16);
      if (sessions.isEmpty) return false;
      if (sessions.any((s) => s.isOpenForCheckIn)) return false;
      final newest = sessions.first;
      final ended = newest.status == SessionStatus.closed;
      return ended;
    } catch (_) {
      return false;
    }
  }

  /// Fetches session documents matching [rawCode] from Firestore and merges them
  /// into [AttendanceStore]. Use when [validateSessionCode] is null after
  /// [loadAll] (session started after load, or first targeted fetch).
  Future<AttendanceSession?> resolveSessionByCode(String rawCode) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) return null;
    try {
      final sessions = await _fetchJoinCodeSessionsFromServer(code, limit: 16);
      final best = _pickActiveJoinSession(sessions);
      if (best != null) {
        await _ensureListLoaded(best.listId);
        return best;
      }
      return AttendanceStore.sessionByCodeOpenForCheckIn(code);
    } catch (_) {
      return AttendanceStore.sessionByCodeOpenForCheckIn(code);
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
          .get(_loadQueryOptions(force: true));
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
    } catch (e) {
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
      final sessions = await _fetchJoinCodeSessionsFromServer(code, limit: 16);
      for (final session in AttendanceStore.sessions) {
        if (normalizeSessionCodeInput(session.sessionCode) != code) continue;
        if (sessions.every((s) => s.id != session.id)) {
          sessions.add(session);
        }
      }
      sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
      AttendanceSession? bounded;
      for (final session in sessions) {
        if (isTimestampWithinSessionBounds(session, capturedAt)) {
          if (bounded == null || session.startTime.isAfter(bounded.startTime)) {
            bounded = session;
          }
        }
      }
      final bestActive = _pickActiveJoinSession(sessions);
      final picked = bounded ?? bestActive;
      if (picked != null) {
        await _ensureListLoaded(picked.listId);
      }
      return picked;
    } catch (e) {
      AttendanceSession? bounded;
      for (final session in AttendanceStore.sessions) {
        if (normalizeSessionCodeInput(session.sessionCode) != code) continue;
        if (isTimestampWithinSessionBounds(session, capturedAt)) {
          if (bounded == null || session.endTime.isAfter(bounded.endTime)) {
            bounded = session;
          }
        }
      }
      return bounded ?? AttendanceStore.sessionByCodeOpenForCheckIn(code);
    }
  }

  /// Lecturer session resolved and published on Firestore (both-party gate).
  Future<AttendanceSession?> resolvePublishedLecturerSessionForPendingClaim({
    required String sessionCodeRaw,
    required DateTime capturedAt,
    String? sessionIdHint,
  }) async {
    final session = await resolveSessionForPendingCodeEntry(
      sessionCodeRaw: sessionCodeRaw,
      capturedAt: capturedAt,
      sessionIdHint: sessionIdHint,
    );
    if (session == null) return null;
    if (!await isLecturerSessionPublishedOnServer(session.id)) return null;
    return session;
  }

  /// True when this student has a non-expired awaiting claim on the server.
  Future<bool> hasAwaitingStudentClaimOnServer({
    required String sessionCodeRaw,
    required String studentId,
  }) async {
    if (!AppConnectivity.instance.hasNetworkInterface) return false;
    final code = normalizeSessionCodeInput(sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return false;
    final docId = PendingSessionCodeClaimUpload.claimDocId(
      normalizedCode: code,
      studentId: studentId,
    );
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.checkInAttempts)
          .doc(docId)
          .get(_loadQueryOptions(force: false));
      if (!doc.exists) return false;
      final data = doc.data();
      if (data == null) return false;
      final status = (data['status'] as String?)?.trim().toLowerCase();
      if (status != 'pending' || data['awaitingSession'] != true) return false;
      final until = data['pendingUntil'];
      if (until is Timestamp && DateTime.now().isAfter(until.toDate())) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Resolves a session for replaying a [PendingSessionCodeEntry].
  ///
  /// Tries stored session id, local store by code, then server by code at capture time.
  Future<AttendanceSession?> resolveSessionForPendingCodeEntry({
    required String sessionCodeRaw,
    required DateTime capturedAt,
    String? sessionIdHint,
  }) async {
    final first = await _resolveSessionForPendingCodeEntryOnce(
      sessionCodeRaw: sessionCodeRaw,
      capturedAt: capturedAt,
      sessionIdHint: sessionIdHint,
    );
    if (first != null) return first;

    for (var attempt = 1; attempt < 3; attempt++) {
      await Future<void>.delayed(Duration(milliseconds: 150 * attempt));
      final session = await _resolveSessionForPendingCodeEntryOnce(
        sessionCodeRaw: sessionCodeRaw,
        capturedAt: capturedAt,
        sessionIdHint: sessionIdHint,
      );
      if (session != null) return session;
    }
    return null;
  }

  Future<AttendanceSession?> _resolveSessionForPendingCodeEntryOnce({
    required String sessionCodeRaw,
    required DateTime capturedAt,
    String? sessionIdHint,
  }) async {
    final hint = sessionIdHint?.trim();
    final normalizedCode = normalizeSessionCodeInput(sessionCodeRaw);
    if (hint != null && hint.isNotEmpty) {
      var session = AttendanceStore.sessionById(hint);
      session ??= (await _fetchSessionsByIds({hint}, force: true)).firstOrNull;
      if (session != null) {
        final i = AttendanceStore.sessions.indexWhere((s) => s.id == session!.id);
        if (i >= 0) {
          AttendanceStore.updateSession(session);
        } else {
          AttendanceStore.addSession(session);
        }
        if (normalizedCode.isEmpty ||
            normalizeSessionCodeInput(session.sessionCode) == normalizedCode) {
          return session;
        }
      }
    }

    var session = validateSessionCode(sessionCodeRaw);
    if (session != null &&
        isTimestampWithinSessionBounds(session, capturedAt)) {
      return session;
    }

    session = await resolveSessionByCodeAtTime(
      rawCode: sessionCodeRaw,
      capturedAt: capturedAt,
    );
    return session;
  }

  /// Warms the local store with server sessions referenced by pending codes.
  Future<void> prefetchSessionsForPendingCodes() async {
    if (!AppConnectivity.instance.hasNetworkInterface) return;
    final pending = await PendingSessionCodeQueue.loadAll();
    if (pending.isEmpty) return;
    final codes = pending
        .map((e) => normalizeSessionCodeInput(e.sessionCodeRaw))
        .where((c) => c.isNotEmpty)
        .toSet();
    for (final code in codes) {
      await resolveSessionByCode(code);
    }
  }

  /// Matches a session code to a live session and its attendance list.
  ///
  /// Checks local store first, then Firestore when online. Used before check-in
  /// and when replaying queued codes after a lecturer uploads an offline session.
  Future<({AttendanceSession? session, AttendanceList? list})>
      resolveSessionAndListForStudentCode(
    String rawCode, {
    DateTime? capturedAt,
  }) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) {
      return (session: null, list: null);
    }

    AttendanceSession? session;
    if (capturedAt != null) {
      session = await resolveSessionForPendingCodeEntry(
        sessionCodeRaw: rawCode,
        capturedAt: capturedAt,
      );
    } else {
      session = validateSessionCode(rawCode);
      if (session != null && session.isOpenForCheckIn) {
        final list = AttendanceStore.listById(session.listId);
        return (session: session, list: list);
      }
      final hasNet = AppConnectivity.instance.isOnline ||
          AppConnectivity.instance.hasNetworkInterface;
      if ((session == null || !session.isOpenForCheckIn) && hasNet) {
        if (!AppConnectivity.instance.isOnline) {
          await AppConnectivity.instance.ensureReachable(
            timeout: const Duration(seconds: 4),
          );
        }
        PendingSessionCodeSync.ensureWatchingSessionPublishForCodes([rawCode]);
        for (var attempt = 0; attempt < 3; attempt++) {
          if (attempt > 0) {
            await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
          }
          final found =
              await resolveActiveSessionByCodeForSignIn(rawCode);
          if (found != null) {
            session = found;
            break;
          }
        }
      }
    }

    if (session != null && !session.isOpenForCheckIn) {
      session = null;
    }

    if (session == null) return (session: null, list: null);

    var list = AttendanceStore.listById(session.listId);
    list ??= await resolveListById(session.listId);
    return (session: session, list: list);
  }

  Future<void> _ensureListLoaded(String listId) async {
    if (AttendanceStore.listById(listId) != null) return;
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.attendanceLists)
          .doc(listId)
          .get(_loadQueryOptions(force: true));
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
    var list = AttendanceStore.listById(listId);
    if (list != null || !AppConnectivity.instance.isOnline) return list;

    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(Duration(milliseconds: 300 * (i + 1)));
      await _ensureListLoaded(listId);
      list = AttendanceStore.listById(listId);
      if (list != null) return list;
    }
    return null;
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
  /// writes absent rows only after the 7-day verification window. Pending
  /// check-ins and offline-created sessions stay pending until then.
  Future<void> finalizeRollForSession(String sessionId) async {
    final session = AttendanceStore.sessionById(sessionId);
    if (session == null) return;

    final awaitingUpload = await _sessionIdsAwaitingUpload();
    if (awaitingUpload.contains(sessionId)) return;

    final pendingCheckInsEarly = await PendingCheckInQueue.loadAll();
    if (pendingCheckInsEarly.any((e) => e.sessionId == sessionId)) {
      return;
    }
    final pendingCodesEarly = await PendingSessionCodeQueue.loadAll();
    if (pendingCodesEarly.any(
      (e) =>
          e.sessionId == sessionId &&
          e.status != PendingSessionCodeStatus.invalidOrExpired,
    )) {
      return;
    }

    if (!rollGracePeriodExpired(session, DateTime.now())) return;

    final listId = session.listId;
    final studentIds =
        AttendanceStore.studentIdsForSessionRoll(listId, sessionId);

    final pendingCheckIns = await PendingCheckInQueue.loadAll();
    final pendingCodes = await PendingSessionCodeQueue.loadAll();

    final presentStudentIds = <String>{};
    for (final e in pendingCheckIns) {
      if (e.sessionId != sessionId) continue;
      if (pendingCheckInMatchesSession(e, session)) {
        presentStudentIds.add(e.studentId);
      }
    }
    for (final e in pendingCodes) {
      if (e.sessionId != sessionId) continue;
      if (e.status == PendingSessionCodeStatus.invalidOrExpired) continue;
      final student =
          AttendanceStore.findStudentByReg(e.registrationNumber);
      if (student == null) continue;
      if (isTimestampWithinSessionBounds(session, e.capturedAt) &&
          isPositionWithinSession(session, e.latitude, e.longitude)) {
        presentStudentIds.add(student.id);
      }
    }
    for (final r in AttendanceStore.attendanceRecords) {
      if (r.sessionId != sessionId) continue;
      if (r.present && r.verified) {
        presentStudentIds.add(r.studentId);
      } else if (r.present && !r.verified) {
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
      if (await hasAwaitingStudentClaimOnServer(
        sessionCodeRaw: session.sessionCode,
        studentId: studentId,
      )) {
        continue;
      }
      if (AttendanceStore.hasCheckedIn(sessionId, studentId)) {
        final existing =
            AttendanceStore.attendanceRecordForSessionStudent(sessionId, studentId);
        if (existing != null && !existing.present) continue;
      }
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
        verified: false,
        present: false,
        deviceId: null,
      );
      if (!AttendanceStore.addAttendanceRecordIfAbsent(record)) {
        final existing =
            AttendanceStore.attendanceRecordForSessionStudent(sessionId, studentId);
        if (existing != null &&
            !existing.present &&
            !existing.verified &&
            existing.latitude == 0 &&
            existing.longitude == 0) {
          AttendanceStore.updateAttendanceRecord(record);
          pending.add(record);
        }
        continue;
      }
      pending.add(record);
    }

    if (pending.isEmpty) return;
    // Absent rows are written server-side when the session is finalized.
    // Keep local absent rows only for offline roll display.
  }

  Future<_CheckInAttemptUploadResult> _trySubmitCheckInAttemptDetailed({
    required String sessionId,
    required String studentId,
    required String listId,
    required String course,
    required DateTime capturedAt,
    required double latitude,
    required double longitude,
    required String deviceId,
    String? sessionCodeRaw,
  }) async {
    if (deviceId.trim().isEmpty) {
      return _CheckInAttemptUploadResult.failed;
    }
    final docId = attendanceRecordIdForSessionStudent(sessionId, studentId);
    final uid = AuthRepository.instance.currentFirebaseUid?.trim();
    final timeout = AppConnectivity.instance.hasNetworkInterface
        ? _onlineFirestoreTimeout
        : _sessionPublishTimeout;
    final code = sessionCodeRaw?.trim();
    final student = _studentRecordForId(studentId);
    final reg = student?.registrationNumber.trim().toUpperCase();
    final studentName = student?.name.trim();
    try {
      await _firestore
          .collection(FirestoreCollections.checkInAttempts)
          .doc(docId)
          .set(
            <String, dynamic>{
              'sessionId': sessionId,
              'studentId': studentId,
              'listId': listId,
              'course': course,
              'capturedAt': Timestamp.fromDate(capturedAt),
              'latitude': latitude,
              'longitude': longitude,
              'deviceId': deviceId,
              'status': 'pending',
              if (reg != null && reg.isNotEmpty) 'registrationNumber': reg,
              if (studentName != null && studentName.isNotEmpty)
                'studentName': studentName,
              if (code != null && code.isNotEmpty) 'sessionCodeRaw': code,
              if (uid != null && uid.isNotEmpty) 'submittedByUid': uid,
              'clientSubmittedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          )
          .timeout(timeout);
      return _CheckInAttemptUploadResult.submitted;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        return _CheckInAttemptUploadResult.permissionDenied;
      }
      return _CheckInAttemptUploadResult.failed;
    } catch (_) {
      return _CheckInAttemptUploadResult.failed;
    }
  }

  /// Uploads check-in evidence for server reconciliation (not attendance_records).
  Future<bool> trySubmitCheckInAttempt({
    required String sessionId,
    required String studentId,
    required String listId,
    required String course,
    required DateTime capturedAt,
    required double latitude,
    required double longitude,
    required String deviceId,
    String? sessionCodeRaw,
  }) async {
    final result = await _trySubmitCheckInAttemptDetailed(
      sessionId: sessionId,
      studentId: studentId,
      listId: listId,
      course: course,
      capturedAt: capturedAt,
      latitude: latitude,
      longitude: longitude,
      deviceId: deviceId,
      sessionCodeRaw: sessionCodeRaw,
    );
    return result == _CheckInAttemptUploadResult.submitted;
  }

  /// Prevents absent backfill when a present row already exists remotely.
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

  /// Rejected check-in reasons keyed by session id (student profile detail).
  Future<Map<String, String>> fetchCheckInAttemptRejectionBySession({
    required String listId,
    required String studentId,
  }) async {
    final out = <String, String>{};
    try {
      final snap = await _firestore
          .collection(FirestoreCollections.checkInAttempts)
          .where('listId', isEqualTo: listId)
          .where('studentId', isEqualTo: studentId)
          .get()
          .timeout(_sessionPublishTimeout);
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['status'] != 'rejected') continue;
        final sessionId = (data['sessionId'] as String?)?.trim() ?? '';
        final reason = (data['rejectionReason'] as String?)?.trim() ?? '';
        if (sessionId.isNotEmpty && reason.isNotEmpty) {
          out[sessionId] = reason;
        }
      }
    } catch (_) {}
    return out;
  }

  static AttendanceRecord _recordWithVerified(
    AttendanceRecord r,
    bool verified,
  ) =>
      AttendanceRecord(
        id: r.id,
        sessionId: r.sessionId,
        studentId: r.studentId,
        course: r.course,
        timestamp: r.timestamp,
        latitude: r.latitude,
        longitude: r.longitude,
        verified: verified,
        present: r.present,
        deviceId: r.deviceId,
      );

  Future<bool> _hasMetadataEvidenceForSessionStudent({
    required AttendanceSession session,
    required String studentId,
    required String listId,
  }) async {
    final id = attendanceRecordIdForSessionStudent(session.id, studentId);
    if (await PendingCheckInQueue.containsRecordId(id)) return true;

    final studentReg = AttendanceStore.students
        .where((s) => s.id == studentId)
        .map((s) => s.registrationNumber.trim().toUpperCase())
        .firstOrNull;
    final regForMatch = studentReg ?? '';

    final pendingCheckIns = await PendingCheckInQueue.loadAll();
    for (final e in pendingCheckIns) {
      if (e.studentId != studentId) continue;
      if (e.sessionId == session.id &&
          (pendingCheckInMatchesSession(e, session) ||
              pendingCheckInMatchesSessionForCorrection(e, session))) {
        return true;
      }
    }

    final pendingCodes = await PendingSessionCodeQueue.loadAll();
    for (final e in pendingCodes) {
      if (pendingSessionCodeMatchesSession(
            entry: e,
            session: session,
            studentRegistrationNumber: regForMatch,
          ) ||
          pendingSessionCodeMatchesSessionForCorrection(
            entry: e,
            session: session,
            studentRegistrationNumber: regForMatch,
          )) {
        return true;
      }
    }

    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      session.id,
      studentId,
    );
    if (existing != null &&
        existing.present &&
        isTimestampWithinSessionBounds(session, existing.timestamp) &&
        positionQualifiesForPresentCorrection(
          session,
          existing.latitude,
          existing.longitude,
        )) {
      return true;
    }

    return (await _serverAttemptMatchesSessionForStudent(
          listId: listId,
          session: session,
          studentId: studentId,
        )) !=
        null;
  }

  Future<bool> _shouldRetainLocalPresentOverOfficialAbsent({
    required String sessionId,
    required String studentId,
    required AttendanceRecord? existing,
  }) async {
    if (existing == null || !existing.present) return false;
    final id = attendanceRecordIdForSessionStudent(sessionId, studentId);
    if (await PendingCheckInQueue.containsRecordId(id)) return true;
    final session = AttendanceStore.sessionById(sessionId);
    if (session == null) return false;
    if (!existing.verified &&
        isValidCheckInCoordinates(existing.latitude, existing.longitude) &&
        isTimestampWithinSessionBounds(session, existing.timestamp)) {
      return true;
    }
    return _hasMetadataEvidenceForSessionStudent(
      session: session,
      studentId: studentId,
      listId: session.listId,
    );
  }

  void _stopAllCheckInAttemptWatches() {
    for (final sub in _checkInAttemptWatchSubs.values) {
      unawaited(sub.cancel());
    }
    _checkInAttemptWatchSubs.clear();
  }

  /// Merges official rows as soon as Cloud Functions accept the attempt.
  void watchCheckInAttemptForStudent({
    required String recordId,
    required String sessionId,
    required String studentId,
  }) {
    if (_firestoreIfReady == null) return;
    unawaited(_checkInAttemptWatchSubs.remove(recordId)?.cancel());
    _checkInAttemptWatchSubs[recordId] = _firestore
        .collection(FirestoreCollections.checkInAttempts)
        .doc(recordId)
        .snapshots()
        .listen(
      (snap) async {
        if (!snap.exists) return;
        final status =
            (snap.data()?['status'] as String?)?.trim().toLowerCase() ?? '';
        if (status == 'accepted') {
          await PendingCheckInQueue.removeById(recordId);
          _promoteLocalPresentToVerified(sessionId, studentId);
          unawaited(
            refreshOfficialRecordFromFirebase(
              sessionId: sessionId,
              studentId: studentId,
            ),
          );
          await _checkInAttemptWatchSubs.remove(recordId)?.cancel();
        } else if (status == 'rejected') {
          await PendingCheckInQueue.removeById(recordId);
          await clearLocalUnverifiedPresentForCheckIn(recordId, force: true);
          await _checkInAttemptWatchSubs.remove(recordId)?.cancel();
        }
      },
      onError: (_) {},
    );
  }

  /// Refreshes only this student's rows on [listId] (no full [loadAll]).
  Future<void> refreshStudentAttendanceRecordsForList(
    String listId,
    String studentId,
  ) async {
    if (!AppConnectivity.instance.hasNetworkInterface) return;
    final sessions = AttendanceStore.sessionsForListNewestFirst(listId);
    if (sessions.isEmpty) {
      unawaited(loadListAttendanceData(listId));
      return;
    }
    await Future.wait(
      sessions.map(
        (s) => refreshOfficialRecordFromFirebase(
          sessionId: s.id,
          studentId: studentId,
        ),
      ),
    );
    _notifyStoreUpdated();
  }

  /// Fast poll after upload — promotes on accepted attempt without blocking UI.
  Future<bool> quickVerifyStudentCheckIn({
    required String sessionId,
    required String studentId,
  }) =>
      _tryQuickVerifyAfterCheckInUpload(
        sessionId: sessionId,
        studentId: studentId,
        recordId: attendanceRecordIdForSessionStudent(sessionId, studentId),
      );

  Future<bool> _tryQuickVerifyAfterCheckInUpload({
    required String sessionId,
    required String studentId,
    required String recordId,
  }) async {
    const fastDelaysMs = [40, 80, 120, 180, 250, 350, 500, 700];
    for (var i = 0; i < fastDelaysMs.length; i++) {
      if (await _isCheckInAttemptAccepted(recordId)) {
        _promoteLocalPresentToVerified(sessionId, studentId);
        unawaited(
          refreshOfficialRecordFromFirebase(
            sessionId: sessionId,
            studentId: studentId,
          ),
        );
        return true;
      }
      final result = await refreshOfficialRecordFromFirebase(
        sessionId: sessionId,
        studentId: studentId,
      );
      if (result == OfficialRecordRefreshResult.verifiedPresent) {
        return true;
      }
      if (await isCheckInAttemptRejected(recordId)) {
        return false;
      }
      await Future<void>.delayed(Duration(milliseconds: fastDelaysMs[i]));
    }
    unawaited(
      _continueVerifyInBackground(
        sessionId: sessionId,
        studentId: studentId,
        recordId: recordId,
      ),
    );
    return false;
  }

  Future<void> _continueVerifyInBackground({
    required String sessionId,
    required String studentId,
    required String recordId,
  }) async {
    final verified = await awaitOfficialRecordFromFirebase(
      sessionId: sessionId,
      studentId: studentId,
      timeout: const Duration(seconds: 15),
    );
    if (verified) return;
    if (!await PendingCheckInQueue.containsRecordId(recordId) &&
        await _isCheckInAttemptAccepted(recordId)) {
      _promoteLocalPresentToVerified(sessionId, studentId);
      unawaited(_persistScopedLocalSnapshot());
    }
  }

  Future<void> _uploadPendingMetadataEvidenceForStudent({
    required String listId,
    required String studentId,
  }) async {
    if (!AppConnectivity.instance.hasNetworkInterface) return;
    final student = AttendanceStore.students
        .where((s) => s.id == studentId)
        .firstOrNull;
    if (student == null) return;
    final reg = student.registrationNumber.trim().toUpperCase();

    for (final e in await PendingSessionCodeQueue.loadAll()) {
      if (e.registrationNumber.trim().toUpperCase() != reg) continue;
      await PendingSessionCodeClaimUpload.uploadForEntryWithStudent(
        entry: e,
        studentId: studentId,
      );
    }
    await PendingSessionCodeSync.drainUrgent();

    final course = AttendanceStore.courseForStudentOnList(listId, studentId)
            .trim()
            .isNotEmpty
        ? AttendanceStore.courseForStudentOnList(listId, studentId)
        : (AttendanceStore.listById(listId)?.coursesSafe.firstOrNull ?? '—');
    for (final e in await PendingCheckInQueue.loadAll()) {
      if (e.studentId != studentId) continue;
      await trySubmitCheckInAttempt(
        sessionId: e.sessionId,
        studentId: studentId,
        listId: e.listId.isNotEmpty ? e.listId : listId,
        course: e.course.trim().isNotEmpty ? e.course : course,
        capturedAt: e.capturedAt,
        latitude: e.latitude,
        longitude: e.longitude,
        deviceId: e.deviceId,
      );
    }
  }

  /// Merges one official row from Firestore (realtime listener or poll).
  Future<void> applyRemoteAttendanceRecord(AttendanceRecord official) async {
    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      official.sessionId,
      official.studentId,
    );

    if (official.present && official.verified) {
      if (existing != null) {
        AttendanceStore.updateAttendanceRecord(official);
      } else {
        AttendanceStore.addAttendanceRecord(official);
      }
      await PendingCheckInQueue.removeById(official.id);
      AttendanceStore.invalidateLookupCaches();
      unawaited(_persistScopedLocalSnapshot());
      _notifyStoreUpdated();
      return;
    }

    final queued = await PendingCheckInQueue.containsRecordId(official.id);
    final retainLocalPresent = !official.present &&
        await _shouldRetainLocalPresentOverOfficialAbsent(
          sessionId: official.sessionId,
          studentId: official.studentId,
          existing: existing,
        );
    if (!official.present && (queued || retainLocalPresent)) {
      return;
    }
    if (existing != null) {
      if (!official.present &&
          existing.present &&
          !existing.verified &&
          (queued || retainLocalPresent)) {
        return;
      }
      AttendanceStore.updateAttendanceRecord(official);
    } else {
      AttendanceStore.addAttendanceRecord(official);
    }
    if (official.present && official.verified) {
      await PendingCheckInQueue.removeById(official.id);
    }
    AttendanceStore.invalidateLookupCaches();
    unawaited(_persistScopedLocalSnapshot());
    _notifyStoreUpdated();
  }

  Future<bool> _isCheckInAttemptAccepted(String recordId) async {
    if (_firestoreIfReady == null) return false;
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.checkInAttempts)
          .doc(recordId)
          .get()
          .timeout(_sessionPublishTimeout);
      if (!doc.exists) return false;
      return (doc.data()?['status'] as String?)?.trim() == 'accepted';
    } catch (_) {
      return false;
    }
  }

  void _promoteLocalPresentToVerified(String sessionId, String studentId) {
    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      sessionId,
      studentId,
    );
    if (existing == null || !existing.present || existing.verified) return;
    AttendanceStore.updateAttendanceRecord(
      _recordWithVerified(existing, true),
    );
    AttendanceStore.invalidateLookupCaches();
    _notifyStoreUpdated();
  }

  /// After a successful check-in, keeps polling until the official row lands and
  /// refreshes list detail / student stats for immediate UI updates.
  Future<void> notifyAttendanceAfterCheckIn({
    required String sessionId,
    required String studentId,
    String? listId,
  }) async {
    final recordId = attendanceRecordIdForSessionStudent(sessionId, studentId);
    watchCheckInAttemptForStudent(
      recordId: recordId,
      sessionId: sessionId,
      studentId: studentId,
    );
    final trimmedListId = listId?.trim() ?? '';
    unawaited(() async {
      final row = AttendanceStore.attendanceRecordForSessionStudent(
        sessionId,
        studentId,
      );
      if (row?.verified != true) {
        await _continueVerifyInBackground(
          sessionId: sessionId,
          studentId: studentId,
          recordId: recordId,
        );
      }
      if (trimmedListId.isNotEmpty) {
        await refreshStudentAttendanceRecordsForList(
          trimmedListId,
          studentId,
        );
      }
    }());
  }

  /// Pulls one official row from Firebase into [AttendanceStore].
  Future<OfficialRecordRefreshResult> refreshOfficialRecordFromFirebase({
    required String sessionId,
    required String studentId,
  }) async {
    final id = attendanceRecordIdForSessionStudent(sessionId, studentId);
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.attendanceRecords)
          .doc(id)
          .get()
          .timeout(_sessionPublishTimeout);
      if (!doc.exists) {
        if (await _isCheckInAttemptAccepted(id)) {
          _promoteLocalPresentToVerified(sessionId, studentId);
          final promoted = AttendanceStore.attendanceRecordForSessionStudent(
            sessionId,
            studentId,
          );
          if (promoted != null && promoted.present && promoted.verified) {
            return OfficialRecordRefreshResult.verifiedPresent;
          }
        }
        return OfficialRecordRefreshResult.notFound;
      }
      final official = _recordFromDoc(doc);
      await applyRemoteAttendanceRecord(official);
      if (official.present && official.verified) {
        return OfficialRecordRefreshResult.verifiedPresent;
      }
      if (!official.present) {
        final existing = AttendanceStore.attendanceRecordForSessionStudent(
          sessionId,
          studentId,
        );
        final retainLocalPresent =
            await _shouldRetainLocalPresentOverOfficialAbsent(
          sessionId: sessionId,
          studentId: studentId,
          existing: existing,
        );
        if (!retainLocalPresent) {
          await clearLocalUnverifiedPresentForCheckIn(id);
        }
        return OfficialRecordRefreshResult.officialAbsent;
      }
      return OfficialRecordRefreshResult.notFound;
    } catch (_) {
      return OfficialRecordRefreshResult.notFound;
    }
  }

  /// Polls Firebase until the official row appears, is rejected, or [timeout] elapses.
  Future<bool> awaitOfficialRecordFromFirebase({
    required String sessionId,
    required String studentId,
    Duration? timeout,
  }) async {
    final online = AppConnectivity.instance.isOnline;
    final effectiveTimeout = timeout ??
        (online ? const Duration(seconds: 8) : const Duration(seconds: 12));
    final id = attendanceRecordIdForSessionStudent(sessionId, studentId);
    final deadline = DateTime.now().add(effectiveTimeout);
    var pollIndex = 0;
    const pollScheduleMs = [100, 150, 200, 300, 400, 500, 600, 800];

    Future<OfficialRecordRefreshResult> pollOnce() async {
      if (await _isCheckInAttemptAccepted(id)) {
        _promoteLocalPresentToVerified(sessionId, studentId);
      }
      return refreshOfficialRecordFromFirebase(
        sessionId: sessionId,
        studentId: studentId,
      );
    }

    var result = await pollOnce();
    if (result == OfficialRecordRefreshResult.verifiedPresent) {
      return true;
    }
    if (result == OfficialRecordRefreshResult.officialAbsent) {
      final retain = await _shouldRetainLocalPresentOverOfficialAbsent(
        sessionId: sessionId,
        studentId: studentId,
        existing: AttendanceStore.attendanceRecordForSessionStudent(
          sessionId,
          studentId,
        ),
      );
      if (!retain && !await PendingCheckInQueue.containsRecordId(id)) {
        await PendingCheckInQueue.removeById(id);
        return false;
      }
      if (retain) {
        // Server may still be upgrading absent → present; keep polling.
      }
    }
    if (await isCheckInAttemptRejected(id)) {
      await refreshOfficialRecordFromFirebase(
        sessionId: sessionId,
        studentId: studentId,
      );
      await PendingCheckInQueue.removeById(id);
      await clearLocalUnverifiedPresentForCheckIn(id, force: true);
      return false;
    }
    while (DateTime.now().isBefore(deadline)) {
      final delayMs = pollScheduleMs[
          pollIndex < pollScheduleMs.length
              ? pollIndex
              : pollScheduleMs.length - 1];
      pollIndex++;
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (!DateTime.now().isBefore(deadline)) break;

      result = await pollOnce();
      if (result == OfficialRecordRefreshResult.verifiedPresent) {
        return true;
      }
      if (result == OfficialRecordRefreshResult.officialAbsent) {
        final retain = await _shouldRetainLocalPresentOverOfficialAbsent(
          sessionId: sessionId,
          studentId: studentId,
          existing: AttendanceStore.attendanceRecordForSessionStudent(
            sessionId,
            studentId,
          ),
        );
        if (!retain && !await PendingCheckInQueue.containsRecordId(id)) {
          await PendingCheckInQueue.removeById(id);
          return false;
        }
      }
      if (await isCheckInAttemptRejected(id)) {
        await refreshOfficialRecordFromFirebase(
          sessionId: sessionId,
          studentId: studentId,
        );
        await PendingCheckInQueue.removeById(id);
        await clearLocalUnverifiedPresentForCheckIn(id, force: true);
        return false;
      }
    }
    return AttendanceStore.attendanceRecordForSessionStudent(sessionId, studentId)
            ?.verified ==
        true;
  }

  /// Present check-in: [checkInAttempts] upload, then local pending row. Official
  /// [attendanceRecords] rows are written by Cloud Functions; this method then
  /// refreshes the local store from Firebase when possible.
  Future<StudentOfflineCheckInOutcome> submitStudentCheckInWithOfflineSupport(
    AttendanceRecord record, {
    String? listIdOverride,
    String? sessionCodeRaw,
  }) async {
    if (record.present) {
      final d = record.deviceId?.trim() ?? '';
      if (d.isNotEmpty &&
          await _isCheckInDeviceBlocked(
            sessionId: record.sessionId,
            studentId: record.studentId,
            deviceId: d,
            sessionCodeRaw: sessionCodeRaw,
          )) {
        return StudentOfflineCheckInOutcome.deviceBlocked;
      }
    }
    if (await _remoteRecordIsPresent(record.id)) {
      return StudentOfflineCheckInOutcome.duplicate;
    }
    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      record.sessionId,
      record.studentId,
    );
    if (existing != null) {
      if (existing.present && existing.verified) {
        return StudentOfflineCheckInOutcome.duplicate;
      }
    }

    final resolvedCourse = _resolvePresentCourseForSession(
      record.sessionId,
      record.studentId,
      record.course,
    );
    final localRow = _recordWithVerified(
      AttendanceRecord(
        id: record.id,
        sessionId: record.sessionId,
        studentId: record.studentId,
        course: resolvedCourse,
        timestamp: record.timestamp,
        latitude: record.latitude,
        longitude: record.longitude,
        verified: false,
        present: true,
        deviceId: record.deviceId,
      ),
      false,
    );

    if (record.present &&
        !await isLecturerSessionPublishedOnServer(record.sessionId)) {
      final student = AttendanceStore.studentMapById()[record.studentId];
      final session = AttendanceStore.sessionById(record.sessionId);
      if (student != null && session != null) {
        final d = record.deviceId?.trim() ?? '';
        if (d.isNotEmpty &&
            await _isCheckInDeviceBlocked(
              sessionId: record.sessionId,
              studentId: record.studentId,
              deviceId: d,
              sessionCodeRaw: session.sessionCode,
            )) {
          return StudentOfflineCheckInOutcome.deviceBlocked;
        }
        final claimEntry = PendingSessionCodeEntry(
          id:
              '${normalizeSessionCodeInput(session.sessionCode)}_${student.registrationNumber.trim().toUpperCase()}',
          registrationNumber: student.registrationNumber,
          sessionCodeRaw: session.sessionCode,
          capturedAt: record.timestamp,
          latitude: record.latitude,
          longitude: record.longitude,
          deviceId: d,
        );
        final claimUploaded =
            await PendingSessionCodeClaimUpload.uploadForEntryWithStudent(
          entry: claimEntry,
          studentId: record.studentId,
        );
        PendingSessionCodeSync.ensureWatchingSessionPublishForCodes(
          [session.sessionCode],
        );
        if (claimUploaded) {
          _applyLocalPresentCheckInRow(
            localRow,
            existing: existing,
            sessionId: record.sessionId,
            studentId: record.studentId,
          );
          return StudentOfflineCheckInOutcome.submittedPendingVerification;
        }
        _applyLocalPresentCheckInRow(
          localRow,
          existing: existing,
          sessionId: record.sessionId,
          studentId: record.studentId,
        );
        return StudentOfflineCheckInOutcome.queuedOffline;
      }
    }

    final session = AttendanceStore.sessionById(record.sessionId);
    final listId = (listIdOverride?.trim().isNotEmpty == true
            ? listIdOverride!.trim()
            : null) ??
        session?.listId ??
        '';
    final codeForAttempt = (sessionCodeRaw?.trim().isNotEmpty == true
            ? normalizeSessionCodeInput(sessionCodeRaw!.trim())
            : null) ??
        (session != null
            ? normalizeSessionCodeInput(session.sessionCode)
            : null);
    if (record.present) {
      final d = record.deviceId?.trim() ?? '';
      if (d.isNotEmpty &&
          await _isCheckInDeviceBlocked(
            sessionId: record.sessionId,
            studentId: record.studentId,
            deviceId: d,
            sessionCodeRaw: codeForAttempt,
          )) {
        return StudentOfflineCheckInOutcome.deviceBlocked;
      }
    }
    var uploadResult = await _trySubmitCheckInAttemptDetailed(
      sessionId: record.sessionId,
      studentId: record.studentId,
      listId: listId,
      course: resolvedCourse,
      capturedAt: record.timestamp,
      latitude: record.latitude,
      longitude: record.longitude,
      deviceId: record.deviceId?.trim() ?? '',
      sessionCodeRaw: codeForAttempt,
    );
    var submitted = uploadResult == _CheckInAttemptUploadResult.submitted;
    var permissionDenied =
        uploadResult == _CheckInAttemptUploadResult.permissionDenied;
    if (!submitted &&
        !permissionDenied &&
        AppConnectivity.instance.hasNetworkInterface) {
      for (var i = 0; i < 2 && !submitted && !permissionDenied; i++) {
        await Future<void>.delayed(Duration(milliseconds: 300 * (i + 1)));
        uploadResult = await _trySubmitCheckInAttemptDetailed(
          sessionId: record.sessionId,
          studentId: record.studentId,
          listId: listId,
          course: resolvedCourse,
          capturedAt: record.timestamp,
          latitude: record.latitude,
          longitude: record.longitude,
          deviceId: record.deviceId?.trim() ?? '',
          sessionCodeRaw: codeForAttempt,
        );
        submitted = uploadResult == _CheckInAttemptUploadResult.submitted;
        permissionDenied =
            uploadResult == _CheckInAttemptUploadResult.permissionDenied;
      }
    }
    if (!submitted &&
        !permissionDenied &&
        AppConnectivity.instance.hasNetworkInterface) {
      await AppConnectivity.instance.ensureReachable(
        timeout: const Duration(seconds: 2),
      );
      uploadResult = await _trySubmitCheckInAttemptDetailed(
        sessionId: record.sessionId,
        studentId: record.studentId,
        listId: listId,
        course: resolvedCourse,
        capturedAt: record.timestamp,
        latitude: record.latitude,
        longitude: record.longitude,
        deviceId: record.deviceId?.trim() ?? '',
        sessionCodeRaw: codeForAttempt,
      );
      submitted = uploadResult == _CheckInAttemptUploadResult.submitted;
      permissionDenied =
          uploadResult == _CheckInAttemptUploadResult.permissionDenied;
    }
    if (permissionDenied) {
      await PendingCheckInQueue.removeById(record.id);
      await clearLocalUnverifiedPresentForCheckIn(record.id, force: true);
      final dev = record.deviceId?.trim() ?? '';
      if (dev.isNotEmpty &&
          await _isCheckInDeviceBlocked(
            sessionId: record.sessionId,
            studentId: record.studentId,
            deviceId: dev,
            sessionCodeRaw: codeForAttempt,
          )) {
        return StudentOfflineCheckInOutcome.deviceBlocked;
      }
      return StudentOfflineCheckInOutcome.rejectedVerification;
    }
    if (submitted) {
      _applyLocalPresentCheckInRow(
        localRow,
        existing: existing,
        sessionId: record.sessionId,
        studentId: record.studentId,
      );
      await PendingCheckInQueue.removeById(record.id);
      final verified = await _tryQuickVerifyAfterCheckInUpload(
        sessionId: record.sessionId,
        studentId: record.studentId,
        recordId: record.id,
      );
      _notifyStoreUpdated();
      unawaited(
        notifyAttendanceAfterCheckIn(
          sessionId: record.sessionId,
          studentId: record.studentId,
          listId: listId,
        ),
      );
      if (verified) {
        return StudentOfflineCheckInOutcome.success;
      }
      final official = AttendanceStore.attendanceRecordForSessionStudent(
        record.sessionId,
        record.studentId,
      );
      if (official != null && !official.present) {
        return StudentOfflineCheckInOutcome.sessionMismatch;
      }
      if (await isCheckInAttemptRejected(record.id)) {
        return _outcomeForRejectedAttempt(
          record.id,
          sessionId: record.sessionId,
          studentId: record.studentId,
          deviceId: record.deviceId,
          sessionCodeRaw: codeForAttempt,
        );
      }
      return StudentOfflineCheckInOutcome.submittedPendingVerification;
    }

    _applyLocalPresentCheckInRow(
      localRow,
      existing: existing,
      sessionId: record.sessionId,
      studentId: record.studentId,
    );
    await PendingCheckInQueue.enqueue(
      PendingCheckInEntry(
        id: localRow.id,
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

  /// Persists a new session check-in locally. Official Firestore rows are
  /// server-written only. Returns `false` on duplicate guard.
  Future<bool> submitAttendanceRecord(AttendanceRecord record) async {
    if (record.present) {
      final d = record.deviceId?.trim() ?? '';
      if (d.isNotEmpty &&
          (AttendanceStore.hasPresentCheckInForDevice(
                record.sessionId,
                d,
                record.studentId,
              ) ||
              await isDeviceBlockedForStudentSession(
                sessionId: record.sessionId,
                studentId: record.studentId,
                deviceId: d,
                sessionCodeRaw:
                    AttendanceStore.sessionById(record.sessionId)?.sessionCode,
              ))) {
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
          verified: record.verified,
          present: true,
          deviceId: record.deviceId,
        );
        AttendanceStore.updateAttendanceRecord(upgraded);
        return true;
      }
      if (!existing.present && !record.present) {
        AttendanceStore.updateAttendanceRecord(
          AttendanceRecord(
            id: existing.id,
            sessionId: existing.sessionId,
            studentId: existing.studentId,
            course: existing.course.trim().isNotEmpty
                ? existing.course
                : record.course,
            timestamp: existing.timestamp,
            latitude: isValidCheckInCoordinates(
                    existing.latitude, existing.longitude)
                ? existing.latitude
                : record.latitude,
            longitude: isValidCheckInCoordinates(
                    existing.latitude, existing.longitude)
                ? existing.longitude
                : record.longitude,
            verified: false,
            present: false,
            deviceId: existing.deviceId ?? record.deviceId,
          ),
        );
        return true;
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
            verified: record.verified,
            present: record.present,
            deviceId: record.deviceId,
          )
        : record;
    if (!AttendanceStore.addAttendanceRecordIfAbsent(toPersist)) {
      return false;
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
        verified: verified,
        present: r.present,
        deviceId: r.deviceId,
      ));
    }
  }

  Future<void> _purgeListLocally(String listId) async {
    final trimmed = listId.trim();
    if (trimmed.isEmpty) return;
    await AttendanceListPurge.purgeLocalDataForList(trimmed);
    _loadedListDetailIds.remove(trimmed);
  }

  /// Deletes sessions, sign-ins, and notices while the list doc still exists
  /// (security rules require it). [attendance_records] and [check_in_attempts]
  /// are server-only; `onAttendanceListDeleted` removes those via Admin SDK.
  Future<void> _cascadeDeleteListDocsClient(String listId) async {
    final trimmed = listId.trim();
    if (trimmed.isEmpty) return;

    final sessionDocs = await _queryDocsWhereFieldEquals(
      collection: _firestore.collection(FirestoreCollections.attendanceSessions),
      field: 'listId',
      values: [trimmed],
    );
    final sessionIds = sessionDocs
        .map((d) => d.id)
        .where((id) => id.trim().isNotEmpty)
        .toList();

    final signInDocs = await _queryDocsWhereFieldEquals(
      collection: _firestore.collection(FirestoreCollections.signIns),
      field: 'listId',
      values: [trimmed],
    );

    final noticesCol = _firestore.collection(FirestoreCollections.notices);
    final noticeByList = await _queryDocsWhereFieldEquals(
      collection: noticesCol,
      field: 'targetListId',
      values: [trimmed],
    );
    final noticeRefs = <String, DocumentReference<Map<String, dynamic>>>{
      for (final d in noticeByList) d.reference.path: d.reference,
    };
    for (final sid in sessionIds) {
      final noticeBySession = await _queryDocsWhereFieldEquals(
        collection: noticesCol,
        field: 'sessionId',
        values: [sid],
      );
      for (final d in noticeBySession) {
        noticeRefs[d.reference.path] = d.reference;
      }
    }

    await _deleteFirestoreRefsInBatches(
      sessionDocs.map((d) => d.reference),
    );
    await _deleteFirestoreRefsInBatches(
      signInDocs.map((d) => d.reference),
    );
    await _deleteFirestoreRefsInBatches(noticeRefs.values);
  }

  Future<void> _deleteFirestoreRefsInBatches(
    Iterable<DocumentReference<Map<String, dynamic>>> refs,
  ) async {
    final list = refs.toList();
    if (list.isEmpty) return;
    const batchSize = 400;
    for (var i = 0; i < list.length; i += batchSize) {
      final batch = _firestore.batch();
      for (final ref in list.skip(i).take(batchSize)) {
        batch.delete(ref);
      }
      try {
        await batch.commit();
      } catch (_) {}
    }
  }

  Future<void> removeList(String id) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return;
    await _purgeListLocally(trimmed);
    try {
      await _cascadeDeleteListDocsClient(trimmed);
    } catch (_) {}
    try {
      await _firestore
          .collection(FirestoreCollections.attendanceLists)
          .doc(trimmed)
          .delete();
    } catch (_) {}
    unawaited(PushController.instance.syncListTopicsFromStore());
    unawaited(_persistScopedLocalSnapshot());
    _notifyStoreUpdated();
  }

  Future<String?> _fullNameFromStudentRegistration(String reg) async {
    final normalized = StudentRegistrationNumber.normalize(reg);
    if (normalized.isEmpty) return null;
    try {
      final snap = await _firestore
          .collection(FirestoreCollections.studentRegistrations)
          .doc(normalized)
          .get();
      if (!snap.exists || snap.data() == null) return null;
      final data = snap.data()!;
      final ownerUid = (data['uid'] as String?)?.trim() ?? '';
      final currentUid =
          AuthRepository.instance.currentFirebaseUid?.trim() ?? '';
      if (ownerUid.isNotEmpty &&
          currentUid.isNotEmpty &&
          ownerUid != currentUid) {
        return null;
      }
      final name = (data['fullName'] as String?)?.trim();
      if (name != null && name.isNotEmpty) return name;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Resolves the signed-in student's registered full name for [reg].
  Future<String?> _resolveRegisteredFullNameForReg(String reg) async {
    final normalized = StudentRegistrationNumber.normalize(reg);
    if (normalized.isEmpty) return null;

    final cached = AuthRepository.instance.currentFullName?.trim();
    if (cached != null && cached.isNotEmpty) {
      final profileReg = StudentRegistrationNumber.normalize(
        AuthRepository.instance.currentRegistrationNumber?.trim() ?? '',
      );
      if (profileReg.isEmpty || profileReg == normalized) {
        return cached;
      }
    }

    final profile = await AuthRepository.instance.profileForCurrentUser();
    if (profile != null) {
      final profileReg = StudentRegistrationNumber.normalize(
        profile['registrationNumber']?.trim() ?? '',
      );
      final profileName = profile['fullName']?.trim();
      if (profileName != null &&
          profileName.isNotEmpty &&
          (profileReg.isEmpty || profileReg == normalized)) {
        return profileName;
      }
    }

    final fromReg = await _fullNameFromStudentRegistration(normalized);
    if (fromReg != null && fromReg.isNotEmpty) return fromReg;

    final displayName = FirebaseAuth.instance.currentUser?.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;

    return null;
  }

  void _reconcileLegacyStudentIdsInStore() {
    for (final student in List<StudentRecord>.from(AttendanceStore.students)) {
      final reg = student.registrationNumber.trim().toUpperCase();
      if (!StudentRegistrationNumber.isCanonicalFormat(reg)) continue;
      if (student.id == reg) continue;
      if (StudentRegistrationNumber.isCanonicalFormat(student.id)) continue;
      _reconcileStudentIdToRegistration(student);
    }
  }

  StudentRecord _reconcileStudentIdToRegistration(StudentRecord student) {
    final reg = student.registrationNumber.trim().toUpperCase();
    if (reg.isEmpty || student.id == reg) return student;
    final reconciled = StudentRecord(
      id: reg,
      name: student.name,
      registrationNumber: reg,
      threeDigitCode: student.threeDigitCode,
      initials: student.initials,
    );
    AttendanceStore.upsertStudent(reconciled);
    for (var i = 0; i < AttendanceStore.signIns.length; i++) {
      final si = AttendanceStore.signIns[i];
      if (si.studentId == student.id) {
        AttendanceStore.signIns[i] = si.copyWith(studentId: reg);
      }
    }
    for (final r in List<AttendanceRecord>.from(AttendanceStore.attendanceRecords)) {
      if (r.studentId != student.id) continue;
      final newId = attendanceRecordIdForSessionStudent(r.sessionId, reg);
      if (r.id == newId && r.studentId == reg) continue;
      AttendanceStore.removeAttendanceRecordById(r.id);
      AttendanceStore.addAttendanceRecordIfAbsent(
        AttendanceRecord(
          id: newId,
          sessionId: r.sessionId,
          studentId: reg,
          course: r.course,
          timestamp: r.timestamp,
          latitude: r.latitude,
          longitude: r.longitude,
          verified: r.verified,
          present: r.present,
          deviceId: r.deviceId,
        ),
      );
    }
    return reconciled;
  }

  Future<StudentRecord> registerStudent(
    String name,
    String registrationNumber,
    String initials,
  ) async {
    final normalized = StudentRegistrationNumber.normalize(registrationNumber);
    final trimmedName = name.trim();
    final trimmedIni = normalizeSessionCodeInput(initials);
    var existing = AttendanceStore.findStudentByReg(normalized);
    if (existing != null) {
      existing = _reconcileStudentIdToRegistration(existing);
      final upgraded = _upgradeStudentIfNeeded(
        existing,
        trimmedName,
        trimmedIni,
      );
      await _persistStudentRecord(upgraded, awaitWhenOnline: true);
      return upgraded;
    }
    final record = AttendanceStore.registerStudent(
      trimmedName,
      normalized,
      trimmedIni,
    );
    await _persistStudentRecord(record, awaitWhenOnline: true);
    await _bindDeviceRegistrationIfNeeded(normalized);
    return record;
  }

  /// Creates a roster row using the signed-in user's registered full name.
  Future<StudentRecord?> registerStudentFromAuthProfile(
    String registrationNumber,
  ) async {
    final requestedReg = StudentRegistrationNumber.normalize(registrationNumber);
    if (requestedReg.isEmpty) return null;
    final profileReg = StudentRegistrationNumber.normalize(
      AuthRepository.instance.currentRegistrationNumber?.trim() ?? '',
    );
    if (profileReg.isNotEmpty && requestedReg != profileReg) {
      return AttendanceStore.findStudentByReg(profileReg);
    }
    final effectiveReg = profileReg.isNotEmpty ? profileReg : requestedReg;
    final existing = AttendanceStore.findStudentByReg(effectiveReg);
    final name = await _resolveRegisteredFullNameForReg(effectiveReg);
    if (existing != null) {
      var reconciled = _reconcileStudentIdToRegistration(existing);
      if (name != null && name.isNotEmpty) {
        reconciled = _upgradeStudentIfNeeded(
          reconciled,
          name,
          initialsFromFullName(name),
        );
        await _persistStudentRecord(reconciled, awaitWhenOnline: true);
        return reconciled;
      }
      await _persistStudentRecord(reconciled, awaitWhenOnline: true);
      return reconciled;
    }
    if (name == null || name.isEmpty) return null;
    return registerStudent(
      name,
      effectiveReg,
      initialsFromFullName(name),
    );
  }

  SignInRecord _signInWithStudentMetadata(
    SignInRecord record,
    StudentRecord? student,
  ) {
    if (student == null) return record;
    final name = student.name.trim();
    final reg = student.registrationNumber.trim().toUpperCase();
    return record.copyWith(
      studentName: name.isNotEmpty ? name : record.studentName,
      registrationNumber: reg.isNotEmpty ? reg : record.registrationNumber,
    );
  }

  Future<void> addSignIn(String listId, String studentId, String course) async {
    var student = _studentRecordForId(studentId);
    if (student != null) {
      if (student.name.trim().isEmpty || student.name.trim() == 'Unknown') {
        final reg = student.registrationNumber.trim();
        if (reg.isNotEmpty) {
          final resolved = await _resolveRegisteredFullNameForReg(reg);
          if (resolved != null && resolved.isNotEmpty) {
            student = _upgradeStudentIfNeeded(
              student,
              resolved,
              initialsFromFullName(resolved),
            );
          }
        }
      }
      await _persistStudentRecord(student, awaitWhenOnline: true);
    }

    if (AttendanceStore.hasSignedIn(listId, studentId, course)) {
      final existing = AttendanceStore.signIns.firstWhere(
        (r) =>
            r.listId == listId &&
            r.studentId == studentId &&
            r.course == course,
      );
      final enriched = _signInWithStudentMetadata(existing, student);
      if (enriched.studentName != existing.studentName ||
          enriched.registrationNumber != existing.registrationNumber) {
        final idx = AttendanceStore.signIns.indexOf(existing);
        if (idx >= 0) AttendanceStore.signIns[idx] = enriched;
      }
      await _tryUploadSignInRecord(enriched);
      return;
    }
    final record = _signInWithStudentMetadata(
      SignInRecord(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        listId: listId,
        studentId: studentId,
        course: course,
        signedInAt: DateTime.now(),
      ),
      student,
    );
    AttendanceStore.addSignInRecord(record);
    _notifyStoreUpdated();
    await _tryUploadSignInRecord(record);
    if (isStudentScopedUser() || _normalizedStudentRegistrationForCache() != null) {
      if (AppConnectivity.instance.isOnline) {
        await loadListAttendanceData(listId);
      }
    }
    unawaited(_persistScopedLocalSnapshot());
    unawaited(PushController.instance.syncListTopicsFromStore());
  }

  Future<void> _tryUploadSignInRecord(SignInRecord record) async {
    if (!AppConnectivity.instance.hasNetworkInterface) return;
    try {
      final name = record.studentName?.trim();
      final reg = record.registrationNumber?.trim().toUpperCase();
      await _firestore
          .collection(FirestoreCollections.signIns)
          .doc(record.id)
          .set(
            <String, dynamic>{
              'listId': record.listId,
              'studentId': record.studentId,
              'course': record.course,
              'signedInAt': Timestamp.fromDate(record.signedInAt),
              if (name != null && name.isNotEmpty) 'studentName': name,
              if (reg != null && reg.isNotEmpty) 'registrationNumber': reg,
            },
            SetOptions(merge: true),
          )
          .timeout(_sessionPublishTimeout);
    } catch (_) {}
  }

  /// Uploads local roster enrollments that have not reached Firestore yet.
  Future<void> syncUnuploadedSignIns() async {
    if (!AppConnectivity.instance.hasNetworkInterface) return;
    for (final record in List<SignInRecord>.from(AttendanceStore.signIns)) {
      await _tryUploadSignInRecord(record);
    }
  }

  /// Resolves a student row for list enrollment / check-in replay.
  Future<StudentRecord?> resolveStudentForRegistration(
    String registrationNumber,
  ) async {
    final normalized =
        StudentRegistrationNumber.normalize(registrationNumber.trim());
    if (normalized.isEmpty) return null;
    if (await deviceRegistrationBlockReason(normalized) != null) {
      return null;
    }

    var student = AttendanceStore.findStudentByReg(normalized);
    if (student != null) {
      student = _reconcileStudentIdToRegistration(student);
      await _persistStudentRecord(student, awaitWhenOnline: true);
      return student;
    }

    student = await registerStudentFromAuthProfile(normalized);
    if (student != null) return student;

    final registeredName = await _resolveRegisteredFullNameForReg(normalized);
    if (registeredName != null && registeredName.isNotEmpty) {
      return registerStudent(
        registeredName,
        normalized,
        initialsFromFullName(registeredName),
      );
    }

    final fetched =
        await _fetchStudentsForRegistration(normalized, force: true);
    if (fetched.isEmpty) return null;
    final remote = fetched.first;
    return registerStudent(
      remote.name,
      remote.registrationNumber,
      remote.initials,
    );
  }

  /// Adds the student to [list] when not already enrolled (before check-in).
  Future<StudentListEnrollOutcome> ensureStudentEnrolledOnList({
    required AttendanceList list,
    required StudentRecord student,
    String? course,
  }) async {
    if (await deviceRegistrationBlockReason(student.registrationNumber) !=
        null) {
      return StudentListEnrollOutcome.deviceBlocked;
    }
    if (AttendanceStore.hasStudentSignedIntoList(list.id, student.id)) {
      return StudentListEnrollOutcome.alreadyEnrolled;
    }
    final courses = list.coursesSafe;
    if (courses.isEmpty) return StudentListEnrollOutcome.noCourses;
    final trimmed = course?.trim();
    final chosen = (trimmed != null && trimmed.isNotEmpty)
        ? trimmed
        : (courses.length == 1 ? courses.first : null);
    if (chosen == null || chosen.isEmpty) {
      return StudentListEnrollOutcome.needsCourseChoice;
    }
    await ensureSignInAndBackfillPastAbsents(
      listId: list.id,
      studentId: student.id,
      course: chosen,
    );
    await _bindDeviceRegistrationIfNeeded(student.registrationNumber);
    return StudentListEnrollOutcome.enrolled;
  }

  /// Records list enrollment (if new), backfills missed-session absents, then
  /// reloads official rows from Firebase when online.
  Future<void> ensureSignInAndBackfillPastAbsents({
    required String listId,
    required String studentId,
    required String course,
  }) async {
    if (!AttendanceStore.hasSignedIn(listId, studentId, course)) {
      await addSignIn(listId, studentId, course);
    }
    await _promoteMetadataMatchedPresentForStudentOnList(
      listId: listId,
      studentId: studentId,
      course: course,
    );
    await backfillPastAbsentsForStudentOnList(listId, studentId);
    await _requestServerAbsentBackfill(listId, studentId);
  }

  /// When the student checked in (or queued metadata) before joining the list,
  /// writes present for ended sessions that match code + time + GPS.
  Future<void> _promoteMetadataMatchedPresentForStudentOnList({
    required String listId,
    required String studentId,
    required String course,
  }) async {
    await _uploadPendingMetadataEvidenceForStudent(
      listId: listId,
      studentId: studentId,
    );
    if (AttendanceStore.sessionsForListNewestFirst(listId).isEmpty) {
      await loadListAttendanceData(listId, force: true);
    }
    final pendingCheckIns = await PendingCheckInQueue.loadAll();
    final pendingCodes = await PendingSessionCodeQueue.loadAll();
    final studentReg = AttendanceStore.students
        .where((s) => s.id == studentId)
        .map((s) => s.registrationNumber)
        .firstOrNull;
    final regForMatch = studentReg?.trim().toUpperCase() ?? '';

    for (final sess in AttendanceStore.sessionsForListNewestFirst(listId)) {
      if (AttendanceStore.isPresentForSession(sess.id, studentId)) continue;
      final recordId = attendanceRecordIdForSessionStudent(sess.id, studentId);
      if (await _remoteRecordIsPresent(recordId)) continue;

      PendingCheckInEntry? matchedCheckIn;
      for (final e in pendingCheckIns) {
        if (e.studentId != studentId) continue;
        if (e.sessionId == sess.id && pendingCheckInMatchesSession(e, sess)) {
          matchedCheckIn = e;
          break;
        }
      }

      PendingSessionCodeEntry? matchedCode;
      for (final e in pendingCodes) {
        final matches = pendingSessionCodeMatchesSession(
              entry: e,
              session: sess,
              studentRegistrationNumber: regForMatch,
            ) ||
            pendingSessionCodeMatchesSessionForCorrection(
              entry: e,
              session: sess,
              studentRegistrationNumber: regForMatch,
            );
        if (!matches) continue;
        matchedCode = e;
        break;
      }

      if (matchedCheckIn == null && matchedCode == null) {
        matchedCheckIn = await _serverAttemptMatchesSessionForStudent(
          listId: listId,
          session: sess,
          studentId: studentId,
        );
      }
      if (matchedCheckIn == null && matchedCode == null) continue;

      final record = AttendanceRecord(
        id: recordId,
        sessionId: sess.id,
        studentId: studentId,
        course: course.trim().isNotEmpty ? course.trim() : '—',
        timestamp: matchedCheckIn?.capturedAt ?? matchedCode!.capturedAt,
        latitude: matchedCheckIn?.latitude ?? matchedCode!.latitude,
        longitude: matchedCheckIn?.longitude ?? matchedCode!.longitude,
        verified: true,
        present: true,
        deviceId: matchedCheckIn?.deviceId ?? matchedCode!.deviceId,
      );
      try {
        final outcome = await submitStudentCheckInWithOfflineSupport(
          record,
          listIdOverride: listId,
          sessionCodeRaw: matchedCode?.sessionCodeRaw,
        );
        switch (outcome) {
          case StudentOfflineCheckInOutcome.success:
          case StudentOfflineCheckInOutcome.submittedPendingVerification:
          case StudentOfflineCheckInOutcome.duplicate:
            final existing = AttendanceStore.attendanceRecordForSessionStudent(
              sess.id,
              studentId,
            );
            if (existing != null) {
              AttendanceStore.updateAttendanceRecord(record);
            } else {
              AttendanceStore.addAttendanceRecordIfAbsent(record);
            }
            _notifyStoreUpdated();
            break;
          default:
            await _requestServerAbsentBackfill(listId, studentId);
            if (AppConnectivity.instance.hasNetworkInterface) {
              await awaitOfficialRecordFromFirebase(
                sessionId: sess.id,
                studentId: studentId,
                timeout: const Duration(seconds: 15),
              );
            }
            break;
        }
      } catch (_) {}
    }
  }

  /// Corrects absent roll rows already on this device when queued metadata matches.
  Future<void> correctMetadataMatchedAbsentRollForSignedInLists() async {
    final seen = <String>{};
    for (final signIn in AttendanceStore.signIns) {
      final key = '${signIn.listId}:${signIn.studentId}';
      if (!seen.add(key)) continue;
      var course = AttendanceStore.courseForStudentOnList(
        signIn.listId,
        signIn.studentId,
      );
      if (course.isEmpty) course = signIn.course;
      final trimmedCourse = course.trim().isNotEmpty ? course.trim() : '—';
      await _uploadPendingMetadataEvidenceForStudent(
        listId: signIn.listId,
        studentId: signIn.studentId,
      );
      await _promoteMetadataMatchedPresentForStudentOnList(
        listId: signIn.listId,
        studentId: signIn.studentId,
        course: trimmedCourse,
      );
      await _requestServerAbsentBackfill(signIn.listId, signIn.studentId);
      if (!AppConnectivity.instance.hasNetworkInterface) continue;
      final refreshSessions = <Future<void>>[];
      for (final sess
          in AttendanceStore.sessionsForListNewestFirst(signIn.listId)) {
        final existing = AttendanceStore.attendanceRecordForSessionStudent(
          sess.id,
          signIn.studentId,
        );
        if (existing != null && existing.present && existing.verified) {
          continue;
        }
        final hasEvidence = await _hasMetadataEvidenceForSessionStudent(
          session: sess,
          studentId: signIn.studentId,
          listId: signIn.listId,
        );
        if (!hasEvidence &&
            !(existing != null && existing.present && !existing.verified)) {
          continue;
        }
        refreshSessions.add(
          awaitOfficialRecordFromFirebase(
            sessionId: sess.id,
            studentId: signIn.studentId,
            timeout: const Duration(seconds: 8),
          ).then((_) {}),
        );
      }
      if (refreshSessions.isNotEmpty) {
        await Future.wait(refreshSessions);
      }
      await refreshStudentAttendanceRecordsForList(
        signIn.listId,
        signIn.studentId,
      );
    }
    _notifyStoreUpdated();
  }

  /// Server-side check-in evidence for [session] when local queues are empty.
  Future<PendingCheckInEntry?> _serverAttemptMatchesSessionForStudent({
    required String listId,
    required AttendanceSession session,
    required String studentId,
  }) async {
    if (!AppConnectivity.instance.hasNetworkInterface) return null;
    try {
      final snaps = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      final byList = await _firestore
          .collection(FirestoreCollections.checkInAttempts)
          .where('studentId', isEqualTo: studentId)
          .where('listId', isEqualTo: listId)
          .get(_loadQueryOptions(force: true));
      snaps.addAll(byList.docs);
      final code = normalizeSessionCodeInput(session.sessionCode);
      if (code.isNotEmpty) {
        final byCode = await _firestore
            .collection(FirestoreCollections.checkInAttempts)
            .where('studentId', isEqualTo: studentId)
            .where('sessionCodeRaw', isEqualTo: code)
            .get(_loadQueryOptions(force: true));
        for (final d in byCode.docs) {
          if (!snaps.any((s) => s.id == d.id)) snaps.add(d);
        }
      }
      for (final doc in snaps) {
        final data = doc.data();
        final status = (data['status'] as String?)?.trim().toLowerCase() ?? '';
        final sid = (data['sessionId'] as String?)?.trim() ?? '';
        if (sid.isNotEmpty && sid != session.id) continue;
        final capturedAt = (data['capturedAt'] as Timestamp?)?.toDate();
        if (capturedAt == null) continue;
        final lat = (data['latitude'] as num?)?.toDouble() ?? 0;
        final lng = (data['longitude'] as num?)?.toDouble() ?? 0;
        if (!isTimestampWithinSessionBounds(session, capturedAt)) continue;
        final strictMatch = isPositionWithinSession(session, lat, lng);
        final correctionMatch =
            positionQualifiesForPresentCorrection(session, lat, lng);
        if (status == 'rejected') {
          if (!correctionMatch) continue;
        } else if (!strictMatch && !correctionMatch) {
          continue;
        }
        return PendingCheckInEntry(
          id: doc.id,
          sessionId: sid.isNotEmpty ? sid : session.id,
          studentId: studentId,
          listId: listId,
          course: (data['course'] as String?)?.trim() ?? '—',
          capturedAt: capturedAt,
          latitude: lat,
          longitude: lng,
          deviceId: (data['deviceId'] as String?)?.trim() ?? '',
          pendingSince: DateTime.now(),
        );
      }
    } catch (_) {}
    return null;
  }

  /// Nudges Cloud Functions to write official absent rows for missed sessions.
  Future<void> _requestServerAbsentBackfill(
    String listId,
    String studentId,
  ) async {
    if (!AppConnectivity.instance.isOnline) return;
    try {
      final snap = await _firestore
          .collection(FirestoreCollections.signIns)
          .where('listId', isEqualTo: listId)
          .where('studentId', isEqualTo: studentId)
          .limit(1)
          .get()
          .timeout(_sessionPublishTimeout);
      if (snap.docs.isEmpty) return;
      await snap.docs.first.reference.update(<String, dynamic>{
        'backfillRequestedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  /// Idempotent: creates missing absent rows for completed sessions on [listId]
  /// where the student has no check-in. Sessions that ended **before** the
  /// student joined the list are marked absent immediately; later sessions keep
  /// the normal verification grace window.
  Future<void> backfillPastAbsentsForStudentOnList(
    String listId,
    String studentId,
  ) async {
    final enrolledAt =
        AttendanceStore.earliestSignInAtForStudentOnList(listId, studentId);
    for (final sess in AttendanceStore.sessionsForListNewestFirst(listId)) {
      if (!sess.countsTowardRollStats) continue;
      final missedBeforeJoin =
          enrolledAt != null && sess.endTime.isBefore(enrolledAt);
      if (!missedBeforeJoin &&
          !rollGracePeriodExpired(sess, DateTime.now())) {
        continue;
      }
      if (AttendanceStore.hasCheckedIn(sess.id, studentId)) continue;
      final recordId = attendanceRecordIdForSessionStudent(sess.id, studentId);
      if (await _remoteRecordIsPresent(recordId)) continue;
      final pendingCheckIns = await PendingCheckInQueue.loadAll();
      final pendingCodes = await PendingSessionCodeQueue.loadAll();
      final studentReg = AttendanceStore.students
          .where((s) => s.id == studentId)
          .map((s) => s.registrationNumber)
          .firstOrNull;
      final metadataMatchedCheckIn = pendingCheckIns.any(
        (e) =>
            e.sessionId == sess.id &&
            e.studentId == studentId &&
            (pendingCheckInMatchesSession(e, sess) ||
                pendingCheckInMatchesSessionForCorrection(e, sess)),
      );
      final regForMatch = studentReg?.trim().toUpperCase() ?? '';
      final metadataMatchedCode = pendingCodes.any(
        (e) =>
            pendingSessionCodeMatchesSession(
              entry: e,
              session: sess,
              studentRegistrationNumber: regForMatch,
            ) ||
            pendingSessionCodeMatchesSessionForCorrection(
              entry: e,
              session: sess,
              studentRegistrationNumber: regForMatch,
            ),
      );
      final metadataMatchedServer = await _serverAttemptMatchesSessionForStudent(
        listId: listId,
        session: sess,
        studentId: studentId,
      );
      if (metadataMatchedCheckIn ||
          metadataMatchedCode ||
          metadataMatchedServer != null) {
        await _promoteMetadataMatchedPresentForStudentOnList(
          listId: listId,
          studentId: studentId,
          course: AttendanceStore.courseForStudentOnList(listId, studentId)
                  .trim()
                  .isNotEmpty
              ? AttendanceStore.courseForStudentOnList(listId, studentId)
              : (AttendanceStore.listById(listId)?.coursesSafe.firstOrNull ??
                  '—'),
        );
        continue;
      }
      if (sessionStudentCheckInMetadataIncomplete(sess)) continue;
      final incompletePendingCheckIn = pendingCheckIns.any(
        (e) =>
            e.sessionId == sess.id &&
            e.studentId == studentId &&
            pendingCheckInMissingMetadataForPending(e),
      );
      final incompletePendingCode = pendingCodes.any(
        (e) =>
            e.sessionId == sess.id &&
            e.registrationNumber.trim().toUpperCase() ==
                (studentReg?.trim().toUpperCase() ?? '') &&
            pendingSessionCodeMissingMetadataForPending(e),
      );
      if (incompletePendingCheckIn || incompletePendingCode) continue;
      final existingLocal =
          AttendanceStore.attendanceRecordForSessionStudent(sess.id, studentId);
      if (existingLocal != null && existingLocal.present) continue;
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
        timestamp: existingLocal?.timestamp ?? sess.endTime,
        latitude: existingLocal != null &&
                isValidCheckInCoordinates(
                  existingLocal.latitude,
                  existingLocal.longitude,
                )
            ? existingLocal.latitude
            : 0,
        longitude: existingLocal != null &&
                isValidCheckInCoordinates(
                  existingLocal.latitude,
                  existingLocal.longitude,
                )
            ? existingLocal.longitude
            : 0,
        verified: false,
        present: false,
        deviceId: existingLocal?.deviceId,
      );
      try {
        await submitAttendanceRecord(record);
      } catch (_) {}
    }
  }
}
