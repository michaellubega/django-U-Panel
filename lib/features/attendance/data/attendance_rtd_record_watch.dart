import 'dart:async';



import 'package:firebase_database/firebase_database.dart';

import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';



import '../../../core/auth/auth_repository.dart';

import '../../../core/firebase/attendance_record_rtd_sync.dart';

import '../../../core/firebase/student_rtd_index.dart';

import '../../../core/firebase/u_panel_rtd.dart';

import '../models/attendance_models.dart';

import 'attendance_repository.dart';



/// Low-latency Realtime Database listeners for official attendance rows and

/// session roll stats (present / absent / pending / %).

class AttendanceRtdRecordWatch {

  AttendanceRtdRecordWatch._();



  static final AttendanceRtdRecordWatch instance = AttendanceRtdRecordWatch._();



  final List<StreamSubscription<DatabaseEvent>> _subs = [];

  final List<StreamSubscription<DatabaseEvent>> _activeSessionSubs = [];

  StreamSubscription<DatabaseEvent>? _activeSessionStatsSub;

  Set<String> _watchedStudentIds = {};

  Set<String> _watchedStudentListIds = {};

  Set<String> _watchedSessionIds = {};

  String? _activeSessionId;

  bool _running = false;

  Timer? _refreshDebounce;



  bool get isRunning => _running;



  Future<void> watchActiveSessionRecords(String sessionId) async {

    if (!AuthRepository.instance.isLoggedIn) return;

    final db = tryUPanelDatabase();

    if (db == null) return;

    final id = sessionId.trim();

    if (id.isEmpty) return;

    if (_activeSessionId == id &&

        _activeSessionSubs.isNotEmpty &&

        _activeSessionStatsSub != null) {

      return;

    }



    await _clearActiveSessionSubs();

    _activeSessionId = id;



    final recordsRef = db.ref(AttendanceRecordRtdSync.sessionRecordsPath(id));

    _activeSessionSubs.add(

      recordsRef.onChildAdded.listen(

        (event) => _onSessionChildEvent(id, event),

        onError: _onRtdError,

      ),

    );

    _activeSessionSubs.add(

      recordsRef.onChildChanged.listen(

        (event) => _onSessionChildEvent(id, event),

        onError: _onRtdError,

      ),

    );



    _activeSessionStatsSub = db

        .ref(AttendanceRecordRtdSync.sessionStatsPath(id))

        .onValue

        .listen(

          (event) => _onSessionStatsEvent(id, event.snapshot.value),

          onError: _onRtdError,

        );



    unawaited(_prefetchSessionRecords(db, id));

  }



  Future<void> clearActiveSessionWatch() async {

    await _clearActiveSessionSubs();

    _activeSessionId = null;

  }



  Future<void> _clearActiveSessionSubs() async {

    for (final sub in _activeSessionSubs) {

      await sub.cancel();

    }

    _activeSessionSubs.clear();

    await _activeSessionStatsSub?.cancel();

    _activeSessionStatsSub = null;

  }



