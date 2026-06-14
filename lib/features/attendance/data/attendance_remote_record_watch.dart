import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/student_rtd_index.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import 'attendance_repository.dart';

/// Live Firestore listeners that merge official [attendance_records] into the
/// local store as soon as Cloud Functions reconcile a check-in.
class AttendanceRemoteRecordWatch {
  AttendanceRemoteRecordWatch._();

  static final AttendanceRemoteRecordWatch instance =
      AttendanceRemoteRecordWatch._();

  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> _subs =
      [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _activeSessionSub;
  Set<String> _watchedStudentIds = {};
  Set<String> _watchedSessionIds = {};
  String? _activeSessionId;
  bool _running = false;
  Timer? _refreshDebounce;

  bool get isRunning => _running;

  /// Dedicated low-latency listener for the lecturer's live session roll.
  Future<void> watchActiveSessionRecords(String sessionId) async {
    if (!AuthRepository.instance.isLoggedIn) return;
    final db = tryUPanelFirestore();
    if (db == null) return;
    final id = sessionId.trim();
    if (id.isEmpty) return;
    if (_activeSessionId == id && _activeSessionSub != null) return;

    await _activeSessionSub?.cancel();
    _activeSessionId = id;
    _activeSessionSub = db
        .collection(FirestoreCollections.attendanceRecords)
        .where('sessionId', isEqualTo: id)
        .snapshots()
        .listen(
          _onRecordsSnapshot,
          onError: (Object e, StackTrace st) {
            if (kDebugMode) {
              debugPrint('AttendanceRemoteRecordWatch active $id: $e');
            }
          },
        );
  }

  Future<void> clearActiveSessionWatch() async {
    await _activeSessionSub?.cancel();
    _activeSessionSub = null;
    _activeSessionId = null;
  }

  Future<void> start() async {
    if (!AuthRepository.instance.isLoggedIn) return;
    final db = tryUPanelFirestore();
    if (db == null) return;

    if (AuthRepository.instance.isStudentAuthIdentity) {
      await AuthRepository.instance.ensureStudentRegistrationHydrated();
      if (!AttendanceRepository.isStudentRecordWatchUser()) return;
    }

    if (AttendanceRepository.isStudentRecordWatchUser()) {
      await StudentRtdIndex.publishCurrentStudentRegistration();
      final studentIds =
          AttendanceRepository.instance.studentIdsForRecordWatch();
      if (studentIds.isEmpty) return;
      if (_running && studentIds == _watchedStudentIds) return;
    } else {
      await AttendanceRepository.instance.awaitRoleChecksForWatch();
      if (!AuthRepository.instance.isLoggedIn) return;
      if (AuthRepository.instance.isStudentAuthIdentity) return;
      final sessionIds =
          AttendanceRepository.instance.sessionIdsForRecordWatch();
      if (sessionIds.isEmpty && _activeSessionId == null) return;
      if (_running && sessionIds == _watchedSessionIds) return;
    }

    await stop(keepActiveSession: true);
    _running = true;

    if (AttendanceRepository.isStudentRecordWatchUser()) {
      _attachStudentRecordWatch(db);
    } else {
      _attachSessionRecordWatch(db);
    }

    if (_subs.isEmpty && _activeSessionSub == null) {
      _running = false;
    }
  }

  /// Re-subscribes when roster/session membership changes after [loadAll].
  Future<void> refreshIfNeeded() async {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 350), () {
      _refreshDebounce = null;
      unawaited(start());
    });
  }

  Future<void> stop({bool keepActiveSession = false}) async {
    _refreshDebounce?.cancel();
    _refreshDebounce = null;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _watchedStudentIds = {};
    _watchedSessionIds = {};
    _running = false;
    if (!keepActiveSession) {
      await clearActiveSessionWatch();
    }
  }

  void _attachStudentRecordWatch(FirebaseFirestore db) {
    final studentIds = AttendanceRepository.instance
        .studentIdsForRecordWatch()
        .toList();
    if (studentIds.isEmpty) return;
    _watchedStudentIds = studentIds.toSet();
    for (final chunk in _chunk(studentIds, 10)) {
      final sub = db
          .collection(FirestoreCollections.attendanceRecords)
          .where('studentId', whereIn: chunk)
          .snapshots()
          .listen(
            _onRecordsSnapshot,
            onError: (Object e, StackTrace st) {
              if (kDebugMode) {
                debugPrint('AttendanceRemoteRecordWatch student: $e');
              }
            },
          );
      _subs.add(sub);
    }
  }

  void _attachSessionRecordWatch(FirebaseFirestore db) {
    final sessionIds =
        AttendanceRepository.instance.sessionIdsForRecordWatch().toList();
    if (_activeSessionId != null && _activeSessionId!.isNotEmpty) {
      sessionIds.removeWhere((id) => id == _activeSessionId);
    }
    if (sessionIds.isEmpty) return;
    _watchedSessionIds = sessionIds.toSet();
    for (final chunk in _chunk(sessionIds, 10)) {
      final sub = db
          .collection(FirestoreCollections.attendanceRecords)
          .where('sessionId', whereIn: chunk)
          .snapshots()
          .listen(
            _onRecordsSnapshot,
            onError: (Object e, StackTrace st) {
              if (kDebugMode) {
                debugPrint('AttendanceRemoteRecordWatch session: $e');
              }
            },
          );
      _subs.add(sub);
    }
  }

  void _onRecordsSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    final changes = snap.docChanges;
    final docs = changes.isEmpty
        ? snap.docs
        : [
            for (final change in changes)
              if (change.type != DocumentChangeType.removed) change.doc,
          ];
    for (final doc in docs) {
      final record = AttendanceRepository.tryRecordFromFirestoreDoc(doc);
      if (record == null) continue;
      unawaited(
        AttendanceRepository.instance
            .applyRemoteAttendanceRecord(record)
            .catchError((Object e, StackTrace st) {
          if (kDebugMode) {
            debugPrint('AttendanceRemoteRecordWatch apply: $e');
            debugPrint('$st');
          }
        }),
      );
    }
  }

  static Iterable<List<T>> _chunk<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      final end = i + size;
      yield items.sublist(i, end > items.length ? items.length : end);
    }
  }
}
