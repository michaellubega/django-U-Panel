import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/api/api_collections.dart';
import '../../../core/api/api_store.dart';
import 'attendance_repository.dart';

/// Live Firestore listeners that merge official [attendance_records] into the
/// local store as soon as Cloud Functions reconcile a check-in.
///
/// Students use [AttendanceRtdRecordWatch] only — Firestore session/student
/// bulk queries are lecturer/admin paths and are denied for student accounts.
class AttendanceRemoteRecordWatch {
  AttendanceRemoteRecordWatch._();

  static final AttendanceRemoteRecordWatch instance =
      AttendanceRemoteRecordWatch._();

  final List<StreamSubscription<ApiQuerySnapshot>> _subs =
      [];
  StreamSubscription<ApiQuerySnapshot>? _activeSessionSub;
  Set<String> _watchedSessionIds = {};
  String? _activeSessionId;
  bool _running = false;
  Timer? _refreshDebounce;
  Future<void> _opChain = Future<void>.value();

  bool get isRunning => _running;

  bool _useFirestoreRecordWatch() =>
      !AttendanceRepository.isStudentRecordWatchUser();

  Future<void> _serialized(Future<void> Function() action) {
    final next = _opChain.then((_) => action());
    _opChain = next.catchError((_) {});
    return next;
  }

  /// Dedicated low-latency listener for the lecturer's live session roll.
  Future<void> watchActiveSessionRecords(String sessionId) async {
    if (!_useFirestoreRecordWatch()) return;
    await _serialized(() async {
      if (!AuthRepository.instance.isLoggedIn) return;
      final db = tryApiStore();
      if (db == null) return;
      final id = sessionId.trim();
      if (id.isEmpty) return;
      if (_activeSessionId == id && _activeSessionSub != null) return;

      await _activeSessionSub?.cancel();
      _activeSessionId = id;
      _activeSessionSub = db
          .collection(ApiCollections.attendanceRecords)
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
    });
  }

  Future<void> clearActiveSessionWatch() async {
    await _serialized(() async {
      await _activeSessionSub?.cancel();
      _activeSessionSub = null;
      _activeSessionId = null;
    });
  }

  Future<void> start() async {
    if (!_useFirestoreRecordWatch()) return;
    await _serialized(_startImpl);
  }

  Future<void> _startImpl() async {
    if (!AuthRepository.instance.isLoggedIn) return;
    final db = tryApiStore();
    if (db == null) return;

    await AttendanceRepository.instance.awaitRoleChecksForWatch();
    if (!AuthRepository.instance.isLoggedIn) return;
    if (!_useFirestoreRecordWatch()) return;

    final sessionIds =
        AttendanceRepository.instance.sessionIdsForRecordWatch();
    if (sessionIds.isEmpty && _activeSessionId == null) return;
    if (_running && sessionIds == _watchedSessionIds) return;

    await _stopImpl(keepActiveSession: true);
    _running = true;
    _attachSessionRecordWatch(db);

    if (_subs.isEmpty && _activeSessionSub == null) {
      _running = false;
    }
  }

  /// Re-subscribes when roster/session membership changes after [loadAll].
  Future<void> refreshIfNeeded() async {
    if (!_useFirestoreRecordWatch()) return;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 100), () {
      _refreshDebounce = null;
      unawaited(start());
    });
  }

  Future<void> stop({bool keepActiveSession = false}) async {
    await _serialized(() => _stopImpl(keepActiveSession: keepActiveSession));
  }

  Future<void> _stopImpl({bool keepActiveSession = false}) async {
    _refreshDebounce?.cancel();
    _refreshDebounce = null;
    final subs = List<StreamSubscription<ApiQuerySnapshot>>.from(
      _subs,
    );
    _subs.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
    _watchedSessionIds = {};
    _running = false;
    if (!keepActiveSession) {
      await _activeSessionSub?.cancel();
      _activeSessionSub = null;
      _activeSessionId = null;
    }
  }

  void _attachSessionRecordWatch(ApiStore db) {
    final sessionIds =
        AttendanceRepository.instance.sessionIdsForRecordWatch().toList();
    if (_activeSessionId != null && _activeSessionId!.isNotEmpty) {
      sessionIds.removeWhere((id) => id == _activeSessionId);
    }
    if (sessionIds.isEmpty) return;
    _watchedSessionIds = sessionIds.toSet();
    for (final chunk in _chunk(sessionIds, 10)) {
      final sub = db
          .collection(ApiCollections.attendanceRecords)
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

  void _onRecordsSnapshot(ApiQuerySnapshot snap) {
    for (final doc in snap.docs) {
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