  Future<void> start() async {

    if (!AuthRepository.instance.isLoggedIn) return;

    final db = tryUPanelDatabase();

    if (db == null) return;



    if (AuthRepository.instance.isStudentAuthIdentity) {

      await AuthRepository.instance.ensureStudentRegistrationHydrated();

      if (!AttendanceRepository.isStudentRecordWatchUser()) return;

    }



    final studentWatch = AttendanceRepository.isStudentRecordWatchUser();

    if (!studentWatch) {

      await AttendanceRepository.instance.awaitRoleChecksForWatch();

      if (AuthRepository.instance.isStudentAuthIdentity) return;

    }

    if (!AuthRepository.instance.isLoggedIn) return;



    if (studentWatch) {

      await StudentRtdIndex.publishCurrentStudentRegistration();

      final reg = AttendanceRepository.instance.studentRegistrationForRtdWatch();

      if (reg == null || reg.isEmpty) return;

      final watchIds = {reg.trim()};
      final listIds = _studentListIdsForRtdWatch(watchIds);

      if (_running &&
          watchIds == _watchedStudentIds &&
          listIds == _watchedStudentListIds) {
        return;
      }

      _watchedStudentIds = watchIds;
      _watchedStudentListIds = listIds;

    } else {

      final sessionIds =

          AttendanceRepository.instance.sessionIdsForRtdRecordWatch();

      if (sessionIds.isEmpty && _activeSessionId == null) return;

      if (_running && sessionIds == _watchedSessionIds) return;

    }



    await stop(keepActiveSession: true);

    _running = true;



    if (studentWatch) {

      _attachStudentRecordWatch(db);

      _attachStudentRollStatsWatch(db);

      _attachStudentListStatsWatch(db);

      _attachStudentAllListRollStatsWatch(db);

    } else {

      _attachSessionRecordWatch(db);

    }



    if (_subs.isEmpty &&

        _activeSessionSubs.isEmpty &&

        _activeSessionStatsSub == null) {

      _running = false;

    }

  }



  Future<void> refreshIfNeeded() async {

    _refreshDebounce?.cancel();

    _refreshDebounce = Timer(const Duration(milliseconds: 200), () {

      _refreshDebounce = null;

      unawaited(start());

    });

  }



  /// After check-in, prefetch the student's official row and list stats from RTD

  /// so profile attendance % updates without waiting on Firestore polling.

  Future<void> primeAfterStudentCheckIn({

    required String sessionId,

    required String studentId,

    String? listId,

  }) async {

    if (!AuthRepository.instance.isLoggedIn) return;

    final db = tryUPanelDatabase();

    if (db == null) return;

    final sid = sessionId.trim();

    final stu = studentId.trim();

    if (sid.isEmpty || stu.isEmpty) return;



    await refreshIfNeeded();



    try {

      final snap = await db

          .ref(AttendanceRecordRtdSync.studentRecordsPath(stu))

          .child(sid)

          .get()

          .timeout(const Duration(seconds: 3));

      if (snap.exists) {

        _applyRecordFromRtd(

          sessionId: sid,

          studentId: stu,

          value: snap.value,

        );

      }

    } catch (_) {}



    try {

      final rollStatsSnap = await db

          .ref(AttendanceRecordRtdSync.studentRollStatsPath(stu))

          .get()

          .timeout(const Duration(seconds: 3));

      if (rollStatsSnap.exists) {

        _onStudentRollStatsEvent(stu, rollStatsSnap.value);

      }

    } catch (_) {}



    final lid = listId?.trim() ?? '';

    if (lid.isNotEmpty) {

      try {

        final statsSnap = await db

            .ref(AttendanceRecordRtdSync.studentListRollStatsPath(stu, lid))

            .get()

            .timeout(const Duration(seconds: 3));

        if (statsSnap.exists) {

          _onStudentListRollStatsEvent(stu, lid, statsSnap.value);

        }

      } catch (_) {}

      try {

        final statsSnap = await db

            .ref(AttendanceRecordRtdSync.listSessionStatsPath(lid, sid))

            .get()

            .timeout(const Duration(seconds: 3));

        if (statsSnap.exists) {

          _onSessionStatsEvent(sid, statsSnap.value);

        }

      } catch (_) {}

    }

  }



  Future<void> stop({bool keepActiveSession = false}) async {

    _refreshDebounce?.cancel();

    _refreshDebounce = null;

    for (final sub in _subs) {

      await sub.cancel();

    }

    _subs.clear();

    _watchedStudentIds = {};

    _watchedStudentListIds = {};

    _watchedSessionIds = {};

    _running = false;

    if (!keepActiveSession) {

      await clearActiveSessionWatch();

    }

  }



