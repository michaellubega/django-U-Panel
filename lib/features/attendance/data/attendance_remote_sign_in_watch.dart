import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/api/api_collections.dart';
import '../../../core/api/api_store.dart';
import 'attendance_repository.dart';

/// Live Firestore listener for roster sign-ins on an active attendance list.
class AttendanceRemoteSignInWatch {
  AttendanceRemoteSignInWatch._();

  static final AttendanceRemoteSignInWatch instance =
      AttendanceRemoteSignInWatch._();

  StreamSubscription<ApiQuerySnapshot>? _activeListSub;
  String? _activeListId;
  Future<void> _opChain = Future<void>.value();

  Future<void> _serialized(Future<void> Function() action) {
    final next = _opChain.then((_) => action());
    _opChain = next.catchError((_) {});
    return next;
  }

  bool _useFirestoreSignInWatch() =>
      !AttendanceRepository.isStudentRecordWatchUser();

  /// Low-latency listener while a lecturer watches a live session roll.
  Future<void> watchActiveListSignIns(String listId) async {
    if (!_useFirestoreSignInWatch()) return;
    await _serialized(() async {
      if (!AuthRepository.instance.isLoggedIn) return;
      final db = tryApiStore();
      if (db == null) return;
      final id = listId.trim();
      if (id.isEmpty) return;
      if (_activeListId == id && _activeListSub != null) return;

      await _activeListSub?.cancel();
      _activeListId = id;
      _activeListSub = db
          .collection(ApiCollections.signIns)
          .where('listId', isEqualTo: id)
          .snapshots()
          .listen(
            _onSignInsSnapshot,
            onError: (Object e, StackTrace st) {
              if (kDebugMode) {
                debugPrint('AttendanceRemoteSignInWatch active $id: $e');
              }
            },
          );
    });
  }

  Future<void> clearActiveListWatch() async {
    await _serialized(() async {
      await _activeListSub?.cancel();
      _activeListSub = null;
      _activeListId = null;
    });
  }

  void _onSignInsSnapshot(ApiQuerySnapshot snap) {
    for (final doc in snap.docs) {
      final signIn = AttendanceRepository.trySignInFromApiDoc(doc);
      if (signIn == null) continue;
      unawaited(
        AttendanceRepository.instance
            .applyRemoteSignInRecord(signIn)
            .catchError((Object e, StackTrace st) {
          if (kDebugMode) {
            debugPrint('AttendanceRemoteSignInWatch apply: $e');
            debugPrint('$st');
          }
        }),
      );
    }
  }
}
