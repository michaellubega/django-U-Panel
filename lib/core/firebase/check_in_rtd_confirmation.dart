import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/services.dart';

import 'u_panel_rtd.dart';

/// Server-published check-in outcome mirrored to Realtime Database.
class CheckInRtdConfirmation {
  const CheckInRtdConfirmation({
    required this.status,
    required this.present,
    required this.verified,
    this.rejectionReason,
    this.sessionId,
    this.studentId,
  });

  final String status;
  final bool present;
  final bool verified;
  final String? rejectionReason;
  final String? sessionId;
  final String? studentId;

  bool get isAccepted => status == 'accepted' && present;

  bool get isRejected => status == 'rejected';

  static CheckInRtdConfirmation? fromValue(dynamic value) {
    if (value is! Map) return null;
    final map = value.map((k, v) => MapEntry(k.toString(), v));
    final status = (map['status'] as String?)?.trim().toLowerCase() ?? '';
    if (status.isEmpty) return null;
    return CheckInRtdConfirmation(
      status: status,
      present: map['present'] == true,
      verified: map['verified'] == true,
      rejectionReason: (map['rejectionReason'] as String?)?.trim(),
      sessionId: (map['sessionId'] as String?)?.trim(),
      studentId: (map['studentId'] as String?)?.trim(),
    );
  }
}

/// Listens for fast check-in confirmation on Realtime Database.
abstract final class CheckInRtdConfirmationWatch {
  static const _root = 'check_in_confirmations';

  static String studentPath(String studentId, String sessionId) =>
      '$_root/by_student/$studentId/$sessionId';

  static DatabaseReference? _studentRef(String studentId, String sessionId) {
    final db = tryUPanelDatabase();
    if (db == null) return null;
    return db.ref(studentPath(studentId, sessionId));
  }

  static Stream<CheckInRtdConfirmation?> watch({
    required String sessionId,
    required String studentId,
  }) {
    final ref = _studentRef(studentId, sessionId);
    if (ref == null) return const Stream<CheckInRtdConfirmation?>.empty();
    return ref.onValue.map(
      (event) => CheckInRtdConfirmation.fromValue(event.snapshot.value),
    );
  }

  static Future<CheckInRtdConfirmation?> fetchOnce({
    required String sessionId,
    required String studentId,
  }) async {
    final ref = _studentRef(studentId, sessionId);
    if (ref == null) return null;
    try {
      final snap = await ref.get().timeout(const Duration(seconds: 3));
      return CheckInRtdConfirmation.fromValue(snap.value);
    } on MissingPluginException catch (e) {
      markUPanelRtdUnavailable(e);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Returns as soon as the server publishes accepted/rejected, or [timeout].
  static Future<CheckInRtdConfirmation?> awaitTerminal({
    required String sessionId,
    required String studentId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final existing = await fetchOnce(
      sessionId: sessionId,
      studentId: studentId,
    );
    if (existing != null &&
        (existing.isAccepted || existing.isRejected)) {
      return existing;
    }
    final ref = _studentRef(studentId, sessionId);
    if (ref == null) return existing;

    final completer = Completer<CheckInRtdConfirmation?>();
    late final StreamSubscription<DatabaseEvent> sub;
    Timer? timer;

    void finish(CheckInRtdConfirmation? value) {
      if (completer.isCompleted) return;
      timer?.cancel();
      unawaited(sub.cancel());
      completer.complete(value);
    }

    timer = Timer(timeout, () => finish(existing));
    sub = ref.onValue.listen(
      (event) {
        final conf = CheckInRtdConfirmation.fromValue(event.snapshot.value);
        if (conf == null) return;
        if (conf.isAccepted || conf.isRejected) {
          finish(conf);
        }
      },
      onError: (Object e) {
        markUPanelRtdUnavailable(e);
        finish(existing);
      },
    );

    return completer.future;
  }
}