  void _attachStudentRecordWatch(FirebaseDatabase db) {

    final studentIds = _watchedStudentIds.toList();

    if (studentIds.isEmpty) return;

    for (final studentId in studentIds) {

      final path = AttendanceRecordRtdSync.studentRecordsPath(studentId);

      _subs.add(

        db.ref(path).onChildAdded.listen(

              (event) => _onStudentChildEvent(studentId, event),

              onError: _onRtdError,

            ),

      );

      _subs.add(

        db.ref(path).onChildChanged.listen(

              (event) => _onStudentChildEvent(studentId, event),

              onError: _onRtdError,

            ),

      );

      unawaited(_prefetchStudentRecords(db, studentId));

    }

  }



  void _attachStudentRollStatsWatch(FirebaseDatabase db) {

    final studentIds = _watchedStudentIds;

    if (studentIds.isEmpty) return;

    for (final studentId in studentIds) {

      final path = AttendanceRecordRtdSync.studentRollStatsPath(studentId);

      _subs.add(

        db.ref(path).onValue.listen(

          (event) => _onStudentRollStatsEvent(studentId, event.snapshot.value),

          onError: _onRtdError,

        ),

      );

      unawaited(_prefetchStudentRollStats(db, studentId));

    }

  }



  void _attachStudentListStatsWatch(FirebaseDatabase db) {

    final studentIds = _watchedStudentIds;

    final listIds = _studentListIdsForRtdWatch(studentIds);

    if (listIds.isEmpty) return;

    for (final listId in listIds) {

      final ref = db.ref('${AttendanceRecordRtdSync.statsRoot}/by_list/$listId');

      _subs.add(

        ref.onChildAdded.listen(

          (event) {

            final sessionId = event.snapshot.key?.trim() ?? '';

            if (sessionId.isEmpty) return;

            _onSessionStatsEvent(sessionId, event.snapshot.value);

          },

          onError: _onRtdError,

        ),

      );

      _subs.add(

        ref.onChildChanged.listen(

          (event) {

            final sessionId = event.snapshot.key?.trim() ?? '';

            if (sessionId.isEmpty) return;

            _onSessionStatsEvent(sessionId, event.snapshot.value);

          },

          onError: _onRtdError,

        ),

      );

      unawaited(_prefetchListStats(db, listId));

    }

  }



  Set<String> _studentListIdsForRtdWatch(Set<String> studentIds) {
    final listIds = <String>{};
    final reg = AttendanceRepository.instance.studentRegistrationForRtdWatch();
    final regKey = reg?.trim().toUpperCase() ?? '';

    if (reg != null && reg.trim().isNotEmpty) {
      listIds.addAll(
        AttendanceStore.enrolledListIdsForRegistrationNormalized(reg.trim()),
      );
    }

    for (final sid in studentIds) {
      for (final signIn in AttendanceStore.signIns) {
        final signInId = signIn.studentId.trim();
        final signInReg = signIn.registrationNumber?.trim().toUpperCase() ?? '';
        if (signInId == sid ||
            (regKey.isNotEmpty &&
                (signInReg == regKey || signInId.toUpperCase() == regKey))) {
          listIds.add(signIn.listId);
        }
      }
    }

    for (final listId
        in AttendanceRepository.instance.recentListDetailIdsForWatch()) {
      if (listId.trim().isNotEmpty) listIds.add(listId.trim());
    }

    return listIds;
  }



  /// One listener on `by_student/{reg}/by_list` — instant % updates for every class.
  void _attachStudentAllListRollStatsWatch(FirebaseDatabase db) {
    final studentIds = _watchedStudentIds;
    if (studentIds.isEmpty) return;

    for (final studentId in studentIds) {
      final path =
          '${AttendanceRecordRtdSync.statsRoot}/by_student/$studentId/by_list';
      _subs.add(
        db.ref(path).onValue.listen(
          (event) => _onStudentAllListRollStatsEvent(
            studentId,
            event.snapshot.value,
          ),
          onError: _onRtdError,
        ),
      );
      unawaited(_prefetchStudentAllListRollStats(db, studentId));
    }
  }

