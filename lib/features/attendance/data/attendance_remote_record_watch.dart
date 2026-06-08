import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';

/// Live Firestore listeners that merge official [attendance_records] into the
/// local store as soon as Cloud Functions reconcile a check-in.
class AttendanceRemoteRecordWatch {
  AttendanceRemoteRecordWatch._();

  static final AttendanceRemoteRecordWatch instance =
      AttendanceRemoteRecordWatch._();

  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> _subs =
      [];
  Set<String> _watchedStudentIds = {};
  Set<String> _watchedSessionIds = {};
  bool _running = false;

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    if (!AuthRepository.instance.isLoggedIn) return;
    final db = tryUPanelFirestore();
    if (db == null) return;

    await stop();
    _running = true;

    await AttendanceRepository.instance.awaitRoleChecksForWatch();
    if (!AuthRepository.instance.isLoggedIn) {
      _running = false;
      return;
    }

    if (AttendanceRepository.isStudentScopedUser()) {
      _attachStudentRecordWatch(db);
    } else {
      _attachSessionRecordWatch(db);
    }

    if (_subs.isEmpty) {
      _running = false;
    }
  }

  /// Re-subscribes when roster/session membership changes after [loadAll].
  Future<void> refreshIfNeeded() async {
    if (!_running) return;
    final studentIds = AttendanceRepository.isStudentScopedUser()
        ? AttendanceRepository.instance.studentIdsForCurrentUserInStore()
        : const <String>{};
    final sessionIds = AttendanceRepository.isStudentScopedUser()
        ? const <String>{}
        : AttendanceStore.sessions.map((s) => s.id).toSet();

    if (studentIds == _watchedStudentIds && sessionIds == _watchedSessionIds) {
      return;
    }
    await start();
  }

  Future<void> stop() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _watchedStudentIds = {};
    _watchedSessionIds = {};
    _running = false;
  }

  void _attachStudentRecordWatch(FirebaseFirestore db) {
    final studentIds = AttendanceRepository.instance
        .studentIdsForCurrentUserInStore()
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
        AttendanceStore.sessions.map((s) => s.id).where((id) => id.isNotEmpty).toList();
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
    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.removed) continue;
      final record = AttendanceRepository.recordFromFirestoreDoc(change.doc);
      unawaited(
        AttendanceRepository.instance.applyRemoteAttendanceRecord(record),
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
