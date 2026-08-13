import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import '../../../core/auth/auth_repository.dart';
import '../../../core/auth/kiu_admin_registration_number.dart';
import '../../../core/auth/lecturer_registration_number.dart';
import '../../../core/auth/staff_auth_email.dart';
import '../../../core/auth/student_registration_number.dart';
import '../../../core/cache/smart_cache_policy.dart';
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/device/device_student_registration_lock.dart';
import '../../../core/connectivity/online_first_persist.dart';
import '../../../core/api/api_auth.dart';
import '../../../core/api/api_collections.dart';
import '../../../core/api/api_datetime.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/api_field_value.dart';
import '../../../core/api/api_store.dart';
import '../../../core/api/rtd_stubs.dart';
import '../../../core/notifications/notification_maintenance_coordinator.dart';
import '../../../core/push/push_controller.dart';
import '../../../core/storage/attendance_local_snapshot.dart';
import '../../../core/storage/staff_number_directory_cache.dart';
import '../attendance_list_hierarchy.dart';
import '../attendance_schedule_utils.dart';
import '../../notices/data/notices_repository.dart';
import '../check_in_outcome.dart';
import '../check_in_rejection.dart';
import '../check_in_validation.dart';
import '../offline_capture_trust.dart';
import '../models/attendance_models.dart';
import '../student_session_grace.dart';
import '../pending_attendance_evidence.dart';
import '../roll_cell_status.dart'
    show sessionStudentCheckInMetadataIncomplete;