  void _onStudentAllListRollStatsEvent(String studentId, dynamic value) {
    if (value is! Map) return;
    var changed = false;
    for (final entry in value.entries) {
      final listId = entry.key?.toString().trim() ?? '';
      if (listId.isEmpty) continue;
      final stats = StudentRollStatsSnapshot.fromRtdValue(entry.value);
      if (stats == null) continue;
      final existing = AttendanceStore.studentListRollStats(studentId, listId);
      if (existing != null &&
          existing.present == stats.present &&
          existing.total == stats.total &&
          existing.percentRounded == stats.percentRounded &&
          existing.updatedAt == stats.updatedAt) {
        continue;
      }
      AttendanceStore.setStudentListRollStats(studentId, listId, stats);
      changed = true;
    }
    if (changed) {
      AttendanceRepository.instance.notifyStoreUpdatedFromRtd();
    }
  }

  Future<void> _prefetchStudentAllListRollStats(
    FirebaseDatabase db,
    String studentId,
  ) async {
    try {
      final snap = await db
          .ref(
            '${AttendanceRecordRtdSync.statsRoot}/by_student/$studentId/by_list',
          )
          .get()
          .timeout(const Duration(seconds: 4));
      if (snap.exists) {
        _onStudentAllListRollStatsEvent(studentId, snap.value);
      }
    } catch (_) {}
  }



  void _onStudentListRollStatsEvent(

    String studentId,

    String listId,

    dynamic value,

  ) {

    final stats = StudentRollStatsSnapshot.fromRtdValue(value);

    if (stats == null) return;

    AttendanceStore.setStudentListRollStats(studentId, listId, stats);

    AttendanceRepository.instance.notifyStoreUpdatedFromRtd();

  }



  void _attachSessionRecordWatch(FirebaseDatabase db) {

    final sessionIds =

        AttendanceRepository.instance.sessionIdsForRtdRecordWatch().toList();

    if (_activeSessionId != null && _activeSessionId!.isNotEmpty) {

      sessionIds.removeWhere((id) => id == _activeSessionId);

    }

    if (sessionIds.isEmpty) return;

    _watchedSessionIds = sessionIds.toSet();

    for (final sessionId in sessionIds) {

      final path = AttendanceRecordRtdSync.sessionRecordsPath(sessionId);

      _subs.add(

        db.ref(path).onChildAdded.listen(

              (event) => _onSessionChildEvent(sessionId, event),

              onError: _onRtdError,

            ),

      );

      _subs.add(

        db.ref(path).onChildChanged.listen(

              (event) => _onSessionChildEvent(sessionId, event),

              onError: _onRtdError,

            ),

      );

      _subs.add(

        db

            .ref(AttendanceRecordRtdSync.sessionStatsPath(sessionId))

            .onValue

            .listen(

              (event) =>

                  _onSessionStatsEvent(sessionId, event.snapshot.value),

              onError: _onRtdError,

            ),

      );

    }

  }



  Future<void> _prefetchStudentRecords(

    FirebaseDatabase db,

    String studentId,

  ) async {

    try {

      final snap = await db

          .ref(AttendanceRecordRtdSync.studentRecordsPath(studentId))

          .get()

          .timeout(const Duration(seconds: 4));

      final value = snap.value;

      if (value is! Map) return;

      for (final entry in value.entries) {

        final sessionId = entry.key?.toString().trim() ?? '';

        if (sessionId.isEmpty) continue;

        _applyRecordFromRtd(

          sessionId: sessionId,

          studentId: studentId,

          value: entry.value,

        );

      }

    } catch (_) {}

  }



  Future<void> _prefetchSessionRecords(

    FirebaseDatabase db,

    String sessionId,

  ) async {

    try {

      final snap = await db

          .ref(AttendanceRecordRtdSync.sessionRecordsPath(sessionId))

          .get()

          .timeout(const Duration(seconds: 4));

      final value = snap.value;

      if (value is! Map) return;

      for (final entry in value.entries) {

        final studentId = entry.key?.toString().trim() ?? '';

        if (studentId.isEmpty) continue;

        _applyRecordFromRtd(

          sessionId: sessionId,

          studentId: studentId,

          value: entry.value,

        );

      }

    } catch (_) {}

  }



