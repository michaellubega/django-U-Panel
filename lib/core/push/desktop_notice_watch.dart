import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_repository.dart';
import '../../features/attendance/attendance_list_hierarchy.dart';
import '../../features/attendance/models/attendance_models.dart';
import '../../features/notices/data/notices_repository.dart';
import 'local_push_display.dart';
import 'push_message_copy.dart';

/// Desktop (Windows / Linux / macOS) has no FCM client — poll Firestore for new
/// notices and show native toasts while the app is running.
class DesktopNoticeWatch {
  DesktopNoticeWatch._();
  static final DesktopNoticeWatch instance = DesktopNoticeWatch._();

  static const _prefPrefix = 'desktop_push_watermark_ms_v1_';
  static const _pollInterval = Duration(seconds: 45);

  Timer? _timer;
  bool _polling = false;
  String? _activeUid;

  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  Future<void> restart() async {
    if (!supported || Firebase.apps.isEmpty) return;
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn) {
      await stop();
      return;
    }
    if (!auth.roleCheckDone) {
      await _waitForRoleReady();
    }
    if (!auth.isLoggedIn || !auth.roleCheckDone) return;

    final uid = auth.currentFirebaseUid?.trim() ?? '';
    if (uid.isEmpty) return;
    if (_activeUid != uid) {
      _activeUid = uid;
    }

    await localPushEnsureInitialized();
    _timer ??= Timer.periodic(_pollInterval, (_) => unawaited(_pollOnce()));
    unawaited(_pollOnce());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _activeUid = null;
  }

  Future<void> _waitForRoleReady() async {
    final auth = AuthRepository.instance;
    for (var i = 0; i < 24 && !auth.roleCheckDone; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _pollOnce() async {
    if (_polling) return;
    _polling = true;
    try {
      final auth = AuthRepository.instance;
      if (!auth.isLoggedIn || !auth.roleCheckDone) return;

      final uid = auth.currentFirebaseUid?.trim() ?? '';
      if (uid.isEmpty) return;

      final notices = await NoticesRepository.instance.fetchRecent(limit: 40);
      final visible = _visibleNotices(notices);
      if (visible.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final wmKey = '$_prefPrefix$uid';
      final wmMs = prefs.getInt(wmKey) ?? 0;
      final watermark = DateTime.fromMillisecondsSinceEpoch(wmMs);

      NoticeRecord? newest;
      for (final n in visible) {
        if (!noticeIsLive(n)) continue;
        final effective = noticeEffectiveAt(n);
        if (!effective.isAfter(watermark)) continue;
        if (newest == null || effective.isAfter(noticeEffectiveAt(newest))) {
          newest = n;
        }
        if (wmMs == 0) continue;
        final (title, body) = pushDisplayCopyForNotice(
          title: n.title,
          body: n.body,
          kind: n.kind,
        );
        if (!_shouldShowPushForNotice(n)) continue;
        if (isRemoteLearningSessionCodeNotice(n)) continue;
        await localPushShow(
          id: n.id.hashCode,
          title: title,
          body: body,
        );
      }

      if (newest != null) {
        await prefs.setInt(
          wmKey,
          noticeEffectiveAt(newest).millisecondsSinceEpoch,
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('DesktopNoticeWatch: $e');
    } finally {
      _polling = false;
    }
  }

  List<NoticeRecord> _visibleNotices(List<NoticeRecord> notices) {
    final auth = AuthRepository.instance;
    final admin = auth.adminCheckDone && auth.isAdmin;
    final lecturer =
        auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin;
    final reg = auth.currentRegistrationNumber?.trim();
    String? studentId;
    if (reg != null && reg.isNotEmpty) {
      final s = AttendanceStore.findStudentByReg(reg);
      studentId = s?.id.trim();
    }
    final signedListIds = <String>{};
    if (studentId != null && studentId.isNotEmpty) {
      for (final si in AttendanceStore.signIns) {
        if (si.studentId == studentId) signedListIds.add(si.listId);
      }
    }
    final lecturerListIds = lecturer
        ? attendanceListsForCurrentStaff().map((l) => l.id).toSet()
        : const <String>{};

    return notices
        .where(
          (n) => noticeVisibleToUser(
            n,
            admin: admin,
            lecturer: lecturer,
            lecturerListIds: lecturerListIds,
            lecturerFirebaseUid: auth.currentFirebaseUid,
            studentId: studentId,
            signedListIds: signedListIds,
          ),
        )
        .toList();
  }

  bool _shouldShowPushForNotice(NoticeRecord n) {
    final auth = AuthRepository.instance;
    if (auth.adminCheckDone && auth.isAdmin) {
      return noticeNotifiesAdmin(n);
    }
    final kind = (n.kind ?? '').toLowerCase();
    if (auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin) {
      if (kind == 'missedsession' || kind == 'sessioncode') return false;
    }
    return true;
  }
}