import 'attendance_list_purge.dart';
import 'attendance_remote_list_watch.dart';
import 'attendance_remote_record_watch.dart';
import 'attendance_rtd_record_watch.dart';
import 'pending_check_in_queue.dart';
import 'pending_retention.dart';
import 'pending_list_create_queue.dart';
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

  Timer? _notifyDebounce;
  bool _notifyFlushScheduled = false;
  Timer? _persistDebounce;
  bool _persistScheduled = false;

  void _notifyStoreUpdated({
    bool immediate = false,
    bool refreshRecordWatch = false,
  }) {
    if (refreshRecordWatch) {
      if (!isStudentRecordWatchUser()) {
        unawaited(AttendanceRemoteRecordWatch.instance.refreshIfNeeded());
      }
      unawaited(AttendanceRtdRecordWatch.instance.refreshIfNeeded());
    }
    if (immediate) {
      _notifyDebounce?.cancel();
      _notifyDebounce = null;
      _notifyFlushScheduled = false;
      notifyListeners();
      return;
    }
    if (_notifyFlushScheduled) return;
    _notifyFlushScheduled = true;
    _notifyDebounce?.cancel();
    _notifyDebounce = Timer(const Duration(milliseconds: 200), () {
      _notifyFlushScheduled = false;
      _notifyDebounce = null;
      notifyListeners();
    });
  }

  /// Coalesces full-store snapshot writes during live roll updates.
  void _schedulePersistScopedLocalSnapshot() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(seconds: 2), () {
      _persistScheduled = false;
      _persistDebounce = null;
      unawaited(_persistScopedLocalSnapshot());
    });
  }

  /// Flushes a pending debounced snapshot (e.g. app background / sign-out).
  Future<void> flushScopedLocalSnapshot() async {
    _persistDebounce?.cancel();
    _persistScheduled = false;
    await _persistScopedLocalSnapshot();
  }

  /// Notifies profile / attendance UI after session validation or record refresh.
  void notifyAttendanceStoreUpdated() => _notifyStoreUpdated();

  /// Instant UI refresh after Realtime Database roll stats or records land.
  void notifyStoreUpdatedFromRtd() {
    _notifyStoreUpdated(immediate: true);
    if (isStudentRecordWatchUser() || isStudentScopedUser()) {
      _schedulePersistScopedLocalSnapshot();
    }
  }

  /// When the signed-in user is a lecturer (not admin), loads are scoped to their lists.
  static String? currentLecturerLoadScopeUid() {
    final a = AuthRepository.instance;
    if (!a.isLoggedIn || !a.adminCheckDone || !a.lecturerCheckDone) return null;
    if (a.isLecturer && !a.isAdmin) {
      return a.currentUserId;
    }
    if (a.isKiuAdmin) {
      return a.currentUserId;
    }
    return null;
  }

  /// True when realtime attendance listeners should use the student path.
  static bool isStudentRecordWatchUser() {
    if (isStudentScopedUser()) return true;
    final a = AuthRepository.instance;
    if (!a.isLoggedIn) return false;
    if (a.isSyntheticStaffAuthIdentity || a.isStaffAuthIdentity) return false;
    if (a.roleCheckDone &&
        (a.isAdmin || a.isQaStaff || a.isKiuAdmin || a.isLecturer)) {
      return false;
    }
    return a.isStudentAuthIdentity &&
        a.currentRegistrationNumber?.trim().isNotEmpty == true;
  }

  /// True when [loadAll] should fetch only the signed-in student's own rows.
  static bool isStudentScopedUser() {
    final a = AuthRepository.instance;
    if (!a.isLoggedIn) return false;
    if (a.isSyntheticStaffAuthIdentity || a.isStaffAuthIdentity) return false;
    if (a.isAdmin || a.isQaStaff || a.isKiuAdmin || a.isLecturer) return false;
    if (a.roleCheckDone) {
      if (a.isStudentProfile) return true;
      return a.isStudentAuthIdentity &&
          a.currentRegistrationNumber?.trim().isNotEmpty == true;
    }
    return a.isStudentAuthIdentity;
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
  static const Duration _sessionPublishFastTimeout = Duration(seconds: 3);
  static const int _sessionUploadMaxAttempts = 4;
  static const List<int> _sessionUploadBackoffMs = [0, 250, 500, 1000];

  /// Sessions uploading to Firestore after an optimistic local start.
  static final Set<String> _publishingSessionIds = <String>{};
  static const Duration _onlineFirestoreTimeout = Duration(seconds: 12);

  final Map<String, bool> _sessionPublishedOnServerCache = {};
  DateTime? _sessionPublishedCacheAt;
  static const Duration _sessionPublishedCacheTtl = Duration(seconds: 3);
  Set<String>? _awaitingUploadSessionIdsCache;
  DateTime? _awaitingUploadCacheAt;
  final Set<String> _listsPublishedOnServer = <String>{};

  /// Live listeners on in-flight check-in attempts (accepted → verify locally).
  final Map<String, StreamSubscription<ApiDocumentSnapshot>>
      _checkInAttemptWatchSubs = {};

  /// RTD listeners for low-latency check-in confirmation (primary over Firestore).
  final Map<String, StreamSubscription<CheckInRtdConfirmation?>>
      _checkInRtdWatchSubs = {};

  /// Prefer Firestore server reads when online; fall back to cache when offline.
  ApiGetOptions _loadQueryOptions({required bool force}) {
    final c = AppConnectivity.instance;
    if (force || c.isOnline) {
      return const ApiGetOptions(source: ApiSource.server);
    }
    return const ApiGetOptions(source: ApiSource.serverAndCache);
  }

  /// Shared short timeout for offline-first list/session Firestore writes.
  static Duration get listPublishTimeout => _sessionPublishTimeout;

  ApiStore? get _firestoreIfReady => tryApiStore();

  ApiStore get _firestore {
    final db = _firestoreIfReady;
    if (db == null) {
      throw StateError('Firestore is not available');
    }
    return db;
  }

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  /// True when [AttendanceStore] already has data (memory or restored snapshot).
  ///
  /// An empty store after a premature student fetch (new device, reg not on
  /// server yet) is **not** treated as cached so later reloads still run.
  bool get hasCachedStore {
    if (!_storeLooksEmpty()) return true;
    if (!_isLoaded) return false;
    final auth = AuthRepository.instance;
    if (isStudentScopedUser() ||
        (auth.isLoggedIn && auth.isLikelyStudent)) {
      return studentProfileHasLocalData();
    }
    return true;
  }

  /// Student profile lists/sessions/records present in the local store.
  bool studentProfileHasLocalData([String? registration]) {
    final reg =
        registration?.trim().toUpperCase() ??
        _normalizedStudentRegistrationForCache();
    if (reg == null || reg.isEmpty) return false;
    return AttendanceStore.hasAttendanceDataForRegistrationNormalized(reg) ||
        AttendanceStore.hasStudentSessionHistoryForRegistrationNormalized(reg);
  }

  /// Restores the last on-device attendance snapshot so UI can paint before Firestore.
  Future<bool>? _warmSnapshotInFlight;

  Future<bool> warmFromLocalSnapshot() {
    final inFlight = _warmSnapshotInFlight;
    if (inFlight != null) return inFlight;
    final task = _warmFromLocalSnapshotBody().whenComplete(() {
      _warmSnapshotInFlight = null;
    });
    _warmSnapshotInFlight = task;
    return task;
  }

  Future<bool> _warmFromLocalSnapshotBody() async {
    if (!AuthRepository.instance.isLoggedIn) return false;
    if (AuthRepository.instance.needsEmailVerification) return false;

    final loadGeneration = _loadGeneration;
    final uid = _snapshotUserId();
    if (uid == null || uid.isEmpty) return false;

    // Try likely scope tags before role hydration so list cards appear instantly.
    final auth = AuthRepository.instance;
    if (auth.isStaffAuthIdentity) {
      if (await _restoreLocalSnapshot(uid, loadGeneration: loadGeneration)) {
        return true;
      }
    }
    final rawReg = auth.currentRegistrationNumber?.trim();
    final normalizedReg = rawReg != null && rawReg.isNotEmpty
        ? StudentRegistrationNumber.normalize(rawReg)
        : null;
    if (normalizedReg != null && auth.isLikelyStudent) {
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
  Future<void> loadAttendanceListsFirst({bool force = false}) async {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn) return;
    if (_likelyStudentBeforeRoleCheck()) return;
    await warmFromLocalSnapshot();
    if (!force &&
        AttendanceStore.lists.isNotEmpty &&
        _listsCatalogCacheFresh()) {
      return;
    }
    if (!force && AttendanceStore.lists.isNotEmpty) {
      unawaited(
        loadAll(
          force: false,
          listsOnly: true,
          scopeToLecturerUid: _listsOnlyScopeUid(),
        ),
      );
      return;
    }
    await loadAll(
      force: force,
      listsOnly: true,
      scopeToLecturerUid: _listsOnlyScopeUid(),
    );
  }

  bool _likelyStudentBeforeRoleCheck() =>
      AuthRepository.instance.isLikelyStudent;

  /// Student profile / sign-in: same local snapshot model as lecturers (`stu:REG`).
  Future<void>? _studentProfileLoadInFlight;

  Future<void> loadStudentAttendanceForProfile({bool force = false}) async {
    if (!AuthRepository.instance.isLoggedIn) return;
    if (AuthRepository.instance.needsEmailVerification) return;
    final auth = AuthRepository.instance;
    final hasReg = auth.currentRegistrationNumber?.trim().isNotEmpty == true;
    if (!_likelyStudentBeforeRoleCheck() &&
        !isStudentScopedUser() &&
        !(auth.isStudentAuthIdentity && hasReg)) {
      return;
    }

    if (_studentProfileLoadInFlight != null && !force) {
      return _studentProfileLoadInFlight!;
    }
    final task = _loadStudentAttendanceForProfileBody(force: force)
        .whenComplete(() {
      _studentProfileLoadInFlight = null;
    });
    _studentProfileLoadInFlight = task;
    return task;
  }

  Future<void> _loadStudentAttendanceForProfileBody({required bool force}) async {
    _ensureSnapshotStudentScope();
    await warmFromLocalSnapshot();
    unawaited(AttendanceRemoteRecordWatch.instance.start());
    unawaited(AttendanceRtdRecordWatch.instance.start());

    final reg = _normalizedStudentRegistrationForCache();
    final sessionHistoryReady = reg != null &&
        AttendanceStore.hasStudentSessionHistoryForRegistrationNormalized(reg);
    final missingListMetadata =
        reg != null && _studentProfileHasMissingListMetadata(reg);

    if (!AppConnectivity.instance.isOnline && !force) {
      if (reg != null) {
        await _keepStudentStoreFromLocalSnapshot(reg, _loadGeneration);
        await _rehydrateStudentPendingWorkIntoStore();
        await _ensureStudentEnrolledListMetadataLoaded(reg: reg);
      }
      return;
    }

    // Cached sessions on disk — paint immediately; RTD + Firestore in background.
    if (!force && sessionHistoryReady && !missingListMetadata) {
      _isLoaded = true;
      _loadScopeStudentReg = reg;
      _loadScopeLecturerUid = null;
      unawaited(AttendanceRemoteRecordWatch.instance.start());
      unawaited(AttendanceRtdRecordWatch.instance.start());
      _notifyStoreUpdated(refreshRecordWatch: true);
      if (AppConnectivity.instance.isOnline) {
        unawaited(() async {
          await refreshStudentProfileFromRtd();
          notifyStoreUpdatedFromRtd();
          await reconcileDeletedListsAgainstRemote();
          await _refreshStudentEnrolledListDetails(force: false);
        }());
      }
      return;
    }

    if (!force && reg != null && missingListMetadata) {
      await _ensureStudentEnrolledListMetadataLoaded(reg: reg);
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
    final sessionHistoryReady = reg != null &&
        AttendanceStore.hasStudentSessionHistoryForRegistrationNormalized(reg);
    final missingListMetadata =
        reg != null && _studentProfileHasMissingListMetadata(reg);

    if (!force && sessionHistoryReady && !missingListMetadata) {
      unawaited(AttendanceRemoteRecordWatch.instance.start());
      unawaited(AttendanceRtdRecordWatch.instance.start());
      if (AppConnectivity.instance.isOnline) {
        unawaited(reconcileDeletedListsAgainstRemote());
      }
      unawaited(_fetchNeverLoadedStudentListDetails());
      return;
    }

    if (!force && reg != null && missingListMetadata) {
      await _ensureStudentEnrolledListMetadataLoaded(reg: reg);
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
    unawaited(AttendanceRemoteRecordWatch.instance.start());
    unawaited(AttendanceRtdRecordWatch.instance.start());
    _notifyStoreUpdated(refreshRecordWatch: true);
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
  Future<void>? _remoteSyncInFlight;

  /// QA/admin full [loadAll] (sessions + rolls), not only fast list metadata.
  bool _staffFullBootstrapDone = false;

  /// Restores local snapshot, then syncs Firestore when cache is empty or [force].
  Future<void> syncFromRemoteIfNeeded({bool force = false}) {
    if (_remoteSyncInFlight != null && !force) return _remoteSyncInFlight!;
    final task = _syncFromRemoteBody(force: force).whenComplete(() {
      _remoteSyncInFlight = null;
    });
    _remoteSyncInFlight = task;
    return task;
  }

  Future<void> _syncFromRemoteBody({required bool force}) async {
    if (AuthRepository.instance.needsEmailVerification) return;
    await warmFromLocalSnapshot();

    await _awaitRoleChecksDone();
    if (!AuthRepository.instance.isLoggedIn) return;
    if (!AuthRepository.instance.roleCheckDone) return;

    if (isStudentScopedUser()) {
      if (!force && hasCachedStore) {
        unawaited(loadStudentAttendanceForProfile(force: false));
        return;
      }
      await loadStudentAttendanceForProfile(force: force);
      return;
    }

    if (!_likelyStudentBeforeRoleCheck()) {
      if (!force &&
          hasCachedStore &&
          AttendanceStore.lists.isNotEmpty &&
          _listsCatalogCacheFresh()) {
        prefetchActiveListDetails();
      } else if (!force && hasCachedStore && AttendanceStore.lists.isNotEmpty) {
        unawaited(
          loadAll(
            force: false,
            listsOnly: true,
            scopeToLecturerUid: _listsOnlyScopeUid(),
          ),
        );
        prefetchActiveListDetails();
      } else {
        await loadAll(
          force: force,
          listsOnly: true,
          scopeToLecturerUid: _listsOnlyScopeUid(),
        );
        prefetchActiveListDetails();
      }
    }

    if (AppConnectivity.instance.isOnline) {
      unawaited(reconcileDeletedListsAgainstRemote());
    }
  }

  Future<void> _runBootstrapLoad({required bool force}) async {
    await warmFromLocalSnapshot();

    if (_usesFullStaffListLoad() && !_staffFullBootstrapDone) {
      await _awaitRoleChecksDone();
      if (AuthRepository.instance.isLoggedIn &&
          AuthRepository.instance.roleCheckDone) {
        await loadAll(force: true, listsOnly: false);
        if (_isLoaded) {
          _staffFullBootstrapDone = true;
        }
      }
      return;
    }

    if (!force && hasCachedStore) {
      unawaited(syncFromRemoteIfNeeded(force: false));
      return;
    }

    await syncFromRemoteIfNeeded(force: force);
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

  /// Session ids for lecturer realtime [attendance_records] listeners.
  ///
  /// Active sessions and recently opened lists are prioritized so roll tables
  /// update promptly even when the store holds many historical sessions.
  Set<String> sessionIdsForRecordWatch({int maxSessions = 80}) {
    final out = <String>[];
    final seen = <String>{};

    void add(String raw) {
      final id = raw.trim();
      if (id.isEmpty || !seen.add(id)) return;
      out.add(id);
    }

    for (final s in AttendanceStore.sessions) {
      if (s.isActive) add(s.id);
    }

    for (final listId in _recentListDetailIds) {
      for (final s in AttendanceStore.sessions) {
        if (s.listId == listId) add(s.id);
      }
    }

    final sorted = List<AttendanceSession>.from(AttendanceStore.sessions)
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    for (final s in sorted) {
      add(s.id);
      if (out.length >= maxSessions) break;
    }

    return out.toSet();
  }

  /// Session ids eligible for Realtime Database record listeners.
  ///
  /// Admins/QA use Firestore bulk watch; RTD is used for the active session only.
  /// Lecturers are limited to sessions on lists they own.
  Set<String> sessionIdsForRtdRecordWatch({int maxSessions = 80}) {
    final all = sessionIdsForRecordWatch(maxSessions: maxSessions);
    final a = AuthRepository.instance;
    if (!a.isLoggedIn) return const {};

    if (a.isAdmin || a.isQaStaff || a.isKiuAdmin) {
      return const {};
    }

    final uid = a.currentUserId?.trim() ?? '';
    if (uid.isEmpty) return const {};

    if (!a.isLecturer) return all;

    final ownedListIds = AttendanceStore.lists
        .where((l) => l.lecturerUid?.trim() == uid)
        .map((l) => l.id)
        .toSet();

    return all.where((sid) {
      final session = AttendanceStore.sessionById(sid);
      if (session == null) return false;
      return ownedListIds.contains(session.listId);
    }).toSet();
  }

  void _touchRecentListDetail(String listId) {
    final id = listId.trim();
    if (id.isEmpty) return;
    _recentListDetailIds.remove(id);
    _recentListDetailIds.add(id);
    while (_recentListDetailIds.length > _maxRecentListDetailIds) {
      _recentListDetailIds.removeAt(0);
    }
  }

  /// Prioritizes this list for realtime record listeners and detail prefetch.
  void touchRecentListDetail(String listId) => _touchRecentListDetail(listId);

  static bool _isRtdPermissionError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('permission-denied') ||
        message.contains('permission_denied');
  }

  /// Republish student RTD index once, then retry a read blocked by rules.
  Future<T?> _rtdReadWithStudentIndexRetry<T>(Future<T> Function() read) async {
    try {
      return await read();
    } catch (e) {
      if (!_isRtdPermissionError(e)) rethrow;
      await StudentRtdIndex.publishCurrentStudentRegistration();
      try {
        return await read();
      } catch (_) {
        return null;
      }
    }
  }

  /// Lists recently opened in detail UI — used for student RTD stats listeners.
  List<String> recentListDetailIdsForWatch() =>
      List<String>.unmodifiable(_recentListDetailIds);

  /// Pulls official rows + per-list roll stats for a student class from RTD.
  Future<bool> refreshStudentListAttendanceFromRtd(String listId) async {
    if (!isStudentRecordWatchUser()) return false;
    final lid = listId.trim();
    if (lid.isEmpty) return false;
    final db = null /* RTD disabled */;
    if (db == null) return false;
    final reg = studentRegistrationForRtdWatch();
    if (reg == null || reg.isEmpty) return false;

    var applied = false;

    try {
      for (final s in await SessionRtdSync.fetchByListId(lid)) {
        if (s.listId.trim() != lid) continue;
        if (AttendanceStore.sessionById(s.id) != null) {
          AttendanceStore.updateSession(s);
        } else {
          AttendanceStore.addSession(s);
        }
        applied = true;
      }
    } catch (_) {}

    final listSessionIds = AttendanceStore.sessions
        .where((s) => s.listId == lid)
        .map((s) => s.id)
        .toSet();

    for (final studentId in {reg}) {
      try {
        final snap = await _rtdReadWithStudentIndexRetry(
          () => db
              .ref(AttendanceRecordRtdSync.studentRecordsPath(studentId))
              .get()
              .timeout(const Duration(seconds: 4)),
        );
        final value = snap?.value;
        if (value is Map) {
          for (final entry in value.entries) {
            final sessionId = entry.key?.toString().trim() ?? '';
            if (sessionId.isEmpty) continue;
            var session = AttendanceStore.sessionById(sessionId);
            if (session == null) {
              session = await SessionRtdSync.fetchById(sessionId);
              if (session != null) {
                if (session.listId.trim() == lid) {
                  AttendanceStore.addSession(session);
                  listSessionIds.add(session.id);
                  applied = true;
                } else {
                  continue;
                }
              }
            }
            if (session != null && session.listId.trim() != lid) continue;
            if (session == null &&
                listSessionIds.isNotEmpty &&
                !listSessionIds.contains(sessionId)) {
              continue;
            }
            final record = AttendanceRecordRtdSync.recordFromRtdValue(
              sessionId: sessionId,
              studentId: studentId,
              value: entry.value,
            );
            if (record == null) continue;
            await applyRemoteAttendanceRecord(record, immediate: true);
            applied = true;
          }
        }
      } catch (_) {}

      try {
        final statsSnap = await _rtdReadWithStudentIndexRetry(
          () => db
              .ref(AttendanceRecordRtdSync.studentListRollStatsPath(
                studentId,
                lid,
              ))
              .get()
              .timeout(const Duration(seconds: 3)),
        );
        if (statsSnap != null && statsSnap.exists) {
          final stats =
              StudentRollStatsSnapshot.fromRtdValue(statsSnap.value);
          if (stats != null) {
            AttendanceStore.setStudentListRollStats(studentId, lid, stats);
            applied = true;
          }
        }
      } catch (_) {}
    }

    if (applied) {
      AttendanceStore.invalidateLookupCaches();
      notifyStoreUpdatedFromRtd();
    }
    return applied;
  }

  /// Profile screen: pull overall + per-list stats and session rows from RTD.
  Future<bool> refreshStudentProfileFromRtd() async {
    if (!isStudentRecordWatchUser()) return false;
    final db = null /* RTD disabled */;
    if (db == null) return false;

    await AuthRepository.instance.ensureStudentRegistrationHydrated();
    await StudentRtdIndex.publishCurrentStudentRegistration();

    final reg = studentRegistrationForRtdWatch();
    if (reg == null || reg.isEmpty) return false;

    var applied = false;

    try {
      final overallSnap = await _rtdReadWithStudentIndexRetry(
        () => db
            .ref(AttendanceRecordRtdSync.studentRollStatsPath(reg))
            .get()
            .timeout(const Duration(seconds: 4)),
      );
      if (overallSnap != null && overallSnap.exists) {
        final stats = StudentRollStatsSnapshot.fromRtdValue(overallSnap.value);
        if (stats != null) {
          AttendanceStore.setStudentRollStats(reg, stats);
          applied = true;
        }
      }
    } catch (_) {}

    final listIds = <String>{
      ...AttendanceStore.enrolledListIdsForRegistrationNormalized(reg),
    };

    try {
      final byListSnap = await _rtdReadWithStudentIndexRetry(
        () => db
            .ref('${AttendanceRecordRtdSync.statsRoot}/by_student/$reg/by_list')
            .get()
            .timeout(const Duration(seconds: 4)),
      );
      final value = byListSnap?.value;
      if (value is Map) {
        for (final key in value.keys) {
          final lid = key?.toString().trim() ?? '';
          if (lid.isNotEmpty) listIds.add(lid);
        }
      }
    } catch (_) {}

    final missingListMetadata = listIds
        .where((id) => AttendanceStore.listById(id) == null)
        .toSet();
    if (missingListMetadata.isNotEmpty) {
      try {
        final fetched = await _fetchListsByIds(missingListMetadata, force: true);
        for (final list in fetched) {
          if (AttendanceStore.listById(list.id) != null) {
            AttendanceStore.updateList(list);
          } else {
            AttendanceStore.addList(list);
          }
          applied = true;
        }
      } catch (_) {}
    }

    for (final listId in listIds) {
      touchRecentListDetail(listId);
      if (await refreshStudentListAttendanceFromRtd(listId)) {
        applied = true;
      }
    }

    if (applied) {
      AttendanceStore.invalidateLookupCaches();
      notifyStoreUpdatedFromRtd();
      unawaited(AttendanceRtdRecordWatch.instance.refreshIfNeeded());
    }
    return applied;
  }

  /// Keeps only the most recent sessions for list-detail / roll loads.
  List<AttendanceSession> _limitSessionsForListDetail(
    Iterable<AttendanceSession> sessions,
  ) {
    final sorted = List<AttendanceSession>.from(sessions)
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    if (sorted.length <= _maxSessionsPerListDetailLoad) return sorted;
    return sorted.take(_maxSessionsPerListDetailLoad).toList();
  }

  /// Student roster ids currently in [AttendanceStore] (for sign-in listeners).
  Set<String> studentIdsForCurrentUserInStore() {
    return studentIdsForRecordWatch();
  }

  /// Registration number for RTD paths (`by_student/{registration}/…`).
  String? studentRegistrationForRtdWatch() =>
      _normalizedStudentRegistrationForWatch();

  /// Ids for Firestore `studentId` queries — always includes registration
  /// (canonical in attendance rows / RTD) plus legacy roster doc ids.
  Set<String> studentIdsForRecordWatch() {
    final reg = _normalizedStudentRegistrationForWatch();
    if (reg == null || reg.isEmpty) return const {};
    final key = reg.trim().toUpperCase();
    final out = <String>{key};
    for (final s in AttendanceStore.students) {
      if (s.registrationNumber.trim().toUpperCase() != key) continue;
      final id = s.id.trim();
      if (id.isNotEmpty) out.add(id);
    }
    final student = AttendanceStore.findStudentByReg(reg);
    final id = student?.id.trim() ?? '';
    if (id.isNotEmpty) out.add(id);
    return out;
  }

  String? _normalizedStudentRegistrationForWatch() {
    final fromScope = currentStudentLoadRegistration();
    if (fromScope != null && fromScope.isNotEmpty) return fromScope;
    if (!_likelyStudentBeforeRoleCheck() &&
        !AuthRepository.instance.isStudentAuthIdentity) {
      return null;
    }
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) return null;
    return StudentRegistrationNumber.normalize(reg);
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
    var purged = false;

    final localIds = AttendanceStore.lists.map((l) => l.id).toSet();
    final orphanLists = localIds.difference(authoritativeIds);
    if (orphanLists.isNotEmpty) {
      purged = await purgeListsRemovedFromRemote(orphanLists) || purged;
    }

    final signInListIds = <String>{
      for (final s in AttendanceStore.signIns)
        if (s.listId.trim().isNotEmpty) s.listId.trim(),
    };
    final orphanSignIns = signInListIds.difference(authoritativeIds);
    for (final id in orphanSignIns) {
      if (await _listDocConfirmedMissingOnServer(id)) {
        await _purgeListLocally(id);
        purged = true;
      }
    }

    if (purged) {
      unawaited(_persistScopedLocalSnapshot());
      _notifyStoreUpdated();
    }
    return purged;
  }

  String _signInDedupKey(SignInRecord r) =>
      '${r.listId}|${r.studentId}|${r.course}';

  /// List IDs kept locally while enrollment or check-in is still in flight.
  Future<Set<String>> _localEnrollmentListIds() async {
    final ids = <String>{..._listsPublishedOnServer};
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
    for (final e in await PendingSessionCreateQueue.loadAll()) {
      final id = e.listId.trim();
      if (id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  /// Clears in-memory attendance after sign-out so the next user does not see stale data.
  void resetForSignOut() {
    _notifyDebounce?.cancel();
    _notifyDebounce = null;
    _notifyFlushScheduled = false;
    _persistDebounce?.cancel();
    _persistScheduled = false;
    unawaited(AttendanceRemoteListWatch.instance.stop());
    unawaited(AttendanceRemoteRecordWatch.instance.stop());
    unawaited(AttendanceRtdRecordWatch.instance.stop());
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
    AttendanceStore.clearSessionRollStats();
    AttendanceStore.clearStudentRollStats();
    AttendanceStore.clearStudentListRollStats();
    AttendanceStore.invalidateLookupCaches();
    _isLoaded = false;
    _loadScopeLecturerUid = null;
    _lecturerScopeIncludesSessions = false;
    _loadScopeStudentReg = null;
    _usingLocalSnapshot = false;
    _localSnapshotSyncedAt = null;
    _listsCatalogFetchedAt = null;
    _loadedListDetailIds.clear();
    _listDetailFetchedAt.clear();
    _recentListDetailIds.clear();
    _listDetailLoads.clear();
    _listDetailQueue.clear();
    _activeListDetailLoads = 0;
    _listDetailMergeLock = Future<void>.value();
    _batchListDetailInFlight = null;
    _remoteSyncInFlight = null;
    _staffFullBootstrapDone = false;
    _notifyStoreUpdated(immediate: true);
  }

  /// List ids whose sessions/records/sign-ins have been fetched (or restored).
  final Set<String> _loadedListDetailIds = {};
  final Map<String, Future<void>> _listDetailLoads = {};
  final List<String> _recentListDetailIds = [];
  static const int _maxRecentListDetailIds = 8;
  final Map<String, DateTime> _listDetailFetchedAt = {};
  DateTime? _listsCatalogFetchedAt;
  static const int _maxConcurrentListDetailLoads = 4;
  static const int _maxPrefetchListDetailLoads = 6;
  static const int _maxBatchListDetailLoads = 16;
  static const int _maxSessionsPerListDetailLoad = 30;
  int _activeListDetailLoads = 0;
  Future<void> _listDetailMergeLock = Future<void>.value();
  Future<void>? _batchListDetailInFlight;
  final List<({String id, bool force, Completer<void> completer})>
      _listDetailQueue = [];

  /// True when sessions, sign-ins, or records for [listId] are in the store.
  bool listDetailReady(String listId) {
    final id = listId.trim();
    if (id.isEmpty) return false;
    if (_loadedListDetailIds.contains(id)) return true;
    return hasLocalListData(id);
  }

  /// Rows for [listId] already in memory (snapshot or prior fetch) — paint without waiting.
  bool hasLocalListData(String listId) {
    final id = listId.trim();
    if (id.isEmpty) return false;
    return AttendanceStore.sessions.any((s) => s.listId == id) ||
        AttendanceStore.signIns.any((si) => si.listId == id) ||
        AttendanceStore.attendanceRecords.any(
          (r) => AttendanceStore.sessionById(r.sessionId)?.listId == id,
        );
  }

  /// Blocking skeleton only while a network fetch runs and there is nothing local to show.
  bool listDetailShowsSkeleton(String listId) {
    final id = listId.trim();
    if (id.isEmpty) return false;
    if (hasLocalListData(id)) return false;
    return _listDetailLoads.containsKey(id);
  }

  bool _listsCatalogCacheFresh() => SmartCachePolicy.isWithinTtl(
        _listsCatalogFetchedAt,
        SmartCachePolicy.profileAndNoticesTtl,
      );

  void _markListsCatalogFetched() {
    _listsCatalogFetchedAt = DateTime.now().toUtc();
  }

  /// Attendance list detail (sessions, records, course names) is fetch-once.
  bool _listDetailIsStale(String listId) {
    final id = listId.trim();
    if (id.isEmpty) return true;
    return !_loadedListDetailIds.contains(id) && !listDetailReady(id);
  }

  /// True when sign-ins/records reference list ids not yet in [AttendanceStore.lists].
  bool _studentProfileHasMissingListMetadata(String reg) {
    final enrolled =
        AttendanceStore.enrolledListIdsForRegistrationNormalized(reg);
    return enrolled.any((id) => AttendanceStore.listById(id) == null);
  }

  /// Fetches list metadata for enrolled classes missing from the local store.
  Future<bool> _ensureStudentEnrolledListMetadataLoaded({
    String? reg,
    bool force = false,
  }) async {
    final normalizedReg = reg ?? _normalizedStudentRegistrationForCache();
    if (normalizedReg == null || normalizedReg.isEmpty) return false;

    final enrolled =
        AttendanceStore.enrolledListIdsForRegistrationNormalized(normalizedReg);
    final missing = enrolled
        .where((id) => AttendanceStore.listById(id) == null)
        .toSet();
    if (missing.isEmpty) return false;
    if (!AppConnectivity.instance.isOnline && !force) return false;

    var changed = false;
    final fetched = await _fetchListsByIds(missing, force: force || true);
    for (final list in fetched) {
      if (AttendanceStore.listById(list.id) == null) {
        AttendanceStore.addList(list);
        changed = true;
      }
    }

    for (final id in missing) {
      if (AttendanceStore.listById(id) != null) continue;
      await _ensureListLoaded(id);
      if (AttendanceStore.listById(id) != null) changed = true;
    }

    if (changed) {
      AttendanceStore.invalidateLookupCaches();
      _schedulePersistScopedLocalSnapshot();
      _notifyStoreUpdated();
    }
    return changed;
  }

  /// True when a list document is confirmed absent (not merely unreachable).
  Future<bool> _listDocConfirmedMissingOnServer(String listId) async {
    if (_firestoreIfReady == null) return false;
    final id = listId.trim();
    if (id.isEmpty) return false;
    try {
      final doc = await _firestore
          .collection(ApiCollections.attendanceLists)
          .doc(id)
          .get(_loadQueryOptions(force: true));
      return !doc.exists;
    } catch (_) {
      return false;
    }
  }

  /// Student lists present in the store but never detail-fetched from server.
  Future<void> _fetchNeverLoadedStudentListDetails() async {
    final reg = _normalizedStudentRegistrationForCache();
    if (reg == null || reg.isEmpty) return;
    await _ensureStudentEnrolledListMetadataLoaded(reg: reg);

    final enrolled =
        AttendanceStore.enrolledListIdsForRegistrationNormalized(reg);
    final listIds = enrolled
        .where((id) => id.isNotEmpty && _listDetailIsStale(id))
        .toList();
    if (listIds.isEmpty) return;
    await loadListAttendanceDataBatch(listIds);
    _schedulePersistScopedLocalSnapshot();
  }

  /// Whether cached list detail should be refreshed from Firestore.
  bool listDetailIsStale(String listId) => _listDetailIsStale(listId);

  void _ensureListDetailMarkedFromStore(String listId) {
    if (!hasLocalListData(listId)) return;
    _loadedListDetailIds.add(listId);
    _listDetailFetchedAt.putIfAbsent(
      listId,
      () => _localSnapshotSyncedAt ?? DateTime.now(),
    );
  }

  void _scheduleBackgroundListDetailRefresh(String listId, {bool force = false}) {
    if (!AppConnectivity.instance.isOnline) return;
    if (!force && !_listDetailIsStale(listId)) return;
    if (_listDetailLoads.containsKey(listId)) return;
    unawaited(loadListAttendanceData(listId, force: force || _listDetailIsStale(listId)));
  }

  void _markAllStoreListsDetailLoaded() {
    _loadedListDetailIds.addAll(AttendanceStore.lists.map((l) => l.id));
  }

  void _markListDetailsReadyFromStore() {
    final syncedAt = _localSnapshotSyncedAt ?? DateTime.now();
    for (final list in AttendanceStore.lists) {
      final id = list.id.trim();
      if (id.isEmpty) continue;
      if (!listDetailReady(id)) continue;
      _loadedListDetailIds.add(id);
      _listDetailFetchedAt.putIfAbsent(id, () => syncedAt);
    }
  }

  List<String> _priorityListDetailIds({int max = _maxBatchListDetailLoads}) {
    final ordered = <String>[];
    final seen = <String>{};

    void add(String raw, {bool front = false}) {
      final id = raw.trim();
      if (id.isEmpty || !seen.add(id)) return;
      if (front) {
        ordered.insert(0, id);
      } else {
        ordered.add(id);
      }
    }

    for (final s in AttendanceStore.sessions) {
      if (s.isActive) add(s.listId, front: true);
    }
    for (final list in AttendanceStore.lists) {
      if (list.status == AttendanceListStatus.active) add(list.id, front: true);
    }
    final today = DateTime.now();
    for (final list in AttendanceStore.lists) {
      if (!AttendanceScheduleUtils.isListScheduledOnDate(list, today)) continue;
      add(list.id);
    }
    for (final id in _recentListDetailIds.reversed) {
      add(id, front: true);
    }
    for (final list in AttendanceStore.lists) {
      add(list.id);
    }
    if (ordered.length <= max) return ordered;
    return ordered.take(max).toList();
  }

  /// Loads active, due-today, and recent lists from Firestore when not on disk.
  void prefetchActiveListDetails() {
    if (!AppConnectivity.instance.isOnline) return;
    if (AuthRepository.instance.needsEmailVerification) return;
    final ids = _priorityListDetailIds()
        .where((id) => !listDetailReady(id))
        .toList();
    if (ids.isEmpty) return;
    prefetchListAttendanceDataBatch(ids);
  }

  /// Loads sessions, sign-ins, records, and roster students for one list.
  ///
  /// Returns as soon as a local snapshot is restored; network refresh continues
  /// in the background when disk already has rows for [listId].
  Future<void> loadListAttendanceData(String listId, {bool force = false}) async {
    final id = listId.trim();
    if (id.isEmpty) return;
    await warmFromLocalSnapshot();
    _touchRecentListDetail(id);
    unawaited(AttendanceRtdRecordWatch.instance.start());
    if (!isStudentRecordWatchUser()) {
      unawaited(AttendanceRemoteRecordWatch.instance.start());
    }
    if (isStudentRecordWatchUser()) {
      unawaited(refreshStudentListAttendanceFromRtd(id));
    }

    if (!force && hasLocalListData(id)) {
      _ensureListDetailMarkedFromStore(id);
      _scheduleBackgroundListDetailRefresh(id);
      return;
    }

    if (force) {
      _loadedListDetailIds.remove(id);
      _listDetailFetchedAt.remove(id);
    } else if (_loadedListDetailIds.contains(id)) {
      if (!_listDetailIsStale(id) || !AppConnectivity.instance.isOnline) {
        return;
      }
      force = true;
      _loadedListDetailIds.remove(id);
    }
    final inFlight = _listDetailLoads[id];
    if (inFlight != null && !force) return inFlight;

    final completer = Completer<void>();
    final safe = completer.future.catchError((Object? _, StackTrace? __) {});
    _listDetailLoads[id] = safe.whenComplete(() {
      _listDetailLoads.remove(id);
    });
    _enqueueListDetailLoad(id: id, force: force, completer: completer);
    return safe;
  }

  void _enqueueListDetailLoad({
    required String id,
    required bool force,
    required Completer<void> completer,
  }) {
    if (force) {
      _listDetailQueue.removeWhere((job) => job.id == id);
    }
    final job = (id: id, force: force, completer: completer);
    final prioritize = force ||
        (_recentListDetailIds.isNotEmpty && _recentListDetailIds.last == id);
    if (prioritize) {
      _listDetailQueue.insert(0, job);
    } else {
      _listDetailQueue.add(job);
    }
    _drainListDetailQueue();
  }

  void _drainListDetailQueue() {
    while (_activeListDetailLoads < _maxConcurrentListDetailLoads &&
        _listDetailQueue.isNotEmpty) {
      final job = _listDetailQueue.removeAt(0);
      if (job.completer.isCompleted) continue;
      _activeListDetailLoads++;
      unawaited(
        _runListDetailJob(job.id, force: job.force)
            .then(job.completer.complete, onError: job.completer.completeError)
            .whenComplete(() {
          _activeListDetailLoads--;
          _drainListDetailQueue();
        }),
      );
    }
  }

  Future<void> _runListDetailJob(String listId, {required bool force}) async {
    await warmFromLocalSnapshot();
    if (!force && listDetailReady(listId)) {
      _loadedListDetailIds.add(listId);
      return;
    }
    await _awaitListMetadataIfNeeded(listId);
    await _executeLoadListDetail(listId, force: force).timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        throw TimeoutException(
          'List detail load timed out',
          const Duration(seconds: 15),
        );
      },
    );
  }

  Future<void> _awaitListMetadataIfNeeded(String listId) async {
    if (AttendanceStore.listById(listId) != null) return;
    final resolved = await resolveListById(listId);
    if (resolved != null) return;
    try {
      await _loadAllSerialized
          .timeout(const Duration(seconds: 6))
          .catchError((Object? _, StackTrace? __) {});
    } catch (_) {}
    if (AttendanceStore.listById(listId) == null) {
      await _ensureListLoaded(listId);
    }
  }

  Future<void> _serializedListDetailMerge(Future<void> Function() merge) async {
    final run = _listDetailMergeLock.then((_) => merge());
    final safe = run.catchError((Object? _, StackTrace? __) {});
    _listDetailMergeLock = safe;
    await safe;
  }

  /// Fire-and-forget per-list detail loads (e.g. when a program page opens).
  void prefetchListAttendanceData(Iterable<String> listIds) {
    prefetchListAttendanceDataBatch(listIds, maxLists: _maxPrefetchListDetailLoads);
  }

  /// Batch-fetch detail for many lists in one round of Firestore queries.
  void prefetchListAttendanceDataBatch(
    Iterable<String> listIds, {
    int maxLists = _maxBatchListDetailLoads,
  }) {
    final seen = <String>{};
    final ordered = <String>[];
    for (final id in [
      ..._recentListDetailIds.reversed,
      ...listIds,
    ]) {
      final trimmed = id.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      ordered.add(trimmed);
      if (ordered.length >= maxLists) break;
    }
    if (ordered.isEmpty) return;
    unawaited(loadListAttendanceDataBatch(ordered));
  }

  Future<void> loadListAttendanceDataBatch(
    Iterable<String> listIds, {
    bool force = false,
  }) async {
    await warmFromLocalSnapshot();
    final ids = <String>[];
    final seen = <String>{};
    for (final raw in listIds) {
      final id = raw.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      if (!force && (_loadedListDetailIds.contains(id) || listDetailReady(id))) {
        continue;
      }
      ids.add(id);
      _touchRecentListDetail(id);
    }
    if (ids.isEmpty) return;

    final run = (_batchListDetailInFlight ?? Future<void>.value()).then(
      (_) => _executeBatchLoadListDetails(ids, force: force),
    );
    final safe = run.catchError((Object? _, StackTrace? __) {});
    _batchListDetailInFlight = safe;
    await safe;
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

  /// True when the session is on the server (Firestore and/or RTD), not only local / queued.
  Future<bool> isLecturerSessionPublishedOnServer(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) return false;
    if (!AppConnectivity.instance.hasNetworkInterface) return false;

    final cacheFresh = _sessionPublishedCacheAt != null &&
        DateTime.now().difference(_sessionPublishedCacheAt!) <
            _sessionPublishedCacheTtl;
    if (cacheFresh && _sessionPublishedOnServerCache.containsKey(id)) {
      return _sessionPublishedOnServerCache[id]!;
    }

    final exists = await _lecturerSessionDocExistsOnServer(id);
    _sessionPublishedOnServerCache[id] = exists;
    _sessionPublishedCacheAt = DateTime.now();
    if (exists) {
      unawaited(PendingSessionCreateQueue.removeBySessionId(id));
      _invalidateAwaitingUploadCache();
    }
    return exists;
  }

  /// True when upload should use an `await_{code}` claim (lecturer session not on
  /// server). False when the session is already known locally — use
  /// [PendingCheckInQueue] and a direct [check_in_attempts] write on reconnect.
  Future<bool> _shouldUseAwaitingSessionClaimPath(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) return true;

    final awaitingUpload = await _sessionIdsAwaitingUpload();
    if (awaitingUpload.contains(id)) return true;

    final localSession = AttendanceStore.sessionById(id);
    if (localSession == null) {
      if (!AppConnectivity.instance.hasNetworkInterface) return true;
      return !await isLecturerSessionPublishedOnServer(id);
    }

    // Offline with a cached session that is not waiting on lecturer upload:
    // queue a direct check-in attempt, not a session-code claim.
    if (!AppConnectivity.instance.hasNetworkInterface) {
      return false;
    }

    return !await isLecturerSessionPublishedOnServer(id);
  }

  Future<void> _enqueuePendingCheckInRow({
    required AttendanceRecord localRow,
    required String listId,
    required String course,
    PendingCheckInQueueStatus status = PendingCheckInQueueStatus.queued,
  }) async {
    await _upsertPendingCheckInFromRecord(
      record: localRow,
      listId: listId,
      course: course,
      status: status,
    );
  }

  /// Ensures every check-in appears on the Check-ins screen for 7-day retention.
  Future<void> _upsertPendingCheckInFromRecord({
    required AttendanceRecord record,
    required String listId,
    required String course,
    PendingCheckInQueueStatus status = PendingCheckInQueueStatus.queued,
    String? sessionCodeRaw,
  }) async {
    final all = await PendingCheckInQueue.loadAll();
    PendingCheckInEntry? existing;
    for (final e in all) {
      if (e.id == record.id) {
        existing = e;
        break;
      }
    }
    var resolvedStatus = status;
    if (status == PendingCheckInQueueStatus.queued &&
        existing?.status == PendingCheckInQueueStatus.approved) {
      resolvedStatus = PendingCheckInQueueStatus.approved;
    }
    final code = sessionCodeRaw?.trim().isNotEmpty == true
        ? normalizeSessionCodeInput(sessionCodeRaw!.trim())
        : existing?.sessionCodeRaw;
    await PendingCheckInQueue.enqueue(
      PendingCheckInEntry(
        id: record.id,
        sessionId: record.sessionId,
        studentId: record.studentId,
        listId: listId,
        course: course,
        capturedAt: record.timestamp,
        latitude: record.latitude,
        longitude: record.longitude,
        deviceId: record.deviceId?.trim() ?? '',
        pendingSince: existing?.pendingSince ?? record.timestamp,
        status: resolvedStatus,
        sessionCodeRaw: code,
        uploadedAt: existing?.uploadedAt,
      ),
    );
  }

  Future<void> _ensureCheckInListedInQueue({
    required AttendanceRecord record,
    String? listIdOverride,
    required String course,
    PendingCheckInQueueStatus? status,
    String? sessionCodeRaw,
  }) async {
    if (!record.present) return;
    final session = AttendanceStore.sessionById(record.sessionId);
    final listId = (listIdOverride?.trim().isNotEmpty == true
            ? listIdOverride!.trim()
            : null) ??
        session?.listId ??
        '';
    final code = sessionCodeRaw?.trim().isNotEmpty == true
        ? normalizeSessionCodeInput(sessionCodeRaw!.trim())
        : (session != null
            ? normalizeSessionCodeInput(session.sessionCode)
            : null);
    var resolvedStatus = status;
    if (resolvedStatus == null && AppConnectivity.instance.hasNetworkInterface) {
      final entry = PendingCheckInEntry(
        id: record.id,
        sessionId: record.sessionId,
        studentId: record.studentId,
        listId: listId,
        course: course,
        capturedAt: record.timestamp,
        latitude: record.latitude,
        longitude: record.longitude,
        deviceId: record.deviceId?.trim() ?? '',
        sessionCodeRaw: code,
      );
      final approved = await pendingCheckInIsApproved(
        entry: entry,
        session: session,
      );
      resolvedStatus = approved
          ? PendingCheckInQueueStatus.approved
          : PendingCheckInQueueStatus.queued;
    } else {
      resolvedStatus ??= record.verified
          ? PendingCheckInQueueStatus.approved
          : PendingCheckInQueueStatus.queued;
    }
    await _upsertPendingCheckInFromRecord(
      record: record,
      listId: listId,
      course: course,
      status: resolvedStatus,
      sessionCodeRaw: code,
    );
  }

  Future<void> _upsertPendingSessionCodeEntry(
    PendingSessionCodeEntry entry, {
    PendingSessionCodeStatus? status,
  }) async {
    final all = await PendingSessionCodeQueue.loadAll();
    PendingSessionCodeEntry? existing;
    for (final e in all) {
      if (e.id == entry.id) {
        existing = e;
        break;
      }
    }
    await PendingSessionCodeQueue.enqueue(
      entry.copyWith(
        status: status ?? entry.status,
        pendingSince: existing?.pendingSince ?? entry.pendingSince,
        uploadedAt: existing?.uploadedAt ?? entry.uploadedAt,
      ),
    );
  }

  /// Backfills present local rows missing from the Check-ins queue (7-day retention).
  Future<void> recoverUnqueuedLocalPresentCheckIns({bool resolveOnline = true}) async {
    if (!isStudentScopedUser() && !isStudentRecordWatchUser()) return;
    final now = DateTime.now();
    final queued = await PendingCheckInQueue.loadAll();
    final queuedIds = queued.map((e) => e.id.trim()).toSet();
    for (final row in AttendanceStore.attendanceRecords) {
      if (!row.present) continue;
      if (!PendingRetention.isWithinRetention(row.timestamp, now)) continue;
      if (row.deviceId?.trim().isEmpty ?? true) continue;
      if (queuedIds.contains(row.id.trim())) continue;
      if (await PendingCheckInQueue.containsRecordId(row.id)) continue;
      final session = AttendanceStore.sessionById(row.sessionId);
      final listId = session?.listId ?? '';
      final sessionCode = session != null
          ? normalizeSessionCodeInput(session.sessionCode)
          : null;
      var approved = false;
      if (resolveOnline && row.verified) {
        approved = await pendingCheckInIsApproved(
          entry: PendingCheckInEntry(
            id: row.id,
            sessionId: row.sessionId,
            studentId: row.studentId,
            listId: listId,
            course: row.course,
            capturedAt: row.timestamp,
            latitude: row.latitude,
            longitude: row.longitude,
            deviceId: row.deviceId?.trim() ?? '',
            sessionCodeRaw: sessionCode,
          ),
          session: session,
        );
      } else if (row.verified) {
        approved = true;
      }
      await _upsertPendingCheckInFromRecord(
        record: row,
        listId: listId,
        course: row.course.trim().isNotEmpty
            ? row.course
            : _resolvePresentCourseForSession(
                row.sessionId,
                row.studentId,
                row.course,
              ),
        status: approved
            ? PendingCheckInQueueStatus.approved
            : PendingCheckInQueueStatus.queued,
        sessionCodeRaw: sessionCode,
      );
      queuedIds.add(row.id.trim());
    }
  }

  void _invalidateSessionPublishedCache([String? sessionId]) {
    if (sessionId != null) {
      _sessionPublishedOnServerCache.remove(sessionId.trim());
    } else {
      _sessionPublishedOnServerCache.clear();
    }
    _sessionPublishedCacheAt = null;
    _invalidateAwaitingUploadCache();
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
    if (offlineQueuedSessionCodeTrustsPresent(
      entry: entry,
      session: session,
      studentRegistrationNumber: studentRegistrationNumber,
    )) {
      return true;
    }
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
        pendingReplayLocationOk(session, entry.latitude, entry.longitude);
  }

  /// Like [pendingSessionCodeMatchesSession] — uses the same replay GPS rules.
  static bool pendingSessionCodeMatchesSessionForCorrection({
    required PendingSessionCodeEntry entry,
    required AttendanceSession session,
    required String studentRegistrationNumber,
  }) {
    return pendingSessionCodeMatchesSession(
      entry: entry,
      session: session,
      studentRegistrationNumber: studentRegistrationNumber,
    );
  }

  /// True when queued check-in evidence matches [session] + list scope.
  static bool pendingCheckInMatchesSession(
    PendingCheckInEntry entry,
    AttendanceSession session,
  ) {
    if (entry.sessionId.trim() != session.id) return false;
    if (offlineOrMetadataQueuedCheckInTrustsPresent(entry, session)) {
      return true;
    }
    if (entry.listId.isNotEmpty && entry.listId != session.listId) {
      return false;
    }
    return isTimestampWithinSessionBounds(session, entry.capturedAt) &&
        isPositionWithinSession(session, entry.latitude, entry.longitude);
  }

  static bool pendingCheckInMatchesSessionForCorrection(
    PendingCheckInEntry entry,
    AttendanceSession session,
  ) =>
      offlineOrMetadataQueuedCheckInTrustsPresent(entry, session);

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
      _schedulePersistScopedLocalSnapshot();
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
              .collection(ApiCollections.checkInAttempts)
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
          .collection(ApiCollections.checkInAttempts)
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
    // Cross-student device checks are local-store only; server reconciles on upload.
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
      if (existing.present && existing.verified) return;
      AttendanceStore.updateAttendanceRecord(localRow);
    } else if (!AttendanceStore.addAttendanceRecordIfAbsent(localRow)) {
      final prior = AttendanceStore.attendanceRecordForSessionStudent(
        sessionId,
        studentId,
      );
      if (prior != null && prior.present && prior.verified) return;
      AttendanceStore.updateAttendanceRecord(localRow);
    }
    AttendanceStore.invalidateLookupCaches();
    _invalidateRollStatsAfterRecordMerge(localRow);
    _notifyStoreUpdated(immediate: true);
    _schedulePersistScopedLocalSnapshot();
    final session = AttendanceStore.sessionById(sessionId);
    watchCheckInAttemptForStudent(
      recordId: localRow.id,
      sessionId: sessionId,
      studentId: studentId,
      sessionCodeRaw: session?.sessionCode,
    );
    unawaited(AttendanceRemoteRecordWatch.instance.start());
    unawaited(AttendanceRtdRecordWatch.instance.start());
  }

  Future<void> _replaceStoreFromRemote({
    required List<AttendanceList> remoteLists,
    required List<AttendanceSession> remoteSessions,
    required List<AttendanceRecord> remoteRecords,
    required List<StudentRecord> remoteStudents,
    required List<SignInRecord> remoteSignIns,
    bool rosterAlreadyAugmented = false,
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
      for (final e in pendingListCreates) e.list.id,
      for (final s in remoteSessions) s.listId,
      for (final s in remoteSignIns) s.listId,
      for (final e in pendingCheckIns)
        if (e.listId.trim().isNotEmpty) e.listId.trim(),
      for (final e in pendingCodes)
        if ((e.listId?.trim() ?? '').isNotEmpty) e.listId!.trim(),
      for (final e in pendingCreates)
        if (e.listId.trim().isNotEmpty) e.listId.trim(),
    };
    final protectedListIds = <String>{
      for (final l in remoteLists) l.id,
      for (final e in pendingListCreates) e.list.id,
      for (final e in pendingCheckIns)
        if (e.listId.trim().isNotEmpty) e.listId.trim(),
      for (final e in pendingCodes)
        if ((e.listId?.trim() ?? '').isNotEmpty) e.listId!.trim(),
      for (final e in pendingCreates)
        if (e.listId.trim().isNotEmpty) e.listId.trim(),
    };
    for (final l in priorLists) {
      if (!protectedListIds.contains(l.id)) {
        await _purgeListLocally(l.id);
      }
    }

    final filteredRemoteSessions = remoteSessions
        .where((s) => protectedListIds.contains(s.listId))
        .toList();
    final filteredRemoteSignIns = remoteSignIns
        .where((s) => protectedListIds.contains(s.listId))
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
            protectedListIds.contains(s.listId))
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
      pendingCheckIns = [
        for (final e in pendingCheckIns)
          rejectedIds.contains(e.id)
              ? e.copyWith(status: PendingCheckInQueueStatus.queued)
              : e,
      ];
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
    final mergedStudents = rosterAlreadyAugmented
        ? List<StudentRecord>.from(studentsById.values)
        : await _augmentRosterStudents(
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

  /// Writes absent rows for ended sessions when each student's grace has elapsed
  /// (7-day cap or a later session resolved on the same list).
  Future<void> finalizeGraceExpiredSessions() async {
    for (final s in AttendanceStore.sessions) {
      if (!s.countsTowardRollStats) continue;
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
  }) async {
    if (AuthRepository.instance.needsEmailVerification) return;
    await warmFromLocalSnapshot();

    final background = !force && hasCachedStore;
    final run = _loadAllSerialized.then(
      (_) => _executeLoadAll(force, scopeToLecturerUid, listsOnly: listsOnly),
    );
    final safe = run.catchError((Object? _, StackTrace? __) {});
    _loadAllSerialized = safe;
    if (background) {
      unawaited(safe);
      return;
    }
    await safe;
  }

  /// QA/admin sees every list; lecturers and KIU admins are uid-scoped.
  bool _usesFullStaffListLoad() {
    final auth = AuthRepository.instance;
    return auth.adminCheckDone && auth.isAdmin;
  }

  /// Scope for fast list-only refresh; null means load the full staff collection.
  String? _listsOnlyScopeUid({String? explicitScope}) {
    if (_usesFullStaffListLoad()) return null;
    final trimmed = explicitScope?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return currentLecturerLoadScopeUid();
  }

  /// Fast list refresh for lecturer / QA attendance hub.
  Future<void> refreshAttendanceLists({bool force = true}) => loadAll(
        force: force,
        listsOnly: true,
        scopeToLecturerUid: _listsOnlyScopeUid(),
      );

  Future<void> _executeLoadListDetail(String listId, {required bool force}) async {
    final loadGeneration = _loadGeneration;
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (_firestoreIfReady == null) return;
    if (!force && _loadedListDetailIds.contains(listId)) return;

    await warmFromLocalSnapshot();
    if (!force && listDetailReady(listId)) {
      _loadedListDetailIds.add(listId);
      return;
    }

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
              _firestore.collection(ApiCollections.attendanceSessions),
          field: 'listId',
          values: [listId],
          options: queryOptions,
        ),
        _queryDocsWhereFieldEquals(
          collection: _firestore.collection(ApiCollections.signIns),
          field: 'listId',
          values: [listId],
          options: queryOptions,
        ),
      ]);
      if (!_loadsAllowedForSession(loadGeneration)) return;

      final sessions = _limitSessionsForListDetail(
        sessionAndSignInDocs[0]
            .map(_trySessionFromDoc)
            .whereType<AttendanceSession>(),
      );
      var mergedSessions = List<AttendanceSession>.from(sessions);
      try {
        for (final session in await SessionRtdSync.fetchByListId(listId)) {
          final i = mergedSessions.indexWhere((s) => s.id == session.id);
          if (i >= 0) {
            mergedSessions[i] = session;
          } else {
            mergedSessions.add(session);
          }
        }
        mergedSessions = _limitSessionsForListDetail(mergedSessions);
      } catch (_) {}
      var signIns = sessionAndSignInDocs[1]
          .map(_trySignInFromDoc)
          .whereType<SignInRecord>()
          .toList();
      final sessionIds = mergedSessions.map((s) => s.id).toList();

      final scopedStudentIds = _scopedStudentIdsForListDetail();
      if (scopedStudentIds != null && scopedStudentIds.isNotEmpty) {
        signIns = signIns
            .where((s) => scopedStudentIds.contains(s.studentId))
            .toList();
        if (isStudentRecordWatchUser()) {
          unawaited(refreshStudentListAttendanceFromRtd(listId));
        }
      }

      await _publishListDetailEarlyProgress(
        listId: listId,
        listSessions: mergedSessions,
        listSignIns: signIns,
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;
      final namesRefresh = _refreshRosterNamesForList(
        listId: listId,
        listSessions: mergedSessions,
        listSignIns: signIns,
      );

      final records = await _fetchAttendanceRecordsForDetailLoad(
        sessionIds: sessionIds,
        scopedStudentIds: scopedStudentIds,
        queryOptions: queryOptions,
      );
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
        extraStudentIds: records.map((r) => r.studentId),
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;
      await namesRefresh.catchError((_) {});

      await _serializedListDetailMerge(
        () => _mergeListDetailIntoStore(
          listId: listId,
          listSessions: mergedSessions,
          listSignIns: signIns,
          listRecords: records,
          listStudents: rosterStudents,
          rosterAlreadyAugmented: true,
        ),
      );
      _loadedListDetailIds.add(listId);
      _listDetailFetchedAt[listId] = DateTime.now();
      await _finalizeExpiredOpenSessions();
      _schedulePersistScopedLocalSnapshot();
      unawaited(AttendanceRemoteRecordWatch.instance.start());
    unawaited(AttendanceRtdRecordWatch.instance.start());
      _notifyStoreUpdated(refreshRecordWatch: true);
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

  Future<void> _executeBatchLoadListDetails(
    List<String> listIds, {
    required bool force,
  }) async {
    final loadGeneration = _loadGeneration;
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (_firestoreIfReady == null) return;
    if (listIds.isEmpty) return;

    if (listIds.isEmpty) return;

    await warmFromLocalSnapshot();
    for (final raw in listIds) {
      if (AttendanceStore.listById(raw) != null) continue;
      await _ensureListLoaded(raw);
    }

    var targetListIds = listIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && AttendanceStore.listById(id) != null)
        .toSet();
    if (!force) {
      targetListIds = targetListIds
          .where((id) => !listDetailReady(id))
          .toSet();
    }
    if (targetListIds.isEmpty) return;
    if (targetListIds.isEmpty) return;

    final online = AppConnectivity.instance.isOnline;
    if (!online && !force) {
      for (final id in targetListIds) {
        if (listDetailReady(id)) _loadedListDetailIds.add(id);
      }
      return;
    }

    try {
      final queryOptions = _loadQueryOptions(force: force);
      final sessionAndSignInDocs = await Future.wait([
        _queryDocsWhereFieldEquals(
          collection:
              _firestore.collection(ApiCollections.attendanceSessions),
          field: 'listId',
          values: targetListIds.toList(),
          options: queryOptions,
        ),
        _queryDocsWhereFieldEquals(
          collection: _firestore.collection(ApiCollections.signIns),
          field: 'listId',
          values: targetListIds.toList(),
          options: queryOptions,
        ),
      ]);
      if (!_loadsAllowedForSession(loadGeneration)) return;

      var allSessions = _limitSessionsForListDetail(
        sessionAndSignInDocs[0]
            .map(_trySessionFromDoc)
            .whereType<AttendanceSession>()
            .where((s) => targetListIds.contains(s.listId)),
      );
      for (final listId in targetListIds) {
        final rtdRunning = await SessionRtdSync.fetchByListId(listId);
        for (final session in rtdRunning) {
          final i = allSessions.indexWhere((s) => s.id == session.id);
          if (i >= 0) {
            allSessions[i] = session;
          } else {
            allSessions.add(session);
          }
        }
      }
      allSessions = _limitSessionsForListDetail(allSessions);
      var allSignIns = sessionAndSignInDocs[1]
          .map(_trySignInFromDoc)
          .whereType<SignInRecord>()
          .where((s) => targetListIds.contains(s.listId))
          .toList();

      final scopedStudentIds = _scopedStudentIdsForListDetail();
      if (scopedStudentIds != null && scopedStudentIds.isNotEmpty) {
        allSignIns = allSignIns
            .where((s) => scopedStudentIds.contains(s.studentId))
            .toList();
      }

      for (final listId in targetListIds) {
        await _publishListDetailEarlyProgress(
          listId: listId,
          listSessions:
              allSessions.where((s) => s.listId == listId).toList(),
          listSignIns: allSignIns.where((si) => si.listId == listId).toList(),
        );
      }
      if (!_loadsAllowedForSession(loadGeneration)) return;

      final sessionIds = allSessions.map((s) => s.id).toList();
      final allRecords = await _fetchAttendanceRecordsForDetailLoad(
        sessionIds: sessionIds,
        scopedStudentIds: scopedStudentIds,
        queryOptions: queryOptions,
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;

      final studentIds = scopedStudentIds ??
          _studentIdsFromRoster(
            signIns: allSignIns,
            records: allRecords,
          );
      final regByStudentId = _regByStudentIdFromSignIns(allSignIns);
      final students = await _fetchStudentsByIds(
        studentIds,
        force: force,
        regByStudentId: regByStudentId,
      );
      final rosterStudents = await _augmentRosterStudents(
        signIns: allSignIns,
        fetched: students,
        extraStudentIds: allRecords.map((r) => r.studentId),
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;

      await _serializedListDetailMerge(
        () => _mergeBatchListDetailsIntoStore(
          targetListIds: targetListIds,
          batchSessions: allSessions,
          batchSignIns: allSignIns,
          batchRecords: allRecords,
          batchStudents: rosterStudents,
          rosterAlreadyAugmented: true,
        ),
      );

      final fetchedAt = DateTime.now();
      for (final id in targetListIds) {
        _loadedListDetailIds.add(id);
        _listDetailFetchedAt[id] = fetchedAt;
      }
      await _finalizeExpiredOpenSessions();
      _schedulePersistScopedLocalSnapshot();
      unawaited(AttendanceRemoteRecordWatch.instance.start());
    unawaited(AttendanceRtdRecordWatch.instance.start());
      _notifyStoreUpdated(refreshRecordWatch: true);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          'AttendanceRepository batch loadListDetails($listIds): $e',
        );
        debugPrint('$st');
      }
      for (final id in targetListIds) {
        if (listDetailReady(id)) _loadedListDetailIds.add(id);
      }
      _notifyStoreUpdated();
    }
  }

  Future<void> _mergeBatchListDetailsIntoStore({
    required Set<String> targetListIds,
    required List<AttendanceSession> batchSessions,
    required List<SignInRecord> batchSignIns,
    required List<AttendanceRecord> batchRecords,
    required List<StudentRecord> batchStudents,
    bool rosterAlreadyAugmented = false,
  }) async {
    final batchSessionIds = batchSessions.map((s) => s.id).toSet();
    final otherSessions = AttendanceStore.sessions
        .where((s) => !targetListIds.contains(s.listId))
        .toList();
    final otherRecords = AttendanceStore.attendanceRecords
        .where((r) => !batchSessionIds.contains(r.sessionId))
        .toList();
    final otherSignIns = AttendanceStore.signIns
        .where((si) => !targetListIds.contains(si.listId))
        .toList();

    await _replaceStoreFromRemote(
      remoteLists: List<AttendanceList>.from(AttendanceStore.lists),
      remoteSessions: [...otherSessions, ...batchSessions],
      remoteRecords: [...otherRecords, ...batchRecords],
      remoteStudents: batchStudents,
      remoteSignIns: [...otherSignIns, ...batchSignIns],
      rosterAlreadyAugmented: rosterAlreadyAugmented,
    );
  }

  Future<void> _mergeListDetailIntoStore({
    required String listId,
    required List<AttendanceSession> listSessions,
    required List<SignInRecord> listSignIns,
    required List<AttendanceRecord> listRecords,
    required List<StudentRecord> listStudents,
    bool rosterAlreadyAugmented = false,
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
      rosterAlreadyAugmented: rosterAlreadyAugmented,
    );
  }

  /// Paints roster names/regs as soon as sign-ins arrive (before student doc fetches).
  Future<void> _publishListDetailEarlyProgress({
    required String listId,
    required List<AttendanceSession> listSessions,
    required List<SignInRecord> listSignIns,
  }) async {
    if (listSignIns.isEmpty && listSessions.isEmpty) return;

    final listSessionIds = listSessions.map((s) => s.id).toSet();
    final listStudentIds = listSignIns.map((si) => si.studentId.trim()).toSet();
    final otherStudents = AttendanceStore.students
        .where((s) => !listStudentIds.contains(s.id.trim()))
        .toList();
    final listStudents = _rosterStudentsFromSignInsSync(
      signIns: listSignIns,
      fetched: AttendanceStore.students
          .where((s) => listStudentIds.contains(s.id.trim()))
          .toList(),
    );
    final otherSessions =
        AttendanceStore.sessions.where((s) => s.listId != listId).toList();
    final otherSignIns =
        AttendanceStore.signIns.where((si) => si.listId != listId).toList();
    final keptRecords = AttendanceStore.attendanceRecords
        .where((r) => !listSessionIds.contains(r.sessionId))
        .toList();
    final listRecords = AttendanceStore.attendanceRecords
        .where((r) => listSessionIds.contains(r.sessionId))
        .toList();

    await _serializedListDetailMerge(
      () => _replaceStoreFromRemote(
        remoteLists: List<AttendanceList>.from(AttendanceStore.lists),
        remoteSessions: [...otherSessions, ...listSessions],
        remoteRecords: [...keptRecords, ...listRecords],
        remoteStudents: [...otherStudents, ...listStudents],
        remoteSignIns: [...otherSignIns, ...listSignIns],
        rosterAlreadyAugmented: true,
      ),
    );
    _notifyStoreUpdated(refreshRecordWatch: false);
  }

  List<StudentRecord> _rosterStudentsFromSignInsSync({
    required List<SignInRecord> signIns,
    required List<StudentRecord> fetched,
    Iterable<String> extraStudentIds = const [],
  }) {
    final byId = <String, StudentRecord>{for (final s in fetched) s.id: s};
    final out = List<StudentRecord>.from(fetched);

    void upsertSynthetic(String studentId, {String? name, String? signInReg}) {
      final sid = studentId.trim();
      if (sid.isEmpty) return;
      final resolvedReg = _registrationForRoster(
        studentId: sid,
        signInReg: signInReg,
        existing: byId[sid],
      );
      var resolvedName = name?.trim() ?? '';
      final existing = byId[sid];
      if (existing != null) {
        if (resolvedName.isEmpty) resolvedName = existing.name.trim();
        if (resolvedReg.isEmpty) {
          final existingReg = existing.registrationNumber.trim().toUpperCase();
          if (existingReg.isNotEmpty && existingReg != '—') {
            // keep existing reg via _registrationForRoster on next pass
          }
        }
        if (resolvedName.isNotEmpty &&
            (existing.name.trim().isEmpty ||
                existing.name.trim() == 'Unknown')) {
          final upgraded = _upgradeStudentIfNeeded(
            existing,
            resolvedName,
            deriveStudentInitialsFromName(resolvedName),
          );
          byId[sid] = upgraded;
          final idx = out.indexWhere((s) => s.id == sid);
          if (idx >= 0) {
            out[idx] = upgraded;
          } else {
            out.add(upgraded);
          }
        }
        return;
      }

      if (isStudentScopedUser() && resolvedReg.isEmpty) {
        final ownReg = currentStudentLoadRegistration()?.trim().toUpperCase();
        if (ownReg != null && ownReg.isNotEmpty) {
          // resolvedReg filled below via _registrationForRoster if own reg matches sid
        }
      }
      final reg = resolvedReg.isNotEmpty
          ? resolvedReg
          : (isStudentScopedUser()
              ? currentStudentLoadRegistration()?.trim().toUpperCase() ?? ''
              : '');
      if (resolvedName.isEmpty && reg.isEmpty) return;

      final synthetic = StudentRecord(
        id: sid,
        name: resolvedName.isNotEmpty ? resolvedName : 'Unknown',
        registrationNumber: reg.isNotEmpty ? reg : '—',
        threeDigitCode: '000',
        initials: resolvedName.isNotEmpty
            ? deriveStudentInitialsFromName(resolvedName)
            : '??',
      );
      byId[sid] = synthetic;
      out.add(synthetic);
    }

    for (final si in signIns) {
      upsertSynthetic(
        si.studentId,
        name: si.studentName,
        signInReg: si.registrationNumber,
      );
    }
    for (final raw in extraStudentIds) {
      upsertSynthetic(raw);
    }
    return out;
  }

  String _registrationForRoster({
    required String studentId,
    String? signInReg,
    StudentRecord? existing,
  }) {
    var reg = signInReg?.trim().toUpperCase() ?? '';
    if (reg.isEmpty && existing != null) {
      final existingReg = existing.registrationNumber.trim().toUpperCase();
      if (existingReg.isNotEmpty && existingReg != '—') reg = existingReg;
    }
    final sid = studentId.trim();
    if (reg.isEmpty && StudentRegistrationNumber.isCanonicalFormat(sid)) {
      reg = StudentRegistrationNumber.normalize(sid);
    }
    return reg;
  }

  Future<void> _refreshRosterNamesForList({
    required String listId,
    required List<AttendanceSession> listSessions,
    required List<SignInRecord> listSignIns,
  }) async {
    final listSessionIds = listSessions.map((s) => s.id).toSet();
    final recordIds = AttendanceStore.attendanceRecords
        .where((r) => listSessionIds.contains(r.sessionId))
        .map((r) => r.studentId);
    final students = await _augmentRosterStudents(
      signIns: listSignIns,
      fetched: AttendanceStore.students,
      extraStudentIds: recordIds,
    );
    final otherStudents = AttendanceStore.students
        .where((s) => !students.any((resolved) => resolved.id == s.id))
        .toList();
    final otherSessions =
        AttendanceStore.sessions.where((s) => s.listId != listId).toList();
    final otherSignIns =
        AttendanceStore.signIns.where((si) => si.listId != listId).toList();
    final keptRecords = AttendanceStore.attendanceRecords
        .where((r) => !listSessionIds.contains(r.sessionId))
        .toList();
    final listRecords = AttendanceStore.attendanceRecords
        .where((r) => listSessionIds.contains(r.sessionId))
        .toList();

    await _serializedListDetailMerge(
      () => _replaceStoreFromRemote(
        remoteLists: List<AttendanceList>.from(AttendanceStore.lists),
        remoteSessions: [...otherSessions, ...listSessions],
        remoteRecords: [...keptRecords, ...listRecords],
        remoteStudents: [...otherStudents, ...students],
        remoteSignIns: [...otherSignIns, ...listSignIns],
        rosterAlreadyAugmented: true,
      ),
    );
    _notifyStoreUpdated(refreshRecordWatch: false);
  }

  /// Chunked [whereIn] queries with per-value fallback when rules reject a chunk.
  static Future<List<ApiDocumentSnapshot>>
      _queryDocsWhereFieldIn({
    required ApiCollectionRef collection,
    required String field,
    required List<String> values,
    ApiGetOptions? options,
  }) async {
    final trimmed = [
      for (final value in values)
        if (value.trim().isNotEmpty) value.trim(),
    ];
    if (trimmed.isEmpty) return const [];

    const chunkSize = 10;
    final out = <ApiDocumentSnapshot>[];
    final seenDocIds = <String>{};

    void addDocs(Iterable<ApiDocumentSnapshot> docs) {
      for (final doc in docs) {
        if (seenDocIds.add(doc.id)) out.add(doc);
      }
    }

    for (var i = 0; i < trimmed.length; i += chunkSize) {
      final chunk = trimmed.skip(i).take(chunkSize).toList();
      var usedFallback = false;
      try {
        final query = collection.where(field, whereIn: chunk);
        final snap = options == null
            ? await query.get().timeout(_onlineFirestoreTimeout)
            : await query.get(options).timeout(_onlineFirestoreTimeout);
        addDocs(snap.docs);
      } on ApiException catch (e) {
        if (e.code == 'permission-denied') {
          usedFallback = true;
        } else if (kDebugMode) {
          debugPrint('_queryDocsWhereFieldIn $field chunk: $e');
        }
      } catch (_) {
        usedFallback = true;
      }
      if (usedFallback) {
        addDocs(
          await _queryDocsWhereFieldEqualsFallback(
            collection: collection,
            field: field,
            values: chunk,
            options: options,
          ),
        );
      }
    }
    return out;
  }

  /// Per-value equality fallback when [whereIn] is denied for a chunk.
  static Future<List<ApiDocumentSnapshot>>
      _queryDocsWhereFieldEqualsFallback({
    required ApiCollectionRef collection,
    required String field,
    required List<String> values,
    ApiGetOptions? options,
  }) async {
    if (values.isEmpty) return const [];
    const batchSize = 10;
    final out = <ApiDocumentSnapshot>[];
    for (var i = 0; i < values.length; i += batchSize) {
      final chunk = values.skip(i).take(batchSize).toList();
      final snaps = await Future.wait(
        chunk.map((v) async {
          try {
            final query = collection.where(field, isEqualTo: v);
            final snap = options == null
                ? await query.get().timeout(_onlineFirestoreTimeout)
                : await query.get(options).timeout(_onlineFirestoreTimeout);
            return snap;
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

  /// Loads docs matching any of [values] for [field] (prefers [whereIn]).
  static Future<List<ApiDocumentSnapshot>>
      _queryDocsWhereFieldEquals({
    required ApiCollectionRef collection,
    required String field,
    required List<String> values,
    ApiGetOptions? options,
  }) =>
      _queryDocsWhereFieldIn(
        collection: collection,
        field: field,
        values: values,
        options: options,
      );

  String? _snapshotUserId() =>
      AuthRepository.instance.currentUserId?.trim();

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

  /// Students query [attendance_records] by [studentId] only (security rules).
  Future<List<AttendanceRecord>> _fetchAttendanceRecordsForDetailLoad({
    required List<String> sessionIds,
    required Set<String>? scopedStudentIds,
    required ApiGetOptions queryOptions,
  }) async {
    if (scopedStudentIds != null && scopedStudentIds.isNotEmpty) {
      final recordDocs = await _queryDocsWhereFieldEquals(
        collection:
            _firestore.collection(ApiCollections.attendanceRecords),
        field: 'studentId',
        values: scopedStudentIds.toList(),
        options: queryOptions,
      );
      final sessionFilter =
          sessionIds.isEmpty ? null : sessionIds.toSet();
      return recordDocs
          .map(_tryRecordFromDoc)
          .whereType<AttendanceRecord>()
          .where(
            (r) =>
                sessionFilter == null ||
                sessionFilter.contains(r.sessionId),
          )
          .toList();
    }
    if (sessionIds.isEmpty) return [];
    final recordDocs = await _queryDocsWhereFieldEquals(
      collection: _firestore.collection(ApiCollections.attendanceRecords),
      field: 'sessionId',
      values: sessionIds,
      options: queryOptions,
    );
    return recordDocs.map(_tryRecordFromDoc).whereType<AttendanceRecord>().toList();
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
    _listsCatalogFetchedAt = syncedAt;
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
    _markListDetailsReadyFromStore();
    unawaited(AttendanceRemoteRecordWatch.instance.start());
    unawaited(AttendanceRtdRecordWatch.instance.start());
    _notifyStoreUpdated(refreshRecordWatch: true);
    return true;
  }

  void _mergeLocallyPublishedListsInto(Map<String, AttendanceList> listsById) {
    for (final id in _listsPublishedOnServer) {
      final local = AttendanceStore.listById(id);
      if (local != null) {
        listsById[id] = local;
      }
    }
  }

  Future<void> _replaceListsOnly(List<AttendanceList> remoteLists) async {
    if (!AuthRepository.instance.isLoggedIn) return;
    // Wrong-scope or in-flight list refresh can return empty before role hydration;
    // keep visible lists until a non-empty server response arrives.
    if (remoteLists.isEmpty && AttendanceStore.lists.isNotEmpty) return;
    for (final remote in remoteLists) {
      _listsPublishedOnServer.remove(remote.id);
    }
    final listsById = {for (final l in remoteLists) l.id: l};
    for (final e in await PendingListCreateQueue.loadAll()) {
      listsById[e.list.id] = e.list;
    }
    _mergeLocallyPublishedListsInto(listsById);
    final nextIds = listsById.keys.toSet();
    for (final l in AttendanceStore.lists) {
      if (!nextIds.contains(l.id)) {
        await _purgeListLocally(l.id);
      }
    }
    AttendanceStore.replaceLists(listsById.values.toList());
  }

  /// Null when either Firestore query failed (caller must not reconcile/purge).
  Future<List<AttendanceList>?> _fetchLecturerLists(
    String uid, {
    required bool force,
  }) async {
    final queryOptions = _loadQueryOptions(force: force);
    final listsById = <String, AttendanceList>{};
    var assignedOk = true;
    var createdOk = true;

    Future<void> mergeAssigned() async {
      try {
        final assignedSnap = await _firestore
            .collection(ApiCollections.attendanceLists)
            .where('lecturerUid', isEqualTo: uid)
            .get(queryOptions);
        for (final d in assignedSnap.docs) {
          listsById[d.id] = _listFromDoc(d);
        }
      } catch (e, st) {
        assignedOk = false;
        if (kDebugMode) {
          debugPrint(
            'AttendanceRepository._fetchLecturerLists assigned (uid=$uid): $e',
          );
          debugPrint('$st');
        }
      }
    }

    Future<void> mergeCreated() async {
      try {
        final createdSnap = await _firestore
            .collection(ApiCollections.attendanceLists)
            .where('createdBy', isEqualTo: uid)
            .get(queryOptions);
        for (final d in createdSnap.docs) {
          listsById.putIfAbsent(d.id, () => _listFromDoc(d));
        }
      } catch (e, st) {
        createdOk = false;
        if (kDebugMode) {
          debugPrint(
            'AttendanceRepository._fetchLecturerLists created (uid=$uid): $e',
          );
          debugPrint('$st');
        }
      }
    }

    await Future.wait([mergeAssigned(), mergeCreated()]);
    if (!assignedOk || !createdOk) return null;
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
      try {
        final reg = currentStudentLoadRegistration();
        if (reg == null || reg.isEmpty) return withLocalEnrollment({});
        final roster = await _fetchStudentsForRegistration(reg, force: force);
        final studentIds =
            roster.map((s) => s.id).where((id) => id.isNotEmpty);
        if (studentIds.isEmpty) return withLocalEnrollment({});
        final signInDocs = await _queryDocsWhereFieldEquals(
          collection: _firestore.collection(ApiCollections.signIns),
          field: 'studentId',
          values: studentIds.toList(),
          options: options,
        );
        final signInListIds = signInDocs
            .map((d) => (d.data()?['listId'] as String?)?.trim() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();
        if (signInListIds.isEmpty) return withLocalEnrollment({});
        final existingLists =
            await _fetchListsByIds(signInListIds, force: force);
        final remoteIds = existingLists.map((l) => l.id).toSet();
        return withLocalEnrollment(remoteIds);
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint(
            'AttendanceRepository._fetchAuthoritativeRemoteListIds student: $e',
          );
          debugPrint('$st');
        }
        return null;
      }
    }

    final auth = AuthRepository.instance;
    final lecturerScope = currentLecturerLoadScopeUid();
    if (lecturerScope != null && lecturerScope.isNotEmpty) {
      final lists = await _fetchLecturerLists(lecturerScope, force: force);
      if (lists == null) return null;
      return withLocalEnrollment(lists.map((l) => l.id).toSet());
    }

    if (auth.adminCheckDone && auth.isAdmin) {
      try {
        final snap = await _firestore
            .collection(ApiCollections.attendanceLists)
            .get(options);
        return withLocalEnrollment(snap.docs.map((d) => d.id).toSet());
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint(
            'AttendanceRepository._fetchAuthoritativeRemoteListIds admin: $e',
          );
          debugPrint('$st');
        }
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
    final ids = listIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    final fetched = await Future.wait(
      ids.map((trimmed) async {
        try {
          final d = await _firestore
              .collection(ApiCollections.attendanceLists)
              .doc(trimmed)
              .get(options);
          if (!d.exists) return null;
          return _listFromDoc(d);
        } catch (_) {
          return null;
        }
      }),
    );
    return [for (final list in fetched) if (list != null) list];
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
            .collection(ApiCollections.attendanceSessions)
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
    required ApiGetOptions? options,
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
            .collection(ApiCollections.students)
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
            .collection(ApiCollections.students)
            .doc(regHint)
            .get(options);
        if (byReg.exists) return _studentFromDoc(byReg);
      } catch (_) {}
    }

    if (StudentRegistrationNumber.isCanonicalFormat(trimmedId)) {
      try {
        final byIdReg = await _firestore
            .collection(ApiCollections.students)
            .doc(trimmedId)
            .get(options);
        if (byIdReg.exists) return _studentFromDoc(byIdReg);
      } catch (_) {}
      return null;
    }

    try {
      final primary = await _firestore
          .collection(ApiCollections.students)
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
    final idsToFetch = <String>[];
    for (final raw in studentIds) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      if (!force) {
        final cached = AttendanceStore.students
            .where((s) => s.id.trim() == trimmed)
            .firstOrNull;
        if (cached != null) {
          if (seenIds.add(cached.id.trim())) out.add(cached);
          continue;
        }
      }
      idsToFetch.add(trimmed);
    }
    if (idsToFetch.isEmpty) return out;

    final regsForBatch = <String>{
      for (final id in idsToFetch)
        if (StudentRegistrationNumber.isCanonicalFormat(id))
          StudentRegistrationNumber.normalize(id),
      if (regByStudentId != null)
        for (final reg in regByStudentId.values)
          if (StudentRegistrationNumber.isCanonicalFormat(reg))
            StudentRegistrationNumber.normalize(reg),
    };
    if (regsForBatch.isNotEmpty) {
      final docs = await _queryDocsWhereFieldIn(
        collection: _firestore.collection(ApiCollections.students),
        field: 'registrationNumber',
        values: regsForBatch.toList(),
        options: options,
      );
      for (final doc in docs) {
        final student = _studentFromDoc(doc);
        final trimmed = student.id.trim();
        final reg = student.registrationNumber.trim().toUpperCase();
        for (final alias in <String>{trimmed, reg}) {
          if (alias.isEmpty || seenIds.contains(alias)) continue;
          out.add(student);
          seenIds.add(alias);
        }
      }
    }

    final remaining = idsToFetch
        .where((id) => !seenIds.contains(id.trim()))
        .toList();
    if (remaining.isEmpty) return out;

    const batchSize = 8;
    for (var i = 0; i < remaining.length; i += batchSize) {
      final chunk = remaining.skip(i).take(batchSize);
      final batch = await Future.wait(
        chunk.map(
          (trimmed) => _fetchStudentDocByIdOrReg(
            trimmed,
            registrationNumber: regByStudentId?[trimmed],
            options: options,
          ),
        ),
      );
      for (final student in batch) {
        if (student == null) continue;
        final trimmed = student.id.trim();
        if (trimmed.isEmpty || seenIds.contains(trimmed)) continue;
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

  /// True when [app_users.registrationNumber] is set (required for student reads).
  Future<bool> _studentRegistrationConfirmedOnServer() async {
    if (!AuthRepository.instance.isStudentAuthIdentity) return true;
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) return false;
    if (!AppConnectivity.instance.isOnline) return true;
    final uid = AuthRepository.instance.currentUserId?.trim();
    if (uid == null || uid.isEmpty) return false;
    if (_firestoreIfReady == null) return false;
    try {
      final doc = await _firestore
          .collection(ApiCollections.appUsers)
          .doc(uid)
          .get(_loadQueryOptions(force: true));
      final serverReg =
          (doc.data()?['registrationNumber'] as String?)?.trim().toUpperCase();
      return serverReg != null && serverReg.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<List<StudentRecord>> _fetchStudentsForRegistration(
    String reg, {
    required bool force,
  }) async {
    final normalized = reg.trim().toUpperCase();
    if (normalized.isEmpty) return const [];
    try {
      final snap = await _firestore
          .collection(ApiCollections.students)
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

    if (_usesFullStaffListLoad()) {
      await _executeLoadAllForStaff(force, loadGeneration, listsOnly: true);
      return;
    }

    final lecturerScope = _listsOnlyScopeUid(explicitScope: scopeToLecturerUid);

    if (lecturerScope != null && lecturerScope.isNotEmpty) {
      await _executeLoadAllForLecturer(
        force,
        lecturerScope,
        listsOnly: true,
      );
      if (!_loadsAllowedForSession(loadGeneration)) return;
      if (AttendanceStore.lists.isNotEmpty) return;
    }

    if (!auth.roleCheckDone) {
      await _awaitRoleChecksDone(timeout: const Duration(seconds: 2));
    }
    if (!_loadsAllowedForSession(loadGeneration)) return;
    if (!auth.roleCheckDone) return;

    if (isStudentScopedUser()) return;

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
    _loadedListDetailIds.clear();
    _listDetailFetchedAt.clear();
    await _rehydrateStudentPendingWorkIntoStore();
    unawaited(AttendanceRemoteRecordWatch.instance.start());
    unawaited(AttendanceRtdRecordWatch.instance.start());
    _notifyStoreUpdated();
    return true;
  }

  /// Merges queued offline check-ins and session-code captures into
  /// [AttendanceStore] so profile/history screens show pending present rows
  /// after restart without waiting for sync.
  Future<void> _rehydrateStudentPendingWorkIntoStore() async {
    if (!AuthRepository.instance.isLoggedIn) return;

    var changed = false;

    for (final e in await PendingCheckInQueue.loadAll()) {
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

    for (final e in await PendingSessionCodeQueue.loadAll()) {
      if (e.status == PendingSessionCodeStatus.invalidOrExpired ||
          e.status == PendingSessionCodeStatus.deviceBlocked) {
        continue;
      }
      final student = AttendanceStore.findStudentByReg(e.registrationNumber);
      if (student == null) continue;
      final reg = student.registrationNumber.trim().toUpperCase();
      for (final session in _sessionsForPendingCodeRehydrate(e)) {
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
        final list = AttendanceStore.listById(session.listId);
        final course = list != null
            ? resolveCourseForStudentCheckIn(list, student.id)
            : '—';
        final row = AttendanceRecord(
          id: attendanceRecordIdForSessionStudent(session.id, student.id),
          sessionId: session.id,
          studentId: student.id,
          course: course,
          timestamp: e.capturedAt,
          latitude: e.latitude,
          longitude: e.longitude,
          verified: false,
          present: true,
          deviceId: e.deviceId,
        );
        final existing = AttendanceStore.attendanceRecordForSessionStudent(
          session.id,
          student.id,
        );
        if (existing != null && existing.present && existing.verified) continue;
        if (existing != null) {
          AttendanceStore.updateAttendanceRecord(row);
        } else {
          AttendanceStore.addAttendanceRecordIfAbsent(row);
        }
        changed = true;
      }
    }

    if (!changed) return;
    AttendanceStore.invalidateLookupCaches();
    _notifyStoreUpdated();
    unawaited(_persistScopedLocalSnapshot());
  }

  /// Resolves sessions for a queued session-code row using the local store.
  Iterable<AttendanceSession> _sessionsForPendingCodeRehydrate(
    PendingSessionCodeEntry entry,
  ) {
    final byCode = validateSessionCode(entry.sessionCodeRaw);
    if (byCode != null) return [byCode];

    final hint = entry.sessionId?.trim();
    if (hint != null && hint.isNotEmpty) {
      final byId = AttendanceStore.sessionById(hint);
      if (byId != null &&
          normalizeSessionCodeInput(byId.sessionCode) ==
              normalizeSessionCodeInput(entry.sessionCodeRaw)) {
        return [byId];
      }
    }

    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (code.isEmpty) return const [];
    final seen = <String>{};
    final out = <AttendanceSession>[];
    for (final s in AttendanceStore.sessions) {
      if (normalizeSessionCodeInput(s.sessionCode) != code) continue;
      if (seen.add(s.id)) out.add(s);
    }
    return out;
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
        sessionHistoryReady &&
        !_studentProfileHasMissingListMetadata(normalizedReg)) {
      if (online) {
        await reconcileDeletedListsAgainstRemote();
        await _fetchNeverLoadedStudentListDetails();
      }
      await _finalizeExpiredOpenSessions();
      return;
    }

    if (_isLoaded &&
        !force &&
        _loadScopeStudentReg == normalizedReg &&
        sessionHistoryReady &&
        _studentProfileHasMissingListMetadata(normalizedReg)) {
      if (online) {
        await _ensureStudentEnrolledListMetadataLoaded(
          reg: normalizedReg,
        );
        await _fetchNeverLoadedStudentListDetails();
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
        if (await _studentRegistrationConfirmedOnServer()) {
          _isLoaded = true;
          unawaited(_persistScopedLocalSnapshot());
        }
        _notifyStoreUpdated();
        return;
      }

      final queryOptions = _loadQueryOptions(force: force);
      final signInDocs = await _queryDocsWhereFieldEquals(
        collection: _firestore.collection(ApiCollections.signIns),
        field: 'studentId',
        values: studentIds.toList(),
        options: queryOptions,
      );
      final signIns = signInDocs.map(_signInFromDoc).toList();
      final listIds = signIns.map((s) => s.listId).toSet();
      final signInListIds = Set<String>.from(listIds);

      final recordDocs = await _queryDocsWhereFieldEquals(
        collection:
            _firestore.collection(ApiCollections.attendanceRecords),
        field: 'studentId',
        values: studentIds.toList(),
        options: queryOptions,
      );
      final records = recordDocs.map(_recordFromDoc).toList();

      final listsFuture = signInListIds.isEmpty
          ? Future<List<AttendanceList>>.value(const [])
          : _fetchListsByIds(signInListIds, force: force);

      if (!_loadsAllowedForSession(loadGeneration)) return;
      await _replaceStoreFromRemote(
        remoteLists: List<AttendanceList>.from(AttendanceStore.lists),
        remoteSessions: List<AttendanceSession>.from(AttendanceStore.sessions),
        remoteRecords: records,
        remoteStudents: rosterStudents,
        remoteSignIns: signIns,
      );
      _isLoaded = true;
      _notifyStoreUpdated(immediate: true);

      final listIdsFromSignIns = Set<String>.from(listIds);
      var sessions = <AttendanceSession>[];
      if (listIds.isNotEmpty) {
        final sessionDocs = await _queryDocsWhereFieldEquals(
          collection:
              _firestore.collection(ApiCollections.attendanceSessions),
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
              _firestore.collection(ApiCollections.attendanceSessions),
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
      _isLoaded = true;
      _notifyStoreUpdated(immediate: true);

      var lists = await listsFuture;
      if (listIds.length > signInListIds.length) {
        final extraIds = listIds.difference(signInListIds);
        final extraLists = await _fetchListsByIds(extraIds, force: force);
        final seen = lists.map((l) => l.id).toSet();
        for (final list in extraLists) {
          if (seen.add(list.id)) lists.add(list);
        }
      }

      final fetchedListIds = lists.map((l) => l.id).toSet();
      final pendingListIds = await _localEnrollmentListIds();
      for (final missing
          in listIds.difference(fetchedListIds).difference(pendingListIds)) {
        if (await _listDocConfirmedMissingOnServer(missing)) {
          await _purgeListLocally(missing);
        }
      }

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
    unawaited(AttendanceRtdRecordWatch.instance.start());
      unawaited(correctMetadataMatchedAbsentRollForSignedInLists());
      _notifyStoreUpdated(refreshRecordWatch: true);
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
          .collection(ApiCollections.attendanceLists)
          .get(queryOptions);
      final remoteLists = listsSnap.docs.map((d) => _listFromDoc(d)).toList();

      if (listsOnly) {
        await _replaceListsOnly(remoteLists);
        if (!_loadsAllowedForSession(loadGeneration)) return;
        _isLoaded = true;
        _loadScopeLecturerUid = null;
        _markListsCatalogFetched();
        _markStoreSyncedFromServer();
        await _finalizeExpiredOpenSessions();
        unawaited(PushController.instance.syncListTopicsFromStore());
        unawaited(_persistLocalSnapshot(null));
        unawaited(AttendanceRemoteRecordWatch.instance.start());
    unawaited(AttendanceRtdRecordWatch.instance.start());
        _notifyStoreUpdated();
        prefetchActiveListDetails();
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

      final listIds = remoteLists.map((l) => l.id).toList();

      final sessionAndSignInDocs = await Future.wait([
        _queryDocsWhereFieldEquals(
          collection:
              _firestore.collection(ApiCollections.attendanceSessions),
          field: 'listId',
          values: listIds,
          options: queryOptions,
        ),
        _queryDocsWhereFieldEquals(
          collection: _firestore.collection(ApiCollections.signIns),
          field: 'listId',
          values: listIds,
          options: queryOptions,
        ),
      ]);
      final sessions =
          sessionAndSignInDocs[0].map(_trySessionFromDoc).whereType<AttendanceSession>().toList();
      final signIns =
          sessionAndSignInDocs[1].map(_trySignInFromDoc).whereType<SignInRecord>().toList();

      final sessionIds = sessions.map((s) => s.id).toList();
      final recordDocs = await _queryDocsWhereFieldEquals(
        collection:
            _firestore.collection(ApiCollections.attendanceRecords),
        field: 'sessionId',
        values: sessionIds,
        options: queryOptions,
      );
      final records =
          recordDocs.map(_tryRecordFromDoc).whereType<AttendanceRecord>().toList();

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
        remoteSessions: sessions,
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
    unawaited(AttendanceRtdRecordWatch.instance.start());
      _notifyStoreUpdated(refreshRecordWatch: true);
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
        if (AttendanceStore.lists.isNotEmpty && _listsCatalogCacheFresh()) {
          prefetchActiveListDetails();
          await _finalizeExpiredOpenSessions();
          return;
        }
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
      if (lists == null) {
        if (kDebugMode) {
          debugPrint(
            'AttendanceRepository lecturer loadAll: list fetch failed (uid=$uid)',
          );
        }
        if (_isLoaded) {
          await _finalizeExpiredOpenSessions();
          _notifyStoreUpdated();
        }
        return;
      }

      if (listsOnly) {
        await _replaceListsOnly(lists);
        if (!_loadsAllowedForSession(loadGeneration)) return;
        _isLoaded = true;
        _loadScopeLecturerUid = uid;
        _lecturerScopeIncludesSessions = false;
        _loadScopeStudentReg = null;
        _markListsCatalogFetched();
        _markStoreSyncedFromServer();
        await _finalizeExpiredOpenSessions();
        unawaited(PushController.instance.syncListTopicsFromStore());
        unawaited(_persistLocalSnapshot(uid));
        unawaited(AttendanceRemoteRecordWatch.instance.start());
    unawaited(AttendanceRtdRecordWatch.instance.start());
        _notifyStoreUpdated(refreshRecordWatch: true);
        prefetchActiveListDetails();
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
              _firestore.collection(ApiCollections.attendanceSessions),
          field: 'listId',
          values: listIds,
          options: queryOptions,
        ),
        _queryDocsWhereFieldEquals(
          collection: _firestore.collection(ApiCollections.signIns),
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
            _firestore.collection(ApiCollections.attendanceRecords),
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
    unawaited(AttendanceRtdRecordWatch.instance.start());
      _notifyStoreUpdated(refreshRecordWatch: true);
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

  static AttendanceList _listFromDoc(ApiDocumentSnapshot d) {
    final data = d.data()!;
    final date = apiDateFromField(data['date']) ?? DateTime.now();
    final courses = data['courses'] as List<dynamic>?;
    final rawLc = (data['lecturerSignCode'] as String?)?.trim() ?? '';
    final lecturerCode =
        rawLc.isEmpty ? null : normalizeSessionCodeInput(rawLc);
    final signedTs = apiDateFromField(data['lecturerSignedAt']);
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
      lecturerSignedAt: signedTs,
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
      ApiDocumentSnapshot d) {
    final data = d.data()!;
    final start = apiDateFromField(data['startTime']) ?? DateTime.now();
    final end = apiDateFromField(data['endTime']) ?? start;
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
      locationMetadataPending: data['locationMetadataPending'] == true,
    );
  }

  static AttendanceRecord _recordFromDoc(
      ApiDocumentSnapshot d) {
    return recordFromFirestoreDoc(d);
  }

  static AttendanceRecord? _tryRecordFromDoc(
    ApiDocumentSnapshot d,
  ) {
    try {
      if (!d.exists || d.data() == null) return null;
      return _recordFromDoc(d);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AttendanceRepository: skip bad record ${d.id}: $e');
      }
      return null;
    }
  }

  static SignInRecord? _trySignInFromDoc(
    ApiDocumentSnapshot d,
  ) {
    try {
      if (!d.exists || d.data() == null) return null;
      return _signInFromDoc(d);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AttendanceRepository: skip bad sign-in ${d.id}: $e');
      }
      return null;
    }
  }

  static AttendanceSession? _trySessionFromDoc(
    ApiDocumentSnapshot d,
  ) {
    try {
      if (!d.exists || d.data() == null) return null;
      return _sessionFromDoc(d);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AttendanceRepository: skip bad session ${d.id}: $e');
      }
      return null;
    }
  }

  /// Public parser for REST / realtime session listeners.
  static AttendanceSession? trySessionFromApiDoc(ApiDocumentSnapshot d) =>
      _trySessionFromDoc(d);

  /// Public parser for realtime attendance record listeners.
  static AttendanceRecord? tryRecordFromFirestoreDoc(
    ApiDocumentSnapshot d,
  ) => _tryRecordFromDoc(d);

  /// Public parser for realtime attendance record listeners.
  static AttendanceRecord recordFromFirestoreDoc(
    ApiDocumentSnapshot d,
  ) {
    final data = d.data()!;
    final ts = apiDateFromField(data['timestamp']) ?? DateTime.now();
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
      ApiDocumentSnapshot d) {
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

  static SignInRecord _signInFromDoc(ApiDocumentSnapshot d) {
    final data = d.data()!;
    final signedInAt =
        apiDateFromField(data['signedInAt']) ?? DateTime.now();
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
    final byId = AttendanceStore.studentMapById()[trimmed];
    if (byId != null) return byId;
    if (StudentRegistrationNumber.isCanonicalFormat(trimmed)) {
      final byReg = AttendanceStore.findStudentByReg(trimmed);
      if (byReg != null) return byReg;
    }
    final upper = trimmed.toUpperCase();
    return AttendanceStore.students
        .where(
          (s) =>
              s.id.trim() == trimmed ||
              s.registrationNumber.trim().toUpperCase() == upper,
        )
        .firstOrNull;
  }

  /// Registration number attached to check-in uploads for Firestore rules.
  String? _registrationForCheckInUpload(String studentId) {
    final trimmed = studentId.trim();
    if (trimmed.isEmpty) return null;
    final student = _studentRecordForId(trimmed);
    if (student != null) {
      final reg = student.registrationNumber.trim().toUpperCase();
      if (reg.isNotEmpty) return reg;
    }
    final ownReg = currentStudentLoadRegistration()?.trim().toUpperCase();
    if (ownReg != null && ownReg.isNotEmpty) {
      if (trimmed.toUpperCase() == ownReg) return ownReg;
      if (StudentRegistrationNumber.isCanonicalFormat(trimmed)) {
        final normalized = StudentRegistrationNumber.normalize(trimmed).toUpperCase();
        if (normalized == ownReg) return ownReg;
      }
    }
    if (StudentRegistrationNumber.isCanonicalFormat(trimmed)) {
      return StudentRegistrationNumber.normalize(trimmed);
    }
    return ownReg;
  }

  /// Canonical registration-based id used in check-in docs and RTD paths.
  String canonicalStudentIdForUpload(String rawStudentId) {
    final trimmed = rawStudentId.trim();
    if (trimmed.isEmpty) return trimmed;
    final student = _studentRecordForId(trimmed);
    if (student != null) {
      return _reconcileStudentIdToRegistration(student).id.trim();
    }
    final ownReg = currentStudentLoadRegistration();
    if (ownReg != null &&
        ownReg.toUpperCase() ==
            StudentRegistrationNumber.normalize(trimmed).toUpperCase()) {
      return ownReg;
    }
    if (StudentRegistrationNumber.isCanonicalFormat(trimmed)) {
      return StudentRegistrationNumber.normalize(trimmed);
    }
    return trimmed;
  }

  AttendanceRecord _attendanceRecordWithCanonicalStudentId(
    AttendanceRecord record,
  ) {
    final canonical = canonicalStudentIdForUpload(record.studentId);
    if (canonical.isEmpty || canonical == record.studentId.trim()) {
      return record;
    }
    return AttendanceRecord(
      id: attendanceRecordIdForSessionStudent(record.sessionId, canonical),
      sessionId: record.sessionId,
      studentId: canonical,
      course: record.course,
      timestamp: record.timestamp,
      latitude: record.latitude,
      longitude: record.longitude,
      verified: record.verified,
      present: record.present,
      deviceId: record.deviceId,
    );
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
        AuthRepository.appUserIsStudentField: true,
      };

  /// Ensures [students/{id}] exists on Firestore before check-in claim uploads.
  /// Firestore rules require the doc for [studentOwnsStudentId].
  Future<bool> ensureStudentDocOnServer(String studentId) async {
    final id = canonicalStudentIdForUpload(studentId);
    if (id.isEmpty || _firestoreIfReady == null) return false;
    var student = _studentRecordForId(id);
    student ??= AttendanceStore.findStudentByReg(id);
    if (student == null) {
      final reg = _registrationForCheckInUpload(id);
      if (reg != null && reg.isNotEmpty) {
        student = await resolveStudentForRegistration(reg, fast: true);
      }
    }
    if (student == null) {
      final reg = _registrationForCheckInUpload(id);
      if (reg == null || reg.isEmpty) return false;
      student = StudentRecord(
        id: reg,
        name: AuthRepository.instance.currentFullName?.trim().isNotEmpty == true
            ? AuthRepository.instance.currentFullName!.trim()
            : 'Unknown',
        registrationNumber: reg,
        threeDigitCode: '',
        initials: initialsFromFullName(
          AuthRepository.instance.currentFullName?.trim() ?? '',
        ),
      );
      AttendanceStore.upsertStudent(student);
    }
    student = _reconcileStudentIdToRegistration(student);
    if (!AppConnectivity.instance.hasNetworkInterface) {
      await _persistStudentRecord(student, awaitWhenOnline: false);
      return false;
    }
    try {
      await _persistStudentRecord(student, awaitWhenOnline: true);
      final snap = await _firestore
          .collection(ApiCollections.students)
          .doc(student.id)
          .get(const ApiGetOptions(source: ApiSource.server))
          .timeout(_sessionPublishFastTimeout);
      if (snap.exists) return true;
      final reg = student.registrationNumber.trim().toUpperCase();
      if (reg.isNotEmpty && reg != student.id.trim()) {
        final regSnap = await _firestore
            .collection(ApiCollections.students)
            .doc(reg)
            .get(const ApiGetOptions(source: ApiSource.server))
            .timeout(_sessionPublishFastTimeout);
        if (regSnap.exists) return true;
      }
      // Persist succeeded — allow upload even if server read is briefly stale.
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<StudentRecord?> _studentForCheckInUpload(String studentId) async {
    var student = _studentRecordForId(studentId);
    if (student != null) {
      return _reconcileStudentIdToRegistration(student);
    }
    final reg = _registrationForCheckInUpload(studentId);
    if (reg == null || reg.isEmpty) return null;
    student = await resolveStudentForRegistration(reg, fast: true);
    if (student == null) return null;
    return _reconcileStudentIdToRegistration(student);
  }

  Future<void> _persistStudentRecord(
    StudentRecord record, {
    bool awaitWhenOnline = false,
  }) async {
    if (_firestoreIfReady == null) return;
    final reg = record.registrationNumber.trim().toUpperCase();
    final payload = _studentToFirestoreMap(record);

    Future<void> upload() async {
      await _firestore
          .collection(ApiCollections.students)
          .doc(record.id)
          .set(payload, ApiSetOptions(merge: true));
      if (reg.isNotEmpty && reg != record.id.trim()) {
        await _firestore
            .collection(ApiCollections.students)
            .doc(reg)
            .set(payload, ApiSetOptions(merge: true));
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
    Iterable<String> extraStudentIds = const [],
  }) async {
    final sync = _rosterStudentsFromSignInsSync(
      signIns: signIns,
      fetched: fetched,
      extraStudentIds: extraStudentIds,
    );
    final byId = <String, StudentRecord>{for (final s in sync) s.id: s};
    final out = List<StudentRecord>.from(sync);

    final regsNeedingNames = <String>{};
    final uidsNeedingProfiles = <String>{};
    final remoteFetchTargets = <({String studentId, String? reg})>[];

    void considerStudent({
      required String studentId,
      String? signInName,
      String? signInReg,
    }) {
      final sid = studentId.trim();
      if (sid.isEmpty) return;
      final existing = byId[sid];
      var name = signInName?.trim() ?? '';
      var reg = _registrationForRoster(
        studentId: sid,
        signInReg: signInReg,
        existing: existing,
      );
      if (existing != null) {
        if (name.isEmpty) name = existing.name.trim();
        if (name.isEmpty && reg.isNotEmpty) regsNeedingNames.add(reg);
        if (name.isEmpty || name == 'Unknown') {
          if (reg.isNotEmpty) {
            regsNeedingNames.add(reg);
          } else if (!StudentRegistrationNumber.isCanonicalFormat(sid)) {
            uidsNeedingProfiles.add(sid);
          }
        }
        return;
      }
      if (!isStudentScopedUser() && (name.isEmpty || reg.isEmpty)) {
        remoteFetchTargets.add((studentId: sid, reg: reg.isNotEmpty ? reg : null));
      }
      if (name.isEmpty && reg.isNotEmpty) {
        regsNeedingNames.add(reg);
      } else if (name.isEmpty &&
          reg.isEmpty &&
          !StudentRegistrationNumber.isCanonicalFormat(sid)) {
        uidsNeedingProfiles.add(sid);
      }
    }

    for (final si in signIns) {
      considerStudent(
        studentId: si.studentId,
        signInName: si.studentName,
        signInReg: si.registrationNumber,
      );
    }
    for (final raw in extraStudentIds) {
      considerStudent(studentId: raw);
    }

    final nameByReg = await _lookupFullNamesOnRegistrationDocs(regsNeedingNames);
    final profilesByUid =
        await _lookupStudentProfilesByUserIds(uidsNeedingProfiles);

    if (!isStudentScopedUser() && remoteFetchTargets.isNotEmpty) {
      const batchSize = 8;
      for (var i = 0; i < remoteFetchTargets.length; i += batchSize) {
        final chunk = remoteFetchTargets.skip(i).take(batchSize);
        final batch = await Future.wait(
          chunk.map((target) async {
            final sid = target.studentId.trim();
            final reg = target.reg?.trim().toUpperCase() ?? '';
            return _fetchStudentDocByIdOrReg(
              sid,
              registrationNumber: reg.isNotEmpty ? reg : null,
              options: null,
            );
          }),
        );
        for (final remote in batch) {
          if (remote == null) continue;
          for (final sid in <String>{remote.id.trim(), remote.registrationNumber.trim().toUpperCase()}) {
            if (sid.isEmpty) continue;
            if (byId.containsKey(sid)) {
              final existing = byId[sid]!;
              if (existing.name.trim().isEmpty ||
                  existing.name.trim() == 'Unknown') {
                byId[sid] = remote;
                final idx = out.indexWhere((s) => s.id == sid);
                if (idx >= 0) out[idx] = remote;
              }
              continue;
            }
            byId[sid] = remote;
            out.add(remote);
          }
        }
      }
    }

    void applyResolvedProfile(String studentId) {
      final sid = studentId.trim();
      if (sid.isEmpty) return;
      final existing = byId[sid];
      var name = existing?.name.trim() ?? '';
      var reg = _registrationForRoster(
        studentId: sid,
        existing: existing,
      );

      final profile = profilesByUid[sid];
      if (profile != null) {
        if (name.isEmpty || name == 'Unknown') {
          name = profile.name.trim();
        }
        if (reg.isEmpty || reg == '—') {
          final profileReg = profile.reg.trim().toUpperCase();
          if (profileReg.isNotEmpty) reg = profileReg;
        }
      }
      if ((name.isEmpty || name == 'Unknown') && reg.isNotEmpty) {
        name = nameByReg[StudentRegistrationNumber.normalize(reg)] ?? name;
      }
      if (name.isEmpty && reg.isEmpty) return;

      final record = StudentRecord(
        id: sid,
        name: name.isNotEmpty ? name : 'Unknown',
        registrationNumber: reg.isNotEmpty ? reg : '—',
        threeDigitCode: existing?.threeDigitCode ?? '000',
        initials: name.isNotEmpty
            ? deriveStudentInitialsFromName(name)
            : (existing?.initials ?? '??'),
      );
      if (existing == null) {
        byId[sid] = record;
        out.add(record);
        return;
      }
      if (name.isNotEmpty && name != 'Unknown') {
        final upgraded = _upgradeStudentIfNeeded(
          existing,
          name,
          deriveStudentInitialsFromName(name),
        );
        byId[sid] = upgraded;
        final idx = out.indexWhere((s) => s.id == sid);
        if (idx >= 0) out[idx] = upgraded;
      }
    }

    for (final si in signIns) {
      applyResolvedProfile(si.studentId);
    }
    for (final raw in extraStudentIds) {
      applyResolvedProfile(raw);
    }

    for (var i = 0; i < out.length; i++) {
      final student = out[i];
      if (student.name.trim().isNotEmpty && student.name.trim() != 'Unknown') {
        continue;
      }
      var reg = student.registrationNumber.trim().toUpperCase();
      if (reg.isEmpty || reg == '—') {
        reg = _registrationForRoster(studentId: student.id, existing: student);
      }
      var lookedUp = reg.isNotEmpty
          ? nameByReg[StudentRegistrationNumber.normalize(reg)] ?? ''
          : '';
      if (lookedUp.isEmpty) {
        final profile = profilesByUid[student.id.trim()];
        lookedUp = profile?.name.trim() ?? '';
        if ((reg.isEmpty || reg == '—') && profile != null) {
          final profileReg = profile.reg.trim().toUpperCase();
          if (profileReg.isNotEmpty) reg = profileReg;
        }
      }
      if (lookedUp.isEmpty) continue;
      final upgraded = _upgradeStudentIfNeeded(
        StudentRecord(
          id: student.id,
          name: student.name,
          registrationNumber:
              reg.isNotEmpty ? reg : student.registrationNumber,
          threeDigitCode: student.threeDigitCode,
          initials: student.initials,
        ),
        lookedUp,
        deriveStudentInitialsFromName(lookedUp),
      );
      byId[student.id] = upgraded;
      out[i] = upgraded;
    }

    return out;
  }

  Future<Map<String, ({String name, String reg})>> _lookupStudentProfilesByUserIds(
    Iterable<String> userIds,
  ) async {
    final ids = userIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return const {};

    final out = <String, ({String name, String reg})>{};
    const batchSize = 8;
    final list = ids.toList();

    for (var i = 0; i < list.length; i += batchSize) {
      final chunk = list.skip(i).take(batchSize);
      final snaps = await Future.wait(
        chunk.map((uid) async {
          try {
            final snap = await _firestore
                .collection(ApiCollections.appUsers)
                .doc(uid)
                .get();
            return (uid, snap);
          } catch (_) {
            return (uid, null);
          }
        }),
      );
      for (final (uid, snap) in snaps) {
        if (snap == null || !snap.exists || snap.data() == null) continue;
        final data = snap.data()!;
        final name = (data['fullName'] as String?)?.trim() ?? '';
        final reg =
            (data['registrationNumber'] as String?)?.trim().toUpperCase() ??
                '';
        if (name.isEmpty && reg.isEmpty) continue;
        out[uid] = (
          name: name.isNotEmpty ? name : 'Unknown',
          reg: reg.isNotEmpty ? reg : '—',
        );
      }
    }

    for (var i = 0; i < list.length; i += batchSize) {
      final chunk = list.skip(i).take(batchSize).toList();
      try {
        final snap = await _firestore
            .collection(ApiCollections.studentRegistrations)
            .where('uid', whereIn: chunk)
            .get();
        for (final doc in snap.docs) {
          final data = doc.data();
          if (data == null) continue;
          final uid = (data['uid'] as String?)?.trim() ?? '';
          if (uid.isEmpty || out.containsKey(uid)) continue;
          final name = (data['fullName'] as String?)?.trim() ?? '';
          final reg =
              (data['registrationNumber'] as String?)?.trim().toUpperCase() ??
                  doc.id.trim().toUpperCase();
          if (name.isEmpty) continue;
          out[uid] = (
            name: name,
            reg: reg.isNotEmpty ? reg : '—',
          );
        }
      } catch (_) {}
    }

    return out;
  }

  Future<Map<String, String>> _lookupFullNamesOnRegistrationDocs(
    Iterable<String> regs,
  ) async {
    final normalized = <String>{
      for (final raw in regs)
        if (StudentRegistrationNumber.normalize(raw).isNotEmpty)
          StudentRegistrationNumber.normalize(raw),
    };
    if (normalized.isEmpty) return const {};

    final out = <String, String>{};
    final list = normalized.toList();
    const batchSize = 10;
    for (var i = 0; i < list.length; i += batchSize) {
      final chunk = list.skip(i).take(batchSize);
      final results = await Future.wait(
        chunk.map((reg) async {
          final name = await _lookupFullNameOnRegistrationDoc(reg);
          return (reg, name);
        }),
      );
      for (final (reg, name) in results) {
        if (name != null && name.trim().isNotEmpty) {
          out[reg] = name.trim();
        }
      }
    }
    return out;
  }

  Future<String?> _lookupFullNameOnRegistrationDoc(String reg) async {
    final normalized = StudentRegistrationNumber.normalize(reg);
    if (normalized.isEmpty) return null;
    try {
      final snap = await _firestore
          .collection(ApiCollections.studentRegistrations)
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
      'date': apiDateToField(list.date),
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
        ? apiDateToField(list.lecturerSignedAt!)
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
    _listsCatalogFetchedAt = null;
    _notifyStoreUpdated(immediate: true);
    return persistOnlineFirst(
      timeout: _sessionPublishTimeout,
      persistOnline: () async {
        await _firestore
            .collection(ApiCollections.attendanceLists)
            .doc(list.id)
            .set(_listToMap(list));
        markListPublishedOnServer(list.id);
        await PendingListCreateQueue.removeByListId(list.id);
        unawaited(_persistScopedLocalSnapshot());
        _notifyStoreUpdated(immediate: true);
        return (list: list, syncedToServer: true);
      },
      persistOffline: () async {
        await PendingListCreateQueue.enqueue(
          list,
          pendingLecturerStaffNumber: pendingLecturerStaffNumber,
        );
        unawaited(_persistScopedLocalSnapshot());
        _notifyStoreUpdated(immediate: true);
        return (list: list, syncedToServer: false);
      },
    );
  }

  Future<void> updateList(AttendanceList list) async {
    AttendanceStore.updateList(list);
    try {
      await _firestore
          .collection(ApiCollections.attendanceLists)
          .doc(list.id)
          .set(_listToMap(list));
    } catch (_) {}
  }

  /// Resolves a registered lecturer account uid from KIU staff ID or registration number.
  Future<String?> resolveLecturerUidByStaffNumber(
    String rawStaffNumber, {
    Iterable<({String uid, String staffNumber})>? knownRows,
  }) async {
    final staffNumber = StaffAuthEmail.normalizeStaffNumberFlexible(rawStaffNumber);
    final registrationNumber = staffNumber == null &&
            KiuAdminRegistrationNumber.validateFormat(rawStaffNumber) == null
        ? KiuAdminRegistrationNumber.normalize(rawStaffNumber)
        : null;
    if (staffNumber == null && registrationNumber == null) return null;

    if (staffNumber != null && knownRows != null) {
      for (final row in knownRows) {
        if (row.staffNumber.trim().toUpperCase() == staffNumber) {
          return row.uid;
        }
      }
    }

    if (staffNumber != null) {
      final cachedUid = await StaffNumberDirectoryCache.lookup(staffNumber);
      if (cachedUid != null && cachedUid.isNotEmpty) {
        return cachedUid;
      }
    }

    final offline = !AppConnectivity.instance.isOnline;
    final cacheOptions =
        const ApiGetOptions(source: ApiSource.serverAndCache);

    if (staffNumber != null) {
      try {
        final staffSnap = await _firestore
            .collection(ApiCollections.staffNumbers)
            .doc(staffNumber)
            .get(offline ? cacheOptions : const ApiGetOptions());
        final fromStaff = (staffSnap.data()?['uid'] as String?)?.trim();
        if (fromStaff != null && fromStaff.isNotEmpty) {
          unawaited(StaffNumberDirectoryCache.remember(staffNumber, fromStaff));
          return fromStaff;
        }
      } catch (_) {}

      try {
        final lectSnap = await _firestore
            .collection(ApiCollections.lecturers)
            .where('staffNumber', isEqualTo: staffNumber)
            .limit(1)
            .get(offline ? cacheOptions : const ApiGetOptions());
        if (lectSnap.docs.isNotEmpty) {
          final uid = lectSnap.docs.first.id;
          unawaited(StaffNumberDirectoryCache.remember(staffNumber, uid));
          return uid;
        }
      } catch (_) {}
    }

    final registrationLookups = <String>{
      if (registrationNumber != null) registrationNumber,
      if (staffNumber != null) staffNumber,
    };
    for (final reg in registrationLookups) {
      try {
        final lectByRegSnap = await _firestore
            .collection(ApiCollections.lecturers)
            .where('registrationNumber', isEqualTo: reg)
            .limit(1)
            .get(offline ? cacheOptions : const ApiGetOptions());
        if (lectByRegSnap.docs.isNotEmpty) {
          final uid = lectByRegSnap.docs.first.id;
          if (staffNumber != null) {
            unawaited(StaffNumberDirectoryCache.remember(staffNumber, uid));
          }
          return uid;
        }
      } catch (_) {}
    }

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
    final normalized = LecturerRegistrationNumber.normalizeForLookup(manual);
    if (normalized == null) {
      return (
        uid: null,
        error:
            'Enter a valid KIU staff ID (${LecturerRegistrationNumber.exampleHint}).',
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
      final active = await SessionRtdSync.fetchActiveByCode(normalizedCode);
      return active.any((s) => s.id != sessionId);
    } catch (_) {
      return false;
    }
  }

  /// Regenerates the join code when another open session already owns it.
  Future<String> ensureJoinCodeForSessionUpload({
    required String sessionId,
    required String sessionCode,
    bool trustLocallyUnique = false,
  }) async {
    var code = normalizeSessionCodeInput(sessionCode);
    if (trustLocallyUnique) {
      final localClash = AttendanceStore.sessions.any(
        (s) =>
            s.id != sessionId &&
            normalizeSessionCodeInput(s.sessionCode) == code &&
            s.isOpenForCheckIn,
      );
      if (!localClash) return code;
    }
    for (var attempt = 0; attempt < 12; attempt++) {
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

    try {
      final rtdSessions = await SessionRtdSync.fetchActiveByCode(normalizedCode);
      for (final session in rtdSessions) {
        mergeSession(session);
      }
    } catch (_) {}

    // Closed/archived sessions remain in Firestore for replay and roll history.
    if (byId.length < limit) {
      final snap = await _firestore
          .collection(ApiCollections.attendanceSessions)
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
    final id = sessionId.trim();
    if (id.isEmpty) return false;
    if (_publishingSessionIds.contains(id)) return true;

    final queued = (await PendingSessionCreateQueue.loadAll())
        .any((e) => e.sessionId == id);
    if (!queued) return false;

    // Stale queue row — doc may already be on Firestore after a successful upload.
    if (await _lecturerSessionDocExistsOnServer(id)) {
      await PendingSessionCreateQueue.removeBySessionId(id);
      _sessionPublishedOnServerCache[id] = true;
      _sessionPublishedCacheAt = DateTime.now();
      _invalidateAwaitingUploadCache();
      _notifyStoreUpdated();
      return false;
    }
    return true;
  }

  Future<bool> _lecturerSessionDocExistsOnServer(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty || !AppConnectivity.instance.hasNetworkInterface) {
      return false;
    }
    if (await firestoreActiveSessionDocExists(id)) return true;
    return SessionRtdSync.isRunningOnRtd(id);
  }

  /// True when an active or closed session doc exists in Firestore (offline uploads).
  Future<bool> firestoreActiveSessionDocExists(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty || !AppConnectivity.instance.hasNetworkInterface) {
      return false;
    }
    try {
      final snap = await _firestore
          .collection(ApiCollections.attendanceSessions)
          .doc(id)
          .get(const ApiGetOptions(source: ApiSource.server))
          .timeout(_sessionPublishFastTimeout);
      if (!snap.exists) return false;
      final status =
          (snap.data()?['status'] as String?)?.trim().toLowerCase() ?? '';
      return status == SessionStatus.active.name ||
          status == SessionStatus.closed.name;
    } catch (_) {
      return false;
    }
  }

  /// Firestore payload for a running session (offline queue + server reconciliation).
  static Map<String, dynamic> activeSessionToFirestoreMapForSync({
    required AttendanceSession session,
    String? createdByUid,
    bool locationMetadataPending = false,
  }) {
    final sessionMap = <String, dynamic>{
      'listId': session.listId,
      'sessionCode': normalizeSessionCodeInput(session.sessionCode),
      'latitude': session.latitude,
      'longitude': session.longitude,
      'radiusMeters': session.radiusMeters,
      'startTime': apiDateToField(session.startTime),
      'endTime': apiDateToField(session.endTime),
      'status': SessionStatus.active.name,
      'createdBy': session.createdBy,
    };
    final uid = createdByUid?.trim();
    if (uid != null && uid.isNotEmpty) {
      sessionMap['createdByUid'] = uid;
    }
    if (session.remoteLearning) {
      sessionMap['remoteLearning'] = true;
    }
    if (locationMetadataPending && !session.remoteLearning) {
      sessionMap['locationMetadataPending'] = true;
    }
    return sessionMap;
  }

  void _invalidateAwaitingUploadCache() {
    _awaitingUploadSessionIdsCache = null;
    _awaitingUploadCacheAt = null;
  }

  /// Called after Firestore/RTD session publish (online or offline queue drain).
  void markSessionPublishedOnServer(String sessionId) {
    final id = sessionId.trim();
    if (id.isEmpty) return;
    _sessionPublishedOnServerCache[id] = true;
    _sessionPublishedCacheAt = DateTime.now();
    _invalidateAwaitingUploadCache();
  }

  void markListPublishedOnServer(String listId) {
    final id = listId.trim();
    if (id.isNotEmpty) {
      _listsPublishedOnServer.add(id);
    }
  }

  bool _isListKnownOnServer(String listId) =>
      _listsPublishedOnServer.contains(listId.trim());

  /// Keeps the Firestore channel warm before the lecturer taps Start session.
  Future<void> prewarmFirestoreForSessionCreate(String listId) async {
    final id = listId.trim();
    if (id.isEmpty || !AppConnectivity.instance.hasNetworkInterface) return;
    if (_isListKnownOnServer(id)) return;
    try {
      final snap = await _firestore
          .collection(ApiCollections.attendanceLists)
          .doc(id)
          .get(const ApiGetOptions(source: ApiSource.server))
          .timeout(_sessionPublishFastTimeout);
      if (snap.exists) {
        markListPublishedOnServer(id);
      }
    } catch (_) {}
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
    bool skipJoinCodeRecheck = false,
  }) async {
    final uploadCode = skipJoinCodeRecheck
        ? normalizeSessionCodeInput(sessionCode)
        : await ensureJoinCodeForSessionUpload(
            sessionId: sessionId,
            sessionCode: sessionCode,
            trustLocallyUnique: true,
          );
    if (uploadCode != session.sessionCode) {
      final existing = AttendanceStore.sessionById(sessionId);
      if (existing != null) {
        AttendanceStore.updateSession(
          AttendanceSession(
            id: existing.id,
            listId: existing.listId,
            sessionCode: uploadCode,
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
      'startTime': apiDateToField(startTime),
      'endTime': apiDateToField(endTime),
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
    if (!sessionMetadataReady && !remoteLearning) {
      sessionMap['locationMetadataPending'] = true;
    }

    Future<bool> attemptWrite() async {
      final published = await SessionRtdSync.publishRunningSession(
        uploadSession,
        createdByUid: creatorUid,
        locationMetadataPending:
            sessionMap['locationMetadataPending'] == true,
      );
      if (!published) return false;
      _sessionPublishedOnServerCache[sessionId] = true;
      _sessionPublishedCacheAt = DateTime.now();
      _invalidateAwaitingUploadCache();
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
      unawaited(prefetchSessionsForPendingCodes());
      unawaited(PendingSessionCodeSync.drainUrgent());
      return true;
    }

    for (var attempt = 0; attempt < _sessionUploadMaxAttempts; attempt++) {
      if (attempt > 0) {
        final baseMs = _sessionUploadBackoffMs[
            attempt < _sessionUploadBackoffMs.length
                ? attempt
                : _sessionUploadBackoffMs.length - 1];
        final jitter = math.Random().nextInt(80);
        await Future<void>.delayed(Duration(milliseconds: baseMs + jitter));
      }
      try {
        final ok = await attemptWrite();
        if (ok) return true;
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('_publishRunningSessionToRtd attempt $attempt: $e');
          debugPrint('$st');
        }
      }
      if (attempt + 1 >= _sessionUploadMaxAttempts) break;
    }
    return false;
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
        skipJoinCodeRecheck: true,
      );
      if (!uploaded) {
        await PendingSessionCreateQueue.enqueue(pendingEntry);
        unawaited(PendingSessionCreateSync.drainUrgent());
      }
    } finally {
      _publishingSessionIds.remove(sessionId);
      _schedulePersistScopedLocalSnapshot();
      _notifyStoreUpdated(refreshRecordWatch: true);
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
    _notifyStoreUpdated(refreshRecordWatch: true);
    _schedulePersistScopedLocalSnapshot();
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
              .collection(ApiCollections.attendanceLists)
              .doc(listId)
              .set(_listToMap(updated))
              .timeout(_sessionPublishTimeout)
              .then((_) => markListPublishedOnServer(listId))
              .catchError((_) {}),
        );
      }
    }
    final creatorUid = AuthRepository.instance.currentUserId?.trim();
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
    return (
      session: session,
      syncedToServer: false,
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
          .collection(ApiCollections.attendanceSessions)
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
          .collection(ApiCollections.checkInAttempts)
          .doc(docId)
          .get(_loadQueryOptions(force: false));
      if (!doc.exists) return false;
      final data = doc.data();
      if (data == null) return false;
      final status = (data['status'] as String?)?.trim().toLowerCase();
      if (status != 'pending' || data['awaitingSession'] != true) return false;
      final until = apiDateFromField(data['pendingUntil']);
      if (until != null && DateTime.now().isAfter(until)) {
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
      session ??= await SessionRtdSync.fetchById(hint);
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
        .where((e) => !e.hasLocalUploadEvidence)
        .map((e) => normalizeSessionCodeInput(e.sessionCodeRaw))
        .where((c) => c.isNotEmpty)
        .toSet();
    const chunkSize = 4;
    final codeList = codes.toList();
    for (var i = 0; i < codeList.length; i += chunkSize) {
      final end = i + chunkSize > codeList.length ? codeList.length : i + chunkSize;
      await Future.wait(
        codeList.sublist(i, end).map(resolveSessionByCode),
      );
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
        var list = AttendanceStore.listById(session.listId);
        list ??= await resolveListById(session.listId);
        return (session: session, list: list);
      }
      final hasNet = AppConnectivity.instance.isOnline ||
          AppConnectivity.instance.hasNetworkInterface;
      if ((session == null || !session.isOpenForCheckIn) && hasNet) {
        if (!AppConnectivity.instance.isOnline) {
          await AppConnectivity.instance.ensureReachable(
            timeout: const Duration(seconds: 2),
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
          .collection(ApiCollections.attendanceLists)
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

  Future<void> _archiveClosedSessionToFirestore(AttendanceSession session) async {
    final sessionMap = <String, dynamic>{
      'listId': session.listId,
      'sessionCode': normalizeSessionCodeInput(session.sessionCode),
      'latitude': session.latitude,
      'longitude': session.longitude,
      'radiusMeters': session.radiusMeters,
      'startTime': apiDateToField(session.startTime),
      'endTime': apiDateToField(session.endTime),
      'status': SessionStatus.closed.name,
      'createdBy': session.createdBy,
      'finalized': false,
      if (session.remoteLearning) 'remoteLearning': true,
    };
    final creatorUid = AuthRepository.instance.currentUserId?.trim();
    if (creatorUid != null && creatorUid.isNotEmpty) {
      sessionMap['createdByUid'] = creatorUid;
    }
    await _firestore
        .collection(ApiCollections.attendanceSessions)
        .doc(session.id)
        .set(sessionMap, ApiSetOptions(merge: true))
        .timeout(_sessionPublishTimeout);
  }

  Future<void> _syncSessionClosedToFirestore(String sessionId) async {
    final beforeClose = AttendanceStore.sessionById(sessionId);
    if (beforeClose == null) return;
    try {
      await _archiveClosedSessionToFirestore(
        AttendanceSession(
          id: beforeClose.id,
          listId: beforeClose.listId,
          sessionCode: beforeClose.sessionCode,
          latitude: beforeClose.latitude,
          longitude: beforeClose.longitude,
          radiusMeters: beforeClose.radiusMeters,
          startTime: beforeClose.startTime,
          endTime: beforeClose.endTime,
          status: SessionStatus.closed,
          createdBy: beforeClose.createdBy,
          remoteLearning: beforeClose.remoteLearning,
        ),
      );
      unawaited(SessionRtdSync.removeRunningSession(beforeClose.id));
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
  /// writes absent rows per student once their grace window ends (7-day cap or
  /// a later session on the same list is present/absent for that student).
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
      (e) => pendingSessionCodeBlocksSessionFinalize(e, session),
    )) {
      return;
    }

    final listId = session.listId;
    final studentIds =
        AttendanceStore.studentIdsForSessionRoll(listId, sessionId);

    final pendingCheckIns = await PendingCheckInQueue.loadAll();
    final pendingCodes = await PendingSessionCodeQueue.loadAll();

    final presentStudentIds = <String>{};
    for (final e in pendingCheckIns) {
      if (e.sessionId != sessionId) continue;
      if (pendingCheckInMatchesSessionForCorrection(e, session)) {
        presentStudentIds.add(e.studentId);
      }
    }
    for (final e in pendingCodes) {
      if (e.status == PendingSessionCodeStatus.invalidOrExpired) continue;
      final student =
          AttendanceStore.findStudentByReg(e.registrationNumber);
      if (student == null) continue;
      if (offlineQueuedSessionCodeTrustsPresent(
            entry: e,
            session: session,
            studentRegistrationNumber: student.registrationNumber,
          )) {
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
            .collection(ApiCollections.attendanceRecords)
            .where('sessionId', isEqualTo: sessionId)
            .get();
        for (final d in snap.docs) {
          final data = d.data();
          if (data == null || data['present'] != true) continue;
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
      final enrolledAt = AttendanceStore.earliestSignInAtForStudentOnList(
        listId,
        studentId,
      );
      final missedBeforeJoin =
          enrolledAt != null && session.endTime.isBefore(enrolledAt);
      final recordsForStudent = AttendanceStore.attendanceRecords
          .where((r) => r.studentId == studentId)
          .toList();
      if (!missedBeforeJoin &&
          !studentSessionGraceExpired(
            session: session,
            studentId: studentId,
            listId: listId,
            recordsForStudent: recordsForStudent,
          )) {
        continue;
      }
      if (await hasAwaitingStudentClaimOnServer(
        sessionCodeRaw: session.sessionCode,
        studentId: studentId,
      )) {
        continue;
      }
      if (await studentHasUnexpiredPendingEvidenceForSession(
        session: session,
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

  /// True when a pending or accepted check-in attempt exists on RTD or Firestore.
  Future<bool> checkInAttemptExistsOnServer(String recordId) async {
    final id = recordId.trim();
    if (id.isEmpty) return false;
    if (await CheckInRtdAttemptPublish.existsOnRtd(id)) return true;
    if (_firestoreIfReady == null) return false;
    try {
      final doc = await _firestore
          .collection(ApiCollections.checkInAttempts)
          .doc(id)
          .get(const ApiGetOptions(source: ApiSource.server))
          .timeout(_sessionPublishFastTimeout);
      return doc.exists;
    } catch (_) {
      return false;
    }
  }

  /// Whether a pending or accepted check-in attempt exists on Firestore.
  Future<bool> pendingSessionCodeHasServerEvidence({
    required PendingSessionCodeEntry entry,
    required String studentId,
    AttendanceSession? session,
  }) async {
    if (entry.hasLocalUploadEvidence) return true;
    final sid = canonicalStudentIdForUpload(studentId);
    if (sid.isEmpty) return false;

    final sessionId = entry.sessionId?.trim() ??
        session?.id.trim() ??
        '';
    if (sessionId.isNotEmpty) {
      final recordId = attendanceRecordIdForSessionStudent(sessionId, sid);
      if (await checkInAttemptExistsOnServer(recordId)) return true;
    }

    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (isValidJoinCodeFormat(code)) {
      if (await PendingSessionCodeClaimUpload.isClaimOnServer(
        entry: entry,
        studentId: sid,
      )) {
        return true;
      }
    }
    return false;
  }

  /// Accepted attempt or official present row on Firestore — safe to drop local queue.
  Future<bool> pendingSessionCodeResolvedOnServer({
    required PendingSessionCodeEntry entry,
    required String studentId,
    AttendanceSession? session,
  }) async {
    final sid = canonicalStudentIdForUpload(studentId);
    if (sid.isEmpty) return false;

    final sess = session ?? AttendanceStore.sessionById(entry.sessionId ?? '');
    if (sess == null) return false;

    if (await isCheckInAttemptAcceptedForSessionStudent(
      sessionId: sess.id,
      studentId: sid,
    )) {
      return true;
    }
    final recordId = attendanceRecordIdForSessionStudent(sess.id, sid);
    final remotePresent = await _remoteRecordIsPresent(recordId);
    return remotePresent;
  }

  /// Whether queued GPS check-in evidence reached Firestore (full or awaiting claim).
  Future<bool> pendingCheckInHasServerEvidence({
    required PendingCheckInEntry entry,
    AttendanceSession? session,
  }) async {
    if (entry.hasLocalUploadEvidence) return true;
    final canonicalId = canonicalStudentIdForUpload(entry.studentId);
    final recordId =
        attendanceRecordIdForSessionStudent(entry.sessionId, canonicalId);
    if (await checkInAttemptExistsOnServer(recordId)) return true;
    final sess = session ?? AttendanceStore.sessionById(entry.sessionId);
    final code = entry.sessionCodeRaw?.trim().isNotEmpty == true
        ? normalizeSessionCodeInput(entry.sessionCodeRaw!.trim())
        : (sess != null ? normalizeSessionCodeInput(sess.sessionCode) : null);
    if (code != null && code.isNotEmpty) {
      final claimId = PendingSessionCodeClaimUpload.claimDocId(
        normalizedCode: code,
        studentId: canonicalId,
      );
      if (await checkInAttemptExistsOnServer(claimId)) return true;
    }
    return false;
  }

  /// Whether the server accepted the attempt — upload alone stays queued.
  Future<bool> pendingCheckInIsApproved({
    required PendingCheckInEntry entry,
    AttendanceSession? session,
  }) async {
    final canonicalId = canonicalStudentIdForUpload(entry.studentId);
    final recordId =
        attendanceRecordIdForSessionStudent(entry.sessionId, canonicalId);
    if (await _isCheckInAttemptAccepted(recordId)) return true;

    final rtdStatus = await CheckInRtdAttemptPublish.readStatusOnRtd(recordId);
    if (rtdStatus == 'accepted') return true;

    final sess = session ?? AttendanceStore.sessionById(entry.sessionId);
    final code = entry.sessionCodeRaw?.trim().isNotEmpty == true
        ? normalizeSessionCodeInput(entry.sessionCodeRaw!.trim())
        : (sess != null ? normalizeSessionCodeInput(sess.sessionCode) : null);
    if (code != null && code.isNotEmpty) {
      final claimId = PendingSessionCodeClaimUpload.claimDocId(
        normalizedCode: code,
        studentId: canonicalId,
      );
      if (await _isCheckInAttemptAccepted(claimId)) return true;
      final claimRtd =
          await CheckInRtdAttemptPublish.readStatusOnRtd(claimId);
      if (claimRtd == 'accepted') return true;
    }

    final local = AttendanceStore.attendanceRecordForSessionStudent(
      entry.sessionId,
      entry.studentId,
    );
    if (local != null && local.present && local.verified) {
      return _remoteRecordIsPresent(recordId);
    }
    return false;
  }

  /// Corrects queue rows that were marked approved after upload only.
  Future<void> reconcilePendingCheckInQueueStatuses() async {
    final all = await PendingCheckInQueue.loadAll();
    if (all.isEmpty) return;
    var changed = false;
    final next = <PendingCheckInEntry>[];
    for (final e in all) {
      final session = AttendanceStore.sessionById(e.sessionId);
      final approved = await pendingCheckInIsApproved(
        entry: e,
        session: session,
      );
      final status = approved
          ? PendingCheckInQueueStatus.approved
          : PendingCheckInQueueStatus.queued;
      if (status != e.status) changed = true;
      next.add(e.copyWith(status: status));
    }
    if (changed) await PendingCheckInQueue.saveAll(next);
  }

  Future<void> _mergeSessionIntoStoreById(String sessionId) async {
    final trimmed = sessionId.trim();
    if (trimmed.isEmpty) return;
    if (AttendanceStore.sessionById(trimmed) != null) return;
    var session = await SessionRtdSync.fetchById(trimmed);
    session ??=
        (await _fetchSessionsByIds({trimmed}, force: true)).firstOrNull;
    if (session == null) return;
    final i = AttendanceStore.sessions.indexWhere((s) => s.id == session!.id);
    if (i >= 0) {
      AttendanceStore.updateSession(session);
    } else {
      AttendanceStore.addSession(session);
    }
  }

  /// Warms the local store with server sessions referenced by pending GPS check-ins.
  Future<void> prefetchSessionsForPendingCheckIns() async {
    if (!AppConnectivity.instance.hasNetworkInterface) return;
    final pending = await PendingCheckInQueue.loadAll();
    if (pending.isEmpty) return;
    final ids = pending
        .map((e) => e.sessionId.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    for (final id in ids) {
      await _mergeSessionIntoStoreById(id);
    }
  }

  /// Hydrates student registration + session metadata before replaying the queue.
  Future<void> prepareOfflineCheckInDrain() async {
    if (isStudentScopedUser()) {
      await AuthRepository.instance.ensureStudentRegistrationHydrated();
    }
    if (AppConnectivity.instance.hasNetworkInterface) {
      unawaited(
        AppConnectivity.instance.ensureReachable(
          timeout: _sessionPublishFastTimeout,
        ),
      );
    }
    await recoverUnqueuedLocalPresentCheckIns();
    await reconcilePendingCheckInQueueStatuses();
    await prefetchSessionsForPendingCheckIns();
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
    final canonicalId = canonicalStudentIdForUpload(studentId);
    if (canonicalId.isEmpty) {
      return _CheckInAttemptUploadResult.failed;
    }
    final docId = attendanceRecordIdForSessionStudent(sessionId, canonicalId);
    final uid = AuthRepository.instance.currentUserId?.trim();
    final code = sessionCodeRaw?.trim();
    await AuthRepository.instance.ensureStudentRegistrationHydrated();
    final reg = _registrationForCheckInUpload(canonicalId);
    final student = _studentRecordForId(canonicalId);
    final studentName = student?.name.trim();
    final sid = sessionId.trim();
    final lid = listId.trim();
    final awaiting = lid.isEmpty || sid.isEmpty;

    final rtdUploaded = await CheckInRtdAttemptPublish.uploadPending(
      recordId: docId,
      studentId: canonicalId,
      deviceId: deviceId,
      capturedAt: capturedAt,
      latitude: latitude,
      longitude: longitude,
      sessionId: sid.isNotEmpty ? sid : null,
      listId: lid.isNotEmpty ? lid : null,
      course: course,
      sessionCodeRaw: code,
      registrationNumber: reg,
      studentName: studentName,
      submittedByUid: uid,
      awaitingSession: awaiting,
    );
    if (!rtdUploaded) {
      return _CheckInAttemptUploadResult.failed;
    }

    unawaited(PendingCheckInQueue.markUploaded(docId));
    unawaited(ensureStudentDocOnServer(canonicalId));

    return _CheckInAttemptUploadResult.submitted;
  }

  /// Best-effort Firestore mirror when RTD already accepted the attempt.
  ///
  /// Normal client uploads use RTD only; [onCheckInAttemptRtdWritten] mirrors to
  /// Firestore server-side. Kept for tests or manual backfill — not called on
  /// the hot path after RTD success.
  Future<void> mirrorCheckInAttemptToFirestore({
    required String docId,
    required String sessionId,
    required String studentId,
    required String listId,
    required String course,
    required DateTime capturedAt,
    required double latitude,
    required double longitude,
    required String deviceId,
    String? sessionCodeRaw,
    String? registrationNumber,
    String? studentName,
    String? submittedByUid,
    bool awaitingSession = false,
    DateTime? pendingUntil,
  }) async {
    if (_firestoreIfReady == null) return;
    final canonicalId = canonicalStudentIdForUpload(studentId);
    final sid = sessionId.trim();
    final lid = listId.trim();
    final code = sessionCodeRaw?.trim().toUpperCase() ?? '';
    final courseVal = course.trim();
    final awaiting = awaitingSession || sid.isEmpty || lid.isEmpty;
    final reg = (registrationNumber?.trim().toUpperCase().isNotEmpty == true
            ? registrationNumber!.trim().toUpperCase()
            : null) ??
        _registrationForCheckInUpload(canonicalId)?.trim().toUpperCase() ??
        currentStudentLoadRegistration()?.trim().toUpperCase();
    try {
      final payload = <String, dynamic>{
        'studentId': canonicalId,
        'deviceId': deviceId,
        'status': 'pending',
        'capturedAt': apiDateToField(capturedAt),
        'latitude': latitude,
        'longitude': longitude,
        'awaitingSession': awaiting,
        if (pendingUntil != null)
          'pendingUntil': apiDateToField(pendingUntil),
        if (reg != null && reg.isNotEmpty) 'registrationNumber': reg,
        if (studentName != null && studentName.isNotEmpty)
          'studentName': studentName,
        if (submittedByUid != null && submittedByUid.isNotEmpty)
          'submittedByUid': submittedByUid,
        'clientSubmittedAt': ApiFieldValue.serverTimestamp(),
      };
      if (awaiting) {
        if (code.isNotEmpty) payload['sessionCodeRaw'] = code;
      } else {
        payload['sessionId'] = sid;
        payload['listId'] = lid;
        payload['course'] = courseVal.isNotEmpty ? courseVal : '—';
        if (code.isNotEmpty) payload['sessionCodeRaw'] = code;
      }
      await _firestore
          .collection(ApiCollections.checkInAttempts)
          .doc(docId)
          .set(payload, ApiSetOptions(merge: true))
          .timeout(_sessionPublishTimeout);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('mirrorCheckInAttemptToFirestore $docId: $e');
        debugPrint('$st');
      }
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
          .collection(ApiCollections.attendanceRecords)
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
          .collection(ApiCollections.checkInAttempts)
          .where('listId', isEqualTo: listId)
          .where('studentId', isEqualTo: studentId)
          .get()
          .timeout(_sessionPublishTimeout);
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data == null || data['status'] != 'rejected') continue;
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
    if (existing != null && existing.present) {
      return true;
    }

    return (await _serverAttemptMatchesSessionForStudent(
          listId: listId,
          session: session,
          studentId: studentId,
        )) !=
        null;
  }

  Future<void> _clearStalePendingEvidenceForOfficialAbsent({
    required String sessionId,
    required String studentId,
  }) async {
    final sid = sessionId.trim();
    final stu = studentId.trim();
    if (sid.isEmpty || stu.isEmpty) return;
    final now = DateTime.now();

    for (final e in await PendingCheckInQueue.loadAll()) {
      if (e.sessionId != sid || e.studentId != stu) continue;
      if (!PendingRetention.isExpired(e.pendingSince, now)) continue;
      await PendingCheckInQueue.removeById(e.id);
    }

    final student = AttendanceStore.students
        .where((s) => s.id == stu)
        .firstOrNull;
    final reg = student?.registrationNumber.trim().toUpperCase() ??
        stu.toUpperCase();
    for (final e in await PendingSessionCodeQueue.loadAll()) {
      if (e.registrationNumber.trim().toUpperCase() != reg) continue;
      final entrySession = e.sessionId?.trim() ?? '';
      if (entrySession.isNotEmpty && entrySession != sid) continue;
      if (!PendingRetention.isExpired(e.pendingSince, now)) continue;
      await PendingSessionCodeQueue.removeById(e.id);
    }
  }

  Future<bool> _shouldRetainLocalPresentOverOfficialAbsent({
    required String sessionId,
    required String studentId,
    required AttendanceRecord? existing,
  }) async {
    final session = AttendanceStore.sessionById(sessionId);
    if (session == null) return false;
    if (await studentHasUnexpiredPendingEvidenceForSession(
      session: session,
      studentId: studentId,
    )) {
      return true;
    }
    if (existing == null || !existing.present) return false;
    final id = attendanceRecordIdForSessionStudent(sessionId, studentId);
    if (await PendingCheckInQueue.containsRecordId(id)) return true;
    if (!existing.verified) {
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
    for (final sub in _checkInRtdWatchSubs.values) {
      unawaited(sub.cancel());
    }
    _checkInRtdWatchSubs.clear();
  }

  Future<void> _cancelCheckInWatchForRecord(String recordId) async {
    await _checkInAttemptWatchSubs.remove(recordId)?.cancel();
    await _checkInRtdWatchSubs.remove(recordId)?.cancel();
  }

  Future<void> _handleCheckInTerminalStatus({
    required String recordId,
    required String sessionId,
    required String studentId,
    required bool accepted,
  }) async {
    if (accepted) {
      final session = AttendanceStore.sessionById(sessionId);
      final local = AttendanceStore.attendanceRecordForSessionStudent(
        sessionId,
        studentId,
      );
      if (local != null && local.present && session != null) {
        unawaited(_upsertPendingCheckInFromRecord(
          record: local,
          listId: session.listId,
          course: local.course,
          status: PendingCheckInQueueStatus.approved,
        ));
      } else {
        await PendingCheckInQueue.markApproved(recordId);
      }
      _promoteLocalPresentToVerified(sessionId, studentId);
      unawaited(
        refreshOfficialRecordFromApi(
          sessionId: sessionId,
          studentId: studentId,
        ),
      );
    } else {
      final reason =
          await fetchCheckInAttemptRejectionReasonWithRetry(recordId);
      if (categorizeCheckInRejectionReason(reason) ==
          CheckInRejectionCategory.sessionMismatch) {
        await _retainOfflinePresentAfterMetadataRejection(
          recordId: recordId,
          sessionId: sessionId,
          studentId: studentId,
        );
        await _cancelCheckInWatchForRecord(recordId);
        return;
      }
      final session = AttendanceStore.sessionById(sessionId);
      final local = AttendanceStore.attendanceRecordForSessionStudent(
        sessionId,
        studentId,
      );
      if (local != null &&
          local.present &&
          session != null &&
          !PendingRetention.isExpired(local.timestamp, DateTime.now())) {
        await _upsertPendingCheckInFromRecord(
          record: local,
          listId: session.listId,
          course: local.course,
          sessionCodeRaw: normalizeSessionCodeInput(session.sessionCode),
        );
      }
      await clearLocalUnverifiedPresentForCheckIn(recordId, force: true);
    }
    await _cancelCheckInWatchForRecord(recordId);
  }

  /// Keeps optimistic present when the server rejects only on time/GPS/metadata.
  Future<void> _retainOfflinePresentAfterMetadataRejection({
    required String recordId,
    required String sessionId,
    required String studentId,
  }) async {
    final session = AttendanceStore.sessionById(sessionId);
    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      sessionId,
      studentId,
    );
    if (session == null || existing == null || !existing.present) return;
    if (!await PendingCheckInQueue.containsRecordId(recordId)) {
      await PendingCheckInQueue.enqueue(
        PendingCheckInEntry(
          id: recordId,
          sessionId: sessionId,
          studentId: studentId,
          listId: session.listId,
          course: existing.course,
          capturedAt: existing.timestamp,
          latitude: existing.latitude,
          longitude: existing.longitude,
          deviceId: existing.deviceId?.trim() ?? '',
        ),
      );
    }
    _notifyStoreUpdated();
  }

  /// Merges official rows as soon as Cloud Functions accept the attempt.
  void watchCheckInAttemptForStudent({
    required String recordId,
    required String sessionId,
    required String studentId,
    String? sessionCodeRaw,
  }) {
    final canonicalId = canonicalStudentIdForUpload(studentId);
    final code = normalizeSessionCodeInput(sessionCodeRaw ?? '');
    final rtdKey = checkInRtdConfirmationKey(
      sessionId: sessionId,
      sessionCodeRaw: code.isNotEmpty ? code : null,
    );
    final watchKeys = <String>{recordId.trim()};
    if (isValidJoinCodeFormat(code)) {
      final claimId = PendingSessionCodeClaimUpload.claimDocId(
        normalizedCode: code,
        studentId: canonicalId,
      );
      watchKeys.add(claimId);
    }

    for (final docId in watchKeys) {
      if (docId.isEmpty) continue;
      unawaited(_cancelCheckInWatchForRecord(docId));
      _attachCheckInAttemptFirestoreWatch(
        docId: docId,
        recordId: recordId,
        sessionId: sessionId,
        studentId: canonicalId,
      );
    }

    unawaited(_cancelCheckInRtdWatchForRecord(recordId));
    _checkInRtdWatchSubs[recordId] =
        CheckInRtdConfirmationWatch.watch(
      sessionId: rtdKey,
      studentId: canonicalId,
    ).listen(
      (conf) async {
        try {
          if (conf == null) return;
          if (conf.isAccepted) {
            await _handleCheckInTerminalStatus(
              recordId: recordId,
              sessionId: sessionId,
              studentId: canonicalId,
              accepted: true,
            );
          } else if (conf.isRejected) {
            await _handleCheckInTerminalStatus(
              recordId: recordId,
              sessionId: sessionId,
              studentId: canonicalId,
              accepted: false,
            );
          }
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('checkInRtd watch $recordId: $e');
            debugPrint('$st');
          }
        }
      },
      onError: (_) {},
    );
  }

  void _attachCheckInAttemptFirestoreWatch({
    required String docId,
    required String recordId,
    required String sessionId,
    required String studentId,
  }) {
    if (_firestoreIfReady == null) return;
    _checkInAttemptWatchSubs[docId] = _firestore
        .collection(ApiCollections.checkInAttempts)
        .doc(docId)
        .snapshots()
        .listen(
      (snap) async {
        try {
          if (!snap.exists) return;
          final status =
              (snap.data()?['status'] as String?)?.trim().toLowerCase() ?? '';
          if (status == 'accepted') {
            await _handleCheckInTerminalStatus(
              recordId: recordId,
              sessionId: sessionId,
              studentId: studentId,
              accepted: true,
            );
          } else if (status == 'rejected') {
            await _handleCheckInTerminalStatus(
              recordId: recordId,
              sessionId: sessionId,
              studentId: studentId,
              accepted: false,
            );
          }
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('checkInAttempt watch $docId: $e');
            debugPrint('$st');
          }
        }
      },
      onError: (Object e, StackTrace st) {
        if (kDebugMode) {
          debugPrint('checkInAttempt watch denied $docId: $e');
        }
      },
    );
  }

  Future<void> _cancelCheckInRtdWatchForRecord(String recordId) async {
    await _checkInRtdWatchSubs.remove(recordId)?.cancel();
  }

  /// Watches awaiting session-code claims and linked session attempts.
  void watchPendingSessionCodeClaim({
    required PendingSessionCodeEntry entry,
    required String studentId,
  }) {
    final code = normalizeSessionCodeInput(entry.sessionCodeRaw);
    if (!isValidJoinCodeFormat(code)) return;
    final canonicalId = canonicalStudentIdForUpload(studentId);
    final claimId = PendingSessionCodeClaimUpload.claimDocId(
      normalizedCode: code,
      studentId: canonicalId,
    );
    final sessionId = entry.sessionId?.trim() ?? '';
    final recordId = sessionId.isNotEmpty
        ? attendanceRecordIdForSessionStudent(sessionId, canonicalId)
        : claimId;
    watchCheckInAttemptForStudent(
      recordId: recordId,
      sessionId: sessionId.isNotEmpty ? sessionId : claimId,
      studentId: canonicalId,
      sessionCodeRaw: code,
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
      sessions.map((s) async {
        final fromRtd = await refreshOfficialRecordFromRtd(
          sessionId: s.id,
          studentId: studentId,
        );
        if (fromRtd == OfficialRecordRefreshResult.verifiedPresent ||
            fromRtd == OfficialRecordRefreshResult.officialAbsent) {
          return;
        }
        await refreshOfficialRecordFromApi(
          sessionId: s.id,
          studentId: studentId,
        );
      }),
    );
    _notifyStoreUpdated(immediate: true);
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

  /// Waits for server validation after upload (online check-ins), then refreshes stats.
  Future<bool> awaitCheckInVerificationAfterUpload({
    required String sessionId,
    required String studentId,
    String? sessionCodeRaw,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final recordId = attendanceRecordIdForSessionStudent(sessionId, studentId);
    final listId = AttendanceStore.sessionById(sessionId)?.listId;
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final local = AttendanceStore.attendanceRecordForSessionStudent(
        sessionId,
        studentId,
      );
      if (local?.verified == true) {
        await _refreshProfileStatsAfterCheckIn(
          sessionId: sessionId,
          studentId: studentId,
          listId: listId,
        );
        return true;
      }

      if (await _tryQuickVerifyAfterCheckInUpload(
        sessionId: sessionId,
        studentId: studentId,
        recordId: recordId,
        sessionCodeRaw: sessionCodeRaw,
      )) {
        return true;
      }

      if (await isCheckInAttemptRejected(recordId)) return false;

      await Future<void>.delayed(const Duration(milliseconds: 180));
    }

    return AttendanceStore.attendanceRecordForSessionStudent(
              sessionId,
              studentId,
            )?.verified ==
        true;
  }

  /// Pulls fresh list roll stats after a verified check-in (RTD + local merge).
  Future<AttendanceRollStats> listRollStatsAfterVerifiedCheckIn({
    required String sessionId,
    required String studentId,
    required String listId,
    bool refreshFromServer = true,
  }) async {
    if (refreshFromServer) {
      await _refreshProfileStatsAfterCheckIn(
        sessionId: sessionId,
        studentId: studentId,
        listId: listId,
      );
    }
    final student = _studentRecordForId(studentId);
    final reg = student?.registrationNumber.trim().toUpperCase() ??
        _registrationForCheckInUpload(studentId)?.trim().toUpperCase() ??
        AuthRepository.instance.currentRegistrationNumber?.trim().toUpperCase() ??
        '';
    if (reg.isEmpty) {
      return const AttendanceRollStats(present: 0, total: 0);
    }
    return AttendanceStore.rollStatsForRegistrationOnList(reg, listId.trim());
  }

  Future<bool> _applyAcceptedCheckInConfirmation({
    required String sessionId,
    required String studentId,
  }) async {
    final listId = AttendanceStore.sessionById(sessionId)?.listId;
    for (final sid in studentIdsForRecordWatch()) {
      final fromRtd = await refreshOfficialRecordFromRtd(
        sessionId: sessionId,
        studentId: sid,
      );
      if (fromRtd == OfficialRecordRefreshResult.verifiedPresent) {
        await _refreshProfileStatsAfterCheckIn(
          sessionId: sessionId,
          studentId: studentId,
          listId: listId,
        );
        return true;
      }
    }
    _promoteLocalPresentToVerified(sessionId, studentId);
    await _refreshProfileStatsAfterCheckIn(
      sessionId: sessionId,
      studentId: studentId,
      listId: listId,
    );
    unawaited(
      refreshOfficialRecordFromApi(
        sessionId: sessionId,
        studentId: studentId,
      ),
    );
    return true;
  }

  Future<bool> _tryQuickVerifyAfterCheckInUpload({
    required String sessionId,
    required String studentId,
    required String recordId,
    String? sessionCodeRaw,
  }) async {
    if (await _isCheckInAttemptAccepted(recordId)) {
      _promoteLocalPresentToVerified(sessionId, studentId);
      await _refreshProfileStatsAfterCheckIn(
        sessionId: sessionId,
        studentId: studentId,
        listId: AttendanceStore.sessionById(sessionId)?.listId,
      );
      unawaited(
        refreshOfficialRecordFromApi(
          sessionId: sessionId,
          studentId: studentId,
        ),
      );
      return true;
    }

    final rtdKey = checkInRtdConfirmationKey(
      sessionId: sessionId,
      sessionCodeRaw: sessionCodeRaw ??
          AttendanceStore.sessionById(sessionId)?.sessionCode,
    );
    final rtdConf = await CheckInRtdConfirmationWatch.awaitTerminal(
      sessionId: rtdKey,
      studentId: studentId,
      timeout: const Duration(milliseconds: 900),
      pollInterval: const Duration(milliseconds: 120),
    );
    if (rtdConf?.isAccepted == true) {
      return _applyAcceptedCheckInConfirmation(
        sessionId: sessionId,
        studentId: studentId,
      );
    }
    if (rtdConf?.isRejected == true) {
      return false;
    }

    const fastDelaysMs = [25, 50, 80, 120, 180, 250, 350];
    for (var i = 0; i < fastDelaysMs.length; i++) {
      if (await _isCheckInAttemptAccepted(recordId)) {
        _promoteLocalPresentToVerified(sessionId, studentId);
        await _refreshProfileStatsAfterCheckIn(
          sessionId: sessionId,
          studentId: studentId,
          listId: AttendanceStore.sessionById(sessionId)?.listId,
        );
        unawaited(
          refreshOfficialRecordFromApi(
            sessionId: sessionId,
            studentId: studentId,
          ),
        );
        return true;
      }
      final result = await refreshOfficialRecordFromApi(
        sessionId: sessionId,
        studentId: studentId,
      );
      if (result == OfficialRecordRefreshResult.verifiedPresent) {
        await _refreshProfileStatsAfterCheckIn(
          sessionId: sessionId,
          studentId: studentId,
          listId: AttendanceStore.sessionById(sessionId)?.listId,
        );
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
    final verified = await awaitOfficialRecordFromApi(
      sessionId: sessionId,
      studentId: studentId,
      timeout: const Duration(seconds: 15),
    );
    if (verified) return;
    if (!await PendingCheckInQueue.containsRecordId(recordId) &&
        await _isCheckInAttemptAccepted(recordId)) {
      _promoteLocalPresentToVerified(sessionId, studentId);
      unawaited(
        _refreshProfileStatsAfterCheckIn(
          sessionId: sessionId,
          studentId: studentId,
          listId: AttendanceStore.sessionById(sessionId)?.listId,
        ),
      );
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

  /// Merges one official row from Firestore or Realtime Database.
  Future<void> applyRemoteAttendanceRecord(
    AttendanceRecord official, {
    bool immediate = false,
  }) async {
    try {
      await _applyRemoteAttendanceRecordBody(
        official,
        immediate: immediate,
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('applyRemoteAttendanceRecord failed: $e');
        debugPrint('$st');
      }
    }
  }

  Future<void> _applyRemoteAttendanceRecordBody(
    AttendanceRecord official, {
    bool immediate = false,
  }) async {
    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      official.sessionId,
      official.studentId,
    );

    if (official.present && official.verified) {
      if (existing != null &&
          existing.present &&
          existing.verified &&
          existing.id == official.id) {
        return;
      }
      if (existing != null) {
        AttendanceStore.updateAttendanceRecord(official);
      } else {
        AttendanceStore.addAttendanceRecord(official);
      }
      final session = AttendanceStore.sessionById(official.sessionId);
      unawaited(_upsertPendingCheckInFromRecord(
        record: official,
        listId: session?.listId ?? '',
        course: official.course,
        status: PendingCheckInQueueStatus.approved,
      ));
      AttendanceStore.invalidateLookupCaches();
      _invalidateRollStatsAfterRecordMerge(official);
      _schedulePersistScopedLocalSnapshot();
      _notifyStoreUpdated(immediate: true);
      if (session != null) {
        unawaited(_backfillPriorSessionsAfterPresentResolved(
          listId: session.listId,
          studentId: official.studentId,
        ));
      }
      return;
    }

    final queued = await PendingCheckInQueue.containsRecordId(official.id);
    final retainLocalPresent = !official.present &&
        await _shouldRetainLocalPresentOverOfficialAbsent(
          sessionId: official.sessionId,
          studentId: official.studentId,
          existing: existing,
        );
    final sessionForOfficial = AttendanceStore.sessionById(official.sessionId);
    final pendingEvidence = sessionForOfficial != null &&
        await studentHasUnexpiredPendingEvidenceForSession(
          session: sessionForOfficial,
          studentId: official.studentId,
        );
    if (!official.present && (queued || retainLocalPresent || pendingEvidence)) {
      return;
    }
    if (existing != null) {
      if (!official.present &&
          existing.present &&
          !existing.verified &&
          (queued || retainLocalPresent || pendingEvidence)) {
        return;
      }
      AttendanceStore.updateAttendanceRecord(official);
    } else {
      AttendanceStore.addAttendanceRecord(official);
    }
    if (official.present && official.verified) {
      final session = AttendanceStore.sessionById(official.sessionId);
      unawaited(_upsertPendingCheckInFromRecord(
        record: official,
        listId: session?.listId ?? '',
        course: official.course,
        status: PendingCheckInQueueStatus.approved,
      ));
    } else if (!official.present && !pendingEvidence) {
      unawaited(PendingCheckInQueue.markApproved(official.id));
      unawaited(_clearStalePendingEvidenceForOfficialAbsent(
        sessionId: official.sessionId,
        studentId: official.studentId,
      ));
    }
    AttendanceStore.invalidateLookupCaches();
    _invalidateRollStatsAfterRecordMerge(official);
    _schedulePersistScopedLocalSnapshot();
    _notifyStoreUpdated(immediate: immediate);
    if (official.present) {
      final session = AttendanceStore.sessionById(official.sessionId);
      if (session != null) {
        unawaited(_backfillPriorSessionsAfterPresentResolved(
          listId: session.listId,
          studentId: official.studentId,
        ));
      }
    }
  }

  void _invalidateRollStatsAfterRecordMerge(AttendanceRecord official) {
    final session = AttendanceStore.sessionById(official.sessionId);
    if (session == null) return;
    final ids = <String>{official.studentId.trim()};
    final student = AttendanceStore.students
        .where((s) => s.id.trim() == official.studentId.trim())
        .firstOrNull;
    if (student != null) {
      ids.addAll(
        AttendanceStore.studentIdsForRegistrationNormalized(
          student.registrationNumber,
        ),
      );
    }
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg != null && reg.isNotEmpty) {
      ids.addAll(AttendanceStore.studentIdsForRegistrationNormalized(reg));
    }
    ids.removeWhere((id) => id.isEmpty);
    AttendanceStore.invalidateRollStatsForStudentIdsOnList(
      ids,
      session.listId,
    );
  }

  /// After a **present** row lands, promote pending evidence then backfill older
  /// sessions — never run from absent-only remote rows.
  Future<void> _backfillPriorSessionsAfterPresentResolved({
    required String listId,
    required String studentId,
  }) async {
    try {
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
      await backfillPastAbsentsForStudentOnList(listId, studentId);
      await _requestServerAbsentBackfill(listId, studentId);
    } catch (_) {}
  }

  Future<bool> _isCheckInAttemptAccepted(String recordId) async {
    if (_firestoreIfReady == null) return false;
    try {
      final doc = await _firestore
          .collection(ApiCollections.checkInAttempts)
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
    final verified = _recordWithVerified(existing, true);
    AttendanceStore.updateAttendanceRecord(verified);
    AttendanceStore.invalidateLookupCaches();
    _invalidateRollStatsAfterRecordMerge(verified);
    _notifyStoreUpdated(immediate: true);
    final session = AttendanceStore.sessionById(sessionId);
    unawaited(
      _refreshProfileStatsAfterCheckIn(
        sessionId: sessionId,
        studentId: studentId,
        listId: session?.listId,
      ),
    );
  }

  /// Instant profile % refresh after check-in is accepted or verified locally.
  Future<void> _refreshProfileStatsAfterCheckIn({
    required String sessionId,
    required String studentId,
    String? listId,
  }) async {
    final session = AttendanceStore.sessionById(sessionId);
    final lid = listId?.trim().isNotEmpty == true
        ? listId!.trim()
        : session?.listId.trim() ?? '';

    await StudentRtdIndex.publishCurrentStudentRegistration();
    unawaited(
      AttendanceRtdRecordWatch.instance.primeAfterStudentCheckIn(
        sessionId: sessionId,
        studentId: studentId,
        listId: lid.isNotEmpty ? lid : null,
      ),
    );

    if (!AppConnectivity.instance.isOnline) {
      notifyStoreUpdatedFromRtd();
      return;
    }

    for (final sid in studentIdsForRecordWatch()) {
      final fromRtd = await refreshOfficialRecordFromRtd(
        sessionId: sessionId,
        studentId: sid,
      );
      if (fromRtd == OfficialRecordRefreshResult.verifiedPresent ||
          fromRtd == OfficialRecordRefreshResult.officialAbsent) {
        break;
      }
    }

    if (lid.isNotEmpty) {
      touchRecentListDetail(lid);
      await refreshStudentListAttendanceFromRtd(lid);
    } else {
      await refreshStudentProfileFromRtd();
    }
    notifyStoreUpdatedFromRtd();
  }

  /// After a successful check-in, keeps polling until the official row lands and
  /// refreshes list detail / student stats for immediate UI updates.
  Future<void> notifyAttendanceAfterCheckIn({
    required String sessionId,
    required String studentId,
    String? listId,
    String? sessionCodeRaw,
  }) async {
    final recordId = attendanceRecordIdForSessionStudent(sessionId, studentId);
    final row = AttendanceStore.attendanceRecordForSessionStudent(
      sessionId,
      studentId,
    );
    if (row != null) {
      _invalidateRollStatsAfterRecordMerge(row);
      notifyStoreUpdatedFromRtd();
    }

    final code = sessionCodeRaw?.trim().isNotEmpty == true
        ? sessionCodeRaw
        : AttendanceStore.sessionById(sessionId)?.sessionCode;
    watchCheckInAttemptForStudent(
      recordId: recordId,
      sessionId: sessionId,
      studentId: studentId,
      sessionCodeRaw: code,
    );

    unawaited(() async {
      await _refreshProfileStatsAfterCheckIn(
        sessionId: sessionId,
        studentId: studentId,
        listId: listId,
      );
      final official = AttendanceStore.attendanceRecordForSessionStudent(
        sessionId,
        studentId,
      );
      if (official?.verified != true) {
        await _continueVerifyInBackground(
          sessionId: sessionId,
          studentId: studentId,
          recordId: recordId,
        );
        await _refreshProfileStatsAfterCheckIn(
          sessionId: sessionId,
          studentId: studentId,
          listId: listId,
        );
      }
      _schedulePersistScopedLocalSnapshot();
    }());
  }

  /// Pulls one official row from Realtime Database into [AttendanceStore].
  Future<OfficialRecordRefreshResult> refreshOfficialRecordFromRtd({
    required String sessionId,
    required String studentId,
  }) async {
    final db = null /* RTD disabled */;
    if (db == null) return OfficialRecordRefreshResult.notFound;
    final sid = sessionId.trim();
    final stu = studentId.trim();
    if (sid.isEmpty || stu.isEmpty) {
      return OfficialRecordRefreshResult.notFound;
    }
    try {
      final snap = await db
          .ref(AttendanceRecordRtdSync.studentRecordsPath(stu))
          .child(sid)
          .get()
          .timeout(const Duration(seconds: 3));
      if (!snap.exists) return OfficialRecordRefreshResult.notFound;
      final official = AttendanceRecordRtdSync.recordFromRtdValue(
        sessionId: sid,
        studentId: stu,
        value: snap.value,
      );
      if (official == null) return OfficialRecordRefreshResult.notFound;
      await applyRemoteAttendanceRecord(official, immediate: true);
      if (official.present && official.verified) {
        return OfficialRecordRefreshResult.verifiedPresent;
      }
      if (!official.present) {
        return OfficialRecordRefreshResult.officialAbsent;
      }
      return OfficialRecordRefreshResult.notFound;
    } catch (_) {
      return OfficialRecordRefreshResult.notFound;
    }
  }

  /// Pulls one official row from Firebase into [AttendanceStore].
  Future<OfficialRecordRefreshResult> refreshOfficialRecordFromApi({
    required String sessionId,
    required String studentId,
  }) async {
    final id = attendanceRecordIdForSessionStudent(sessionId, studentId);
    try {
      final doc = await _firestore
          .collection(ApiCollections.attendanceRecords)
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
  Future<bool> awaitOfficialRecordFromApi({
    required String sessionId,
    required String studentId,
    Duration? timeout,
  }) async {
    final online = AppConnectivity.instance.isOnline;
    final effectiveTimeout = timeout ??
        (online ? const Duration(seconds: 8) : const Duration(seconds: 12));
    final id = attendanceRecordIdForSessionStudent(sessionId, studentId);

    final rtdWaitMs = math.min(
      effectiveTimeout.inMilliseconds,
      online ? 2500 : 4000,
    );
    final rtdKey = checkInRtdConfirmationKey(
      sessionId: sessionId,
      sessionCodeRaw: AttendanceStore.sessionById(sessionId)?.sessionCode,
    );
    final rtdConf = await CheckInRtdConfirmationWatch.awaitTerminal(
      sessionId: rtdKey,
      studentId: studentId,
      timeout: Duration(milliseconds: rtdWaitMs),
    );
    if (rtdConf?.isAccepted == true) {
      return _applyAcceptedCheckInConfirmation(
        sessionId: sessionId,
        studentId: studentId,
      );
    }
    if (rtdConf?.isRejected == true) {
      await clearLocalUnverifiedPresentForCheckIn(id, force: true);
      return false;
    }

    final deadline = DateTime.now().add(effectiveTimeout);
    var pollIndex = 0;
    const pollScheduleMs = [100, 150, 200, 300, 400, 500, 600, 800];

    Future<OfficialRecordRefreshResult> pollOnce() async {
      if (await _isCheckInAttemptAccepted(id)) {
        _promoteLocalPresentToVerified(sessionId, studentId);
        unawaited(
          _refreshProfileStatsAfterCheckIn(
            sessionId: sessionId,
            studentId: studentId,
            listId: AttendanceStore.sessionById(sessionId)?.listId,
          ),
        );
      }
      final fromRtd = await refreshOfficialRecordFromRtd(
        sessionId: sessionId,
        studentId: studentId,
      );
      if (fromRtd == OfficialRecordRefreshResult.verifiedPresent ||
          fromRtd == OfficialRecordRefreshResult.officialAbsent) {
        return fromRtd;
      }
      return refreshOfficialRecordFromApi(
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
        return false;
      }
      if (retain) {
        // Server may still be upgrading absent → present; keep polling.
      }
    }
    if (await isCheckInAttemptRejected(id)) {
      await refreshOfficialRecordFromApi(
        sessionId: sessionId,
        studentId: studentId,
      );
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
          return false;
        }
      }
      if (await isCheckInAttemptRejected(id)) {
        await refreshOfficialRecordFromApi(
          sessionId: sessionId,
          studentId: studentId,
        );
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
    record = _attendanceRecordWithCanonicalStudentId(record);

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
      await _ensureCheckInListedInQueue(
        record: record,
        listIdOverride: listIdOverride,
        course: _resolvePresentCourseForSession(
          record.sessionId,
          record.studentId,
          record.course,
        ),
      );
      return StudentOfflineCheckInOutcome.duplicate;
    }
    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      record.sessionId,
      record.studentId,
    );
    if (existing != null) {
      if (existing.present && existing.verified) {
        await _ensureCheckInListedInQueue(
          record: existing,
          listIdOverride: listIdOverride,
          course: _resolvePresentCourseForSession(
            record.sessionId,
            record.studentId,
            existing.course,
          ),
          status: PendingCheckInQueueStatus.approved,
        );
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

    if (record.present) {
      final sessionForList = AttendanceStore.sessionById(record.sessionId);
      final listIdForQueue = (listIdOverride?.trim().isNotEmpty == true
              ? listIdOverride!.trim()
              : null) ??
          sessionForList?.listId ??
          '';
      final codeForQueue = (sessionCodeRaw?.trim().isNotEmpty == true
              ? normalizeSessionCodeInput(sessionCodeRaw!.trim())
              : null) ??
          (sessionForList != null
              ? normalizeSessionCodeInput(sessionForList.sessionCode)
              : null);
      await _upsertPendingCheckInFromRecord(
        record: localRow,
        listId: listIdForQueue,
        course: resolvedCourse,
        sessionCodeRaw: codeForQueue,
      );
      if (codeForQueue != null &&
          codeForQueue.isNotEmpty &&
          (record.deviceId?.trim().isNotEmpty ?? false)) {
        final student = await _studentForCheckInUpload(record.studentId);
        if (student != null) {
          await _upsertPendingSessionCodeEntry(
            PendingSessionCodeEntry(
              id: '${codeForQueue}_${student.registrationNumber.trim().toUpperCase()}',
              registrationNumber: student.registrationNumber,
              sessionCodeRaw: codeForQueue,
              capturedAt: record.timestamp,
              latitude: record.latitude,
              longitude: record.longitude,
              deviceId: record.deviceId!.trim(),
              sessionId: sessionForList?.id,
              listId: listIdForQueue.isNotEmpty ? listIdForQueue : null,
            ),
          );
        }
      }
    }

    if (record.present &&
        await _shouldUseAwaitingSessionClaimPath(record.sessionId)) {
      final student = await _studentForCheckInUpload(record.studentId);
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
          sessionId: session.id,
          listId: session.listId,
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
          await _upsertPendingSessionCodeEntry(claimEntry);
          await _upsertPendingCheckInFromRecord(
            record: localRow,
            listId: session.listId,
            course: resolvedCourse,
          );
          return StudentOfflineCheckInOutcome.submittedPendingVerification;
        }
        _applyLocalPresentCheckInRow(
          localRow,
          existing: existing,
          sessionId: record.sessionId,
          studentId: record.studentId,
        );
        await PendingSessionCodeQueue.enqueue(claimEntry);
        await _enqueuePendingCheckInRow(
          localRow: localRow,
          listId: session.listId,
          course: resolvedCourse,
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
      await Future<void>.delayed(const Duration(milliseconds: 80));
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
      final student = await _studentForCheckInUpload(record.studentId);
      final session = AttendanceStore.sessionById(record.sessionId);
      if (student != null && record.present) {
        final d = record.deviceId?.trim() ?? '';
        final claimCode = codeForAttempt ??
            (session != null
                ? normalizeSessionCodeInput(session.sessionCode)
                : null);
        if (d.isNotEmpty && claimCode != null && claimCode.isNotEmpty) {
          final claimEntry = PendingSessionCodeEntry(
            id: '${claimCode}_${student.registrationNumber.trim().toUpperCase()}',
            registrationNumber: student.registrationNumber,
            sessionCodeRaw: claimCode,
            capturedAt: record.timestamp,
            latitude: record.latitude,
            longitude: record.longitude,
            deviceId: d,
            sessionId: session?.id,
            listId: listId.isNotEmpty ? listId : session?.listId,
          );
          final claimUploaded =
              await PendingSessionCodeClaimUpload.uploadForEntryWithStudent(
            entry: claimEntry,
            studentId: student.id,
          );
          if (claimUploaded) {
            if (session != null) {
              PendingSessionCodeSync.ensureWatchingSessionPublishForCodes(
                [session.sessionCode],
              );
            } else {
              PendingSessionCodeSync.ensureWatchingSessionPublishForCodes(
                [claimCode],
              );
            }
            _applyLocalPresentCheckInRow(
              localRow,
              existing: existing,
              sessionId: record.sessionId,
              studentId: record.studentId,
            );
            await _upsertPendingSessionCodeEntry(claimEntry);
            await _upsertPendingCheckInFromRecord(
              record: localRow,
              listId: listId,
              course: resolvedCourse,
              sessionCodeRaw: claimCode,
            );
            return StudentOfflineCheckInOutcome.submittedPendingVerification;
          }
        }
      }
      _applyLocalPresentCheckInRow(
        localRow,
        existing: existing,
        sessionId: record.sessionId,
        studentId: record.studentId,
      );
      await _upsertPendingCheckInFromRecord(
        record: localRow,
        listId: listId,
        course: resolvedCourse,
        sessionCodeRaw: codeForAttempt,
      );
      return StudentOfflineCheckInOutcome.queuedOffline;
    }
    if (submitted) {
      _applyLocalPresentCheckInRow(
        localRow,
        existing: existing,
        sessionId: record.sessionId,
        studentId: record.studentId,
      );
      await _upsertPendingCheckInFromRecord(
        record: localRow,
        listId: listId,
        course: resolvedCourse,
        sessionCodeRaw: codeForAttempt,
      );
      var verified = false;
      try {
        verified = await _tryQuickVerifyAfterCheckInUpload(
          sessionId: record.sessionId,
          studentId: record.studentId,
          recordId: record.id,
          sessionCodeRaw: codeForAttempt,
        ).timeout(
          AppConnectivity.instance.isOnline
              ? const Duration(milliseconds: 1100)
              : const Duration(milliseconds: 300),
          onTimeout: () => false,
        );
      } catch (_) {
        verified = false;
      }
      _notifyStoreUpdated();
      unawaited(_backfillPriorSessionsAfterPresentResolved(
        listId: listId,
        studentId: record.studentId,
      ));
      unawaited(
        notifyAttendanceAfterCheckIn(
          sessionId: record.sessionId,
          studentId: record.studentId,
          listId: listId,
          sessionCodeRaw: codeForAttempt,
        ),
      );
      if (verified) {
        await _upsertPendingCheckInFromRecord(
          record: localRow,
          listId: listId,
          course: resolvedCourse,
          status: PendingCheckInQueueStatus.approved,
          sessionCodeRaw: codeForAttempt,
        );
        return StudentOfflineCheckInOutcome.success;
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
      unawaited(PendingCheckInQueue.markUploaded(record.id));
      await _upsertPendingCheckInFromRecord(
        record: localRow,
        listId: listId,
        course: resolvedCourse,
      );
      return StudentOfflineCheckInOutcome.submittedPendingVerification;
    }

    _applyLocalPresentCheckInRow(
      localRow,
      existing: existing,
      sessionId: record.sessionId,
      studentId: record.studentId,
    );
    await _enqueuePendingCheckInRow(
      localRow: localRow,
      listId: listId,
      course: resolvedCourse,
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
  /// (security rules require it). [attendance_records], [check_in_attempts],
  /// [device_session_locks], and Realtime Database mirrors are server-only;
  /// `onAttendanceListDeleted` removes those via Admin SDK.
  Future<void> _cascadeDeleteListDocsClient(String listId) async {
    final trimmed = listId.trim();
    if (trimmed.isEmpty) return;

    final sessionDocs = await _queryDocsWhereFieldEquals(
      collection: _firestore.collection(ApiCollections.attendanceSessions),
      field: 'listId',
      values: [trimmed],
    );
    final sessionIds = sessionDocs
        .map((d) => d.id)
        .where((id) => id.trim().isNotEmpty)
        .toList();

    final signInDocs = await _queryDocsWhereFieldEquals(
      collection: _firestore.collection(ApiCollections.signIns),
      field: 'listId',
      values: [trimmed],
    );

    final noticesCol = _firestore.collection(ApiCollections.notices);
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
          .collection(ApiCollections.attendanceLists)
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
    if (!AppConnectivity.instance.isOnline) return null;
    try {
      final snap = await _firestore
          .collection(ApiCollections.studentRegistrations)
          .doc(normalized)
          .get();
      if (!snap.exists || snap.data() == null) return null;
      final data = snap.data()!;
      final ownerUid = (data['uid'] as String?)?.trim() ?? '';
      final currentUid =
          AuthRepository.instance.currentUserId?.trim() ?? '';
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

    final displayName = ApiAuth.instance.currentUser?.displayName?.trim();
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
    String initials, {
    bool fast = false,
  }) async {
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
      await _persistStudentRecord(
        upgraded,
        awaitWhenOnline: !fast,
      );
      return upgraded;
    }
    final record = AttendanceStore.registerStudent(
      trimmedName,
      normalized,
      trimmedIni,
    );
    await _persistStudentRecord(
      record,
      awaitWhenOnline: !fast,
    );
    if (!fast) {
      await _bindDeviceRegistrationIfNeeded(normalized);
    } else {
      unawaited(_bindDeviceRegistrationIfNeeded(normalized));
    }
    return record;
  }

  /// Creates a roster row using the signed-in user's registered full name.
  Future<StudentRecord?> registerStudentFromAuthProfile(
    String registrationNumber, {
    bool fast = false,
  }) async {
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
    Future<String?> nameFuture = _resolveRegisteredFullNameForReg(effectiveReg);
    if (fast) {
      final cached = AuthRepository.instance.currentFullName?.trim();
      if (cached != null && cached.isNotEmpty) {
        nameFuture = Future<String?>.value(cached);
      } else {
        nameFuture = nameFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () => null,
        );
      }
    }
    final name = await nameFuture;
    if (existing != null) {
      var reconciled = _reconcileStudentIdToRegistration(existing);
      if (name != null && name.isNotEmpty) {
        reconciled = _upgradeStudentIfNeeded(
          reconciled,
          name,
          initialsFromFullName(name),
        );
        await _persistStudentRecord(
          reconciled,
          awaitWhenOnline: !fast,
        );
        return reconciled;
      }
      await _persistStudentRecord(
        reconciled,
        awaitWhenOnline: !fast,
      );
      return reconciled;
    }
    if (name == null || name.isEmpty) return null;
    return registerStudent(
      name,
      effectiveReg,
      initialsFromFullName(name),
      fast: fast,
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

  /// When [deferHeavyWork] is true, writes local enrollment metadata only and
  /// uploads to Firestore in the background (interactive student check-in).
  Future<void> addSignIn(
    String listId,
    String studentId,
    String course, {
    bool deferHeavyWork = false,
  }) async {
    var student = _studentRecordForId(studentId);
    if (student != null) {
      if (!deferHeavyWork &&
          (student.name.trim().isEmpty || student.name.trim() == 'Unknown')) {
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
      await _persistStudentRecord(
        student,
        awaitWhenOnline: !deferHeavyWork,
      );
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
      if (deferHeavyWork) {
        unawaited(_tryUploadSignInRecord(enriched));
      } else {
        await _tryUploadSignInRecord(enriched);
      }
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
    if (deferHeavyWork) {
      unawaited(_tryUploadSignInRecord(record));
    } else {
      await _tryUploadSignInRecord(record);
    }
    if (!deferHeavyWork &&
        (isStudentScopedUser() || _normalizedStudentRegistrationForCache() != null)) {
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
          .collection(ApiCollections.signIns)
          .doc(record.id)
          .set(
            <String, dynamic>{
              'listId': record.listId,
              'studentId': record.studentId,
              'course': record.course,
              'signedInAt': apiDateToField(record.signedInAt),
              if (name != null && name.isNotEmpty) 'studentName': name,
              if (reg != null && reg.isNotEmpty) 'registrationNumber': reg,
            },
            ApiSetOptions(merge: true),
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
    String registrationNumber, {
    bool fast = false,
  }) async {
    final normalized =
        StudentRegistrationNumber.normalize(registrationNumber.trim());
    if (normalized.isEmpty) return null;
    if (await deviceRegistrationBlockReason(normalized) != null) {
      return null;
    }

    var student = AttendanceStore.findStudentByReg(normalized);
    if (student != null) {
      student = _reconcileStudentIdToRegistration(student);
      await _persistStudentRecord(
        student,
        awaitWhenOnline: !fast,
      );
      return student;
    }

    student = await registerStudentFromAuthProfile(normalized, fast: fast);
    if (student != null) return student;

    Future<String?> nameFuture = _resolveRegisteredFullNameForReg(normalized);
    if (fast) {
      nameFuture = nameFuture.timeout(
        const Duration(seconds: 2),
        onTimeout: () => AuthRepository.instance.currentFullName?.trim(),
      );
    }
    final registeredName = await nameFuture;
    if (registeredName != null && registeredName.isNotEmpty) {
      return registerStudent(
        registeredName,
        normalized,
        initialsFromFullName(registeredName),
        fast: fast,
      );
    }

    if (fast) return null;

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
    /// When set, metadata auto-promotion skips this session so the interactive
    /// check-in pipeline can run (e.g. first list join + live session code).
    String? excludeSessionIdFromMetadataPromotion,
    /// Writes local enrollment metadata immediately; sync/backfill runs later.
    bool deferHeavyWork = false,
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
      excludeSessionIdFromMetadataPromotion:
          excludeSessionIdFromMetadataPromotion,
      deferHeavyWork: deferHeavyWork,
    );
    if (deferHeavyWork) {
      unawaited(_bindDeviceRegistrationIfNeeded(student.registrationNumber));
    } else {
      await _bindDeviceRegistrationIfNeeded(student.registrationNumber);
    }
    return StudentListEnrollOutcome.enrolled;
  }

  /// Records list enrollment (if new), backfills missed-session absents, then
  /// reloads official rows from Firebase when online.
  Future<void> ensureSignInAndBackfillPastAbsents({
    required String listId,
    required String studentId,
    required String course,
    String? excludeSessionIdFromMetadataPromotion,
    bool deferHeavyWork = false,
  }) async {
    if (!AttendanceStore.hasSignedIn(listId, studentId, course)) {
      await addSignIn(
        listId,
        studentId,
        course,
        deferHeavyWork: deferHeavyWork,
      );
    }
    if (deferHeavyWork) {
      unawaited(
        _completeDeferredSignInHeavyWork(
          listId: listId,
          studentId: studentId,
          course: course,
          excludeSessionId: excludeSessionIdFromMetadataPromotion,
        ),
      );
      return;
    }
    await _completeDeferredSignInHeavyWork(
      listId: listId,
      studentId: studentId,
      course: course,
      excludeSessionId: excludeSessionIdFromMetadataPromotion,
    );
  }

  Future<void> _completeDeferredSignInHeavyWork({
    required String listId,
    required String studentId,
    required String course,
    String? excludeSessionId,
  }) async {
    await _promoteMetadataMatchedPresentForStudentOnList(
      listId: listId,
      studentId: studentId,
      course: course,
      excludeSessionId: excludeSessionId,
    );
    await backfillPastAbsentsForStudentOnList(listId, studentId);
    await _requestServerAbsentBackfill(listId, studentId);
    if (isStudentScopedUser() || _normalizedStudentRegistrationForCache() != null) {
      if (AppConnectivity.instance.isOnline) {
        unawaited(loadListAttendanceData(listId));
      }
    }
    unawaited(syncUnuploadedSignIns());
  }

  /// When the student checked in (or queued metadata) before joining the list,
  /// writes present for ended sessions that match code + time + GPS.
  Future<void> _promoteMetadataMatchedPresentForStudentOnList({
    required String listId,
    required String studentId,
    required String course,
    String? excludeSessionId,
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
      if (excludeSessionId != null &&
          excludeSessionId.isNotEmpty &&
          sess.id == excludeSessionId) {
        continue;
      }
      if (AttendanceStore.isPresentForSession(sess.id, studentId)) continue;
      final recordId = attendanceRecordIdForSessionStudent(sess.id, studentId);
      if (await _remoteRecordIsPresent(recordId)) continue;

      PendingCheckInEntry? matchedCheckIn;
      for (final e in pendingCheckIns) {
        if (e.studentId != studentId) continue;
        if (e.sessionId == sess.id &&
            pendingCheckInMatchesSessionForCorrection(e, sess)) {
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
          case StudentOfflineCheckInOutcome.sessionMismatch:
          case StudentOfflineCheckInOutcome.rejectedVerification:
          case StudentOfflineCheckInOutcome.queuedOffline:
            final existing = AttendanceStore.attendanceRecordForSessionStudent(
              sess.id,
              studentId,
            );
            final promoted = AttendanceRecord(
              id: record.id,
              sessionId: record.sessionId,
              studentId: record.studentId,
              course: record.course,
              timestamp: record.timestamp,
              latitude: record.latitude,
              longitude: record.longitude,
              verified: true,
              present: true,
              deviceId: record.deviceId,
            );
            if (existing == null || !existing.present) {
              AttendanceStore.addAttendanceRecordIfAbsent(promoted);
            } else if (!existing.verified || !existing.present) {
              AttendanceStore.updateAttendanceRecord(promoted);
            }
            _notifyStoreUpdated();
            break;
          default:
            await _requestServerAbsentBackfill(listId, studentId);
            if (AppConnectivity.instance.hasNetworkInterface) {
              await awaitOfficialRecordFromApi(
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
          awaitOfficialRecordFromApi(
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

  PendingCheckInEntry? _pendingCheckInFromAttemptDoc(
    ApiDocumentSnapshot doc, {
    required AttendanceSession session,
    required String listId,
    required String studentId,
  }) {
    final data = doc.data();
    if (data == null) return null;
    final status = (data['status'] as String?)?.trim().toLowerCase() ?? '';
    if (status != 'pending' && status != 'accepted' && status != 'rejected') {
      return null;
    }
    final sid = (data['sessionId'] as String?)?.trim() ?? '';
    if (sid.isNotEmpty && sid != session.id) return null;
    final attemptListId = (data['listId'] as String?)?.trim() ?? '';
    if (attemptListId.isNotEmpty &&
        attemptListId != listId &&
        attemptListId != session.listId) {
      return null;
    }
    final attemptCode = normalizeSessionCodeInput(
      (data['sessionCodeRaw'] as String?) ?? '',
    );
    final sessionCode = normalizeSessionCodeInput(session.sessionCode);
    if (attemptCode.isNotEmpty &&
        sessionCode.isNotEmpty &&
        attemptCode != sessionCode) {
      return null;
    }
    final capturedAt = apiDateFromField(data['capturedAt']);
    if (capturedAt == null) return null;
    final lat = (data['latitude'] as num?)?.toDouble() ?? 0;
    final lng = (data['longitude'] as num?)?.toDouble() ?? 0;
    final draft = PendingCheckInEntry(
      id: doc.id,
      sessionId: sid.isNotEmpty ? sid : session.id,
      studentId: studentId,
      listId: listId.isNotEmpty ? listId : session.listId,
      course: (data['course'] as String?)?.trim() ?? '—',
      capturedAt: capturedAt,
      latitude: lat,
      longitude: lng,
      deviceId: (data['deviceId'] as String?)?.trim() ?? '',
      pendingSince: DateTime.now(),
    );
    // Reused join codes must not backfill other days — require capture window + GPS.
    if (!isTimestampWithinSessionBounds(session, capturedAt)) {
      return null;
    }
    if (!pendingReplayLocationOk(session, lat, lng)) {
      return null;
    }
    if (sid.isNotEmpty && sid != session.id) {
      return null;
    }
    return draft;
  }

  /// Server-side check-in evidence for [session] when local queues are empty.
  Future<PendingCheckInEntry?> _serverAttemptMatchesSessionForStudent({
    required String listId,
    required AttendanceSession session,
    required String studentId,
  }) async {
    if (!AppConnectivity.instance.hasNetworkInterface) return null;
    try {
      final code = normalizeSessionCodeInput(session.sessionCode);
      if (code.isNotEmpty) {
        final awaitId = PendingSessionCodeClaimUpload.claimDocId(
          normalizedCode: code,
          studentId: studentId,
        );
        final direct = await _firestore
            .collection(ApiCollections.checkInAttempts)
            .doc(awaitId)
            .get(_loadQueryOptions(force: true));
        if (direct.exists) {
          final matched = _pendingCheckInFromAttemptDoc(
            direct,
            session: session,
            listId: listId,
            studentId: studentId,
          );
          if (matched != null) return matched;
        }
      }
      final snaps = <ApiDocumentSnapshot>[];
      final byList = await _firestore
          .collection(ApiCollections.checkInAttempts)
          .where('studentId', isEqualTo: studentId)
          .where('listId', isEqualTo: listId)
          .get(_loadQueryOptions(force: true));
      snaps.addAll(byList.docs);
      if (code.isNotEmpty) {
        final byCode = await _firestore
            .collection(ApiCollections.checkInAttempts)
            .where('studentId', isEqualTo: studentId)
            .where('sessionCodeRaw', isEqualTo: code)
            .get(_loadQueryOptions(force: true));
        for (final d in byCode.docs) {
          if (!snaps.any((s) => s.id == d.id)) snaps.add(d);
        }
      }
      for (final doc in snaps) {
        final matched = _pendingCheckInFromAttemptDoc(
          doc,
          session: session,
          listId: listId,
          studentId: studentId,
        );
        if (matched != null) return matched;
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
          .collection(ApiCollections.signIns)
          .where('listId', isEqualTo: listId)
          .where('studentId', isEqualTo: studentId)
          .limit(1)
          .get()
          .timeout(_sessionPublishTimeout);
      if (snap.docs.isEmpty) return;
      await snap.docs.first.reference.update(<String, dynamic>{
        'backfillRequestedAt': ApiFieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  /// Idempotent: creates missing absent rows for completed sessions on [listId]
  /// where the student has no check-in. Sessions that ended **before** the
  /// student joined the list are marked absent immediately; later sessions wait
  /// until per-student grace ends (7-day cap or a later session resolved).
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
      final recordsForStudent = AttendanceStore.attendanceRecords
          .where((r) => r.studentId == studentId)
          .toList();
      if (!missedBeforeJoin &&
          !studentSessionGraceExpired(
            session: sess,
            studentId: studentId,
            listId: listId,
            recordsForStudent: recordsForStudent,
          )) {
        continue;
      }
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
      if (AttendanceStore.isPresentForSession(sess.id, studentId)) continue;
      if (sessionStudentCheckInMetadataIncomplete(sess)) continue;
      if (await studentHasUnexpiredPendingEvidenceForSession(
        session: sess,
        studentId: studentId,
      )) {
        continue;
      }
      final existingLocal =
          AttendanceStore.attendanceRecordForSessionStudent(sess.id, studentId);
      if (existingLocal != null && existingLocal.present) continue;
      if (existingLocal != null && !existingLocal.present) continue;
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