  Future<void> _prefetchStudentRollStats(

    FirebaseDatabase db,

    String studentId,

  ) async {

    try {

      final snap = await db

          .ref(AttendanceRecordRtdSync.studentRollStatsPath(studentId))

          .get()

          .timeout(const Duration(seconds: 4));

      if (snap.exists) {

        _onStudentRollStatsEvent(studentId, snap.value);

      }

    } catch (_) {}

  }



  Future<void> _prefetchListStats(FirebaseDatabase db, String listId) async {

    try {

      final snap = await db

          .ref('${AttendanceRecordRtdSync.statsRoot}/by_list/$listId')

          .get()

          .timeout(const Duration(seconds: 4));

      final value = snap.value;

      if (value is! Map) return;

      for (final entry in value.entries) {

        final sessionId = entry.key?.toString().trim() ?? '';

        if (sessionId.isEmpty) continue;

        _onSessionStatsEvent(sessionId, entry.value);

      }

    } catch (_) {}

  }



  void _onSessionChildEvent(String sessionId, DatabaseEvent event) {

    final studentId = event.snapshot.key?.trim() ?? '';

    if (studentId.isEmpty) return;

    _applyRecordFromRtd(

      sessionId: sessionId,

      studentId: studentId,

      value: event.snapshot.value,

    );

  }



  void _onStudentChildEvent(String studentId, DatabaseEvent event) {

    final sessionId = event.snapshot.key?.trim() ?? '';

    if (sessionId.isEmpty) return;

    _applyRecordFromRtd(

      sessionId: sessionId,

      studentId: studentId,

      value: event.snapshot.value,

    );

  }



  void _applyRecordFromRtd({

    required String sessionId,

    required String studentId,

    required dynamic value,

  }) {

    final record = AttendanceRecordRtdSync.recordFromRtdValue(

      sessionId: sessionId,

      studentId: studentId,

      value: value,

    );

    if (record == null) return;

    unawaited(

      AttendanceRepository.instance

          .applyRemoteAttendanceRecord(record, immediate: true)

          .catchError((Object e, StackTrace st) {

        if (kDebugMode) {

          debugPrint('AttendanceRtdRecordWatch apply: $e');

          debugPrint('$st');

        }

      }),

    );

  }



  void _onStudentRollStatsEvent(String studentId, dynamic value) {

    final stats = StudentRollStatsSnapshot.fromRtdValue(value);

    if (stats == null) return;

    final existing = AttendanceStore.studentRollStats(studentId);
    if (existing != null &&
        existing.present == stats.present &&
        existing.total == stats.total &&
        existing.percentRounded == stats.percentRounded &&
        existing.updatedAt == stats.updatedAt) {
      return;
    }

    AttendanceStore.setStudentRollStats(studentId, stats);

    AttendanceRepository.instance.notifyStoreUpdatedFromRtd();

  }



  void _onSessionStatsEvent(String sessionId, dynamic value) {

    final stats = SessionRollStatsSnapshot.fromRtdValue(value);

    if (stats == null) return;

    AttendanceStore.setSessionRollStats(sessionId, stats);

    AttendanceRepository.instance.notifyStoreUpdatedFromRtd();

  }



  void _onRtdError(Object error) {

    if (error is MissingPluginException) {

      markUPanelRtdUnavailable(error);

    }

    final message = error.toString();

    if (message.contains('permission-denied') ||

        message.contains('permission_denied')) {

      if (kDebugMode) {

        debugPrint('AttendanceRtdRecordWatch permission denied: $error');

      }

      return;

    }

    if (kDebugMode) {

      debugPrint('AttendanceRtdRecordWatch: $error');

    }

  }

}


