import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/api/api_collections.dart';
import '../../../core/api/api_store.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';

/// Live Firestore listeners that purge local list data when authoritative
/// remote membership changes (e.g. lecturer deletes a list on another device).
class AttendanceRemoteListWatch {
  AttendanceRemoteListWatch._();

  static final AttendanceRemoteListWatch instance =
      AttendanceRemoteListWatch._();

  static const _lecturerSources = {'lecturerAssigned', 'lecturerCreated'};

  final List<StreamSubscription<ApiQuerySnapshot>> _subs =
      [];
  final Map<String, Set<String>> _idsBySource = {};
  bool _running = false;
  bool _lecturerDualWatch = false;
  Set<String>? _studentSignInSourcesExpected;

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    if (!AuthRepository.instance.isLoggedIn) return;
    final db = tryApiStore();
    if (db == null) return;

    await stop();
    _running = true;

    await AttendanceRepository.instance.awaitRoleChecksForWatch();
    if (!AuthRepository.instance.isLoggedIn) {
      _running = false;
      return;
    }

    final auth = AuthRepository.instance;
    if (AttendanceRepository.isStudentScopedUser()) {
      _lecturerDualWatch = false;
      _attachStudentSignInWatch(db);
    } else if (auth.adminCheckDone && auth.isAdmin) {
      _lecturerDualWatch = false;
      _attachCollectionWatch(
        db,
        source: 'staffLists',
        query: ApiCollectionQuery(ApiCollections.attendanceLists),
      );
    } else {
      final uid = auth.currentUserId?.trim();
      if (uid != null && uid.isNotEmpty) {
        _lecturerDualWatch = true;
        _attachCollectionWatch(
          db,
          source: 'lecturerAssigned',
          query: db
              .collection(ApiCollections.attendanceLists)
              .where('lecturerUid', isEqualTo: uid),
        );
        _attachCollectionWatch(
          db,
          source: 'lecturerCreated',
          query: db
              .collection(ApiCollections.attendanceLists)
              .where('createdBy', isEqualTo: uid),
        );
      }
    }

    if (_subs.isEmpty) {
      _running = false;
    }
  }

  Future<void> stop() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _idsBySource.clear();
    _lecturerDualWatch = false;
    _studentSignInSourcesExpected = null;
    _running = false;
  }

  void _attachStudentSignInWatch(ApiStore db) {
    final studentIds = AttendanceRepository.instance
        .studentIdsForCurrentUserInStore()
        .toList();
    if (studentIds.isEmpty) return;
    final expectedSources = <String>{};
    for (final chunk in _chunk(studentIds, 10)) {
      final source = 'signIns:${chunk.join(',')}';
      expectedSources.add(source);
      final sub = db
          .collection(ApiCollections.signIns)
          .where('studentId', whereIn: chunk)
          .snapshots()
          .listen(
            (snap) {
              final listIds = <String>{};
              for (final doc in snap.docs) {
                final id =
                    (doc.data()?['listId'] as String?)?.trim() ?? '';
                if (id.isNotEmpty) listIds.add(id);
              }
              _updateFromSource(source, listIds);
            },
            onError: (Object e, StackTrace st) {
              if (kDebugMode) {
                debugPrint('AttendanceRemoteListWatch signIns: $e');
              }
            },
          );
      _subs.add(sub);
    }
    _studentSignInSourcesExpected = expectedSources;
  }

  void _attachCollectionWatch(
    ApiStore db, {
    required String source,
    required ApiCollectionQuery query,
  }) {
    final sub = query.snapshots().listen(
      (snap) {
        _updateFromSource(
          source,
          snap.docs.map((d) => d.id).toSet(),
        );
      },
      onError: (Object e, StackTrace st) {
        if (kDebugMode) {
          debugPrint('AttendanceRemoteListWatch $source: $e');
        }
      },
    );
    _subs.add(sub);
  }

  bool _allWatchSourcesReady() {
    if (_lecturerDualWatch &&
        !_lecturerSources.every(_idsBySource.containsKey)) {
      return false;
    }
    final studentSources = _studentSignInSourcesExpected;
    if (studentSources != null &&
        !studentSources.every(_idsBySource.containsKey)) {
      return false;
    }
    return true;
  }

  void _updateFromSource(String source, Set<String> ids) {
    _idsBySource[source] = ids;
    if (!_allWatchSourcesReady()) return;

    final remoteIds = <String>{
      ..._idsBySource.values.expand((s) => s).map((id) => id.trim()),
      for (final s in AttendanceStore.signIns)
        if (s.listId.trim().isNotEmpty) s.listId.trim(),
    }..removeWhere((id) => id.isEmpty);
    unawaited(
      AttendanceRepository.instance.reconcileLocalListsAgainstRemoteIds(
        remoteIds,
      ),
    );
  }

  static Iterable<List<T>> _chunk<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      final end = i + size;
      yield items.sublist(i, end > items.length ? items.length : end);
    }
  }
}
