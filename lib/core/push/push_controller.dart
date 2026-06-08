import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_repository.dart';
import '../../features/attendance/data/attendance_repository.dart';
import '../../features/attendance/data/session_code_push_utils.dart';
import '../../features/attendance/models/attendance_models.dart';
import 'desktop_notice_watch.dart';
import 'fcm_web_config.dart';
import 'fcm_web_script_loader.dart';
import 'local_push_display.dart';
import 'push_foreground_display.dart';
import 'push_message_copy.dart';
import 'push_topic_names.dart';

/// Foreground display + FCM topic sync (Android / iOS) and desktop notice polling.
class PushController {
  PushController._();
  static final PushController instance = PushController._();

  FirebaseMessaging? _fm;

  FirebaseMessaging? get _messaging {
    if (Firebase.apps.isEmpty) return null;
    try {
      return _fm ??= FirebaseMessaging.instance;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('FirebaseMessaging unavailable: $e');
        debugPrint('$st');
      }
      return null;
    }
  }

  bool _initialized = false;
  final Set<String> _subscribedListTopics = {};
  String? _subscribedStudentTopic;
  String? _subscribedLecturerTopic;
  Future<void> _topicSyncSerialized = Future<void>.value();
  int _lastLoggedListTopicCount = -1;
  bool _subscribedAllNotices = false;

  /// FCM token + topic subscribe (not available on desktop or web).
  bool get _fcmNativeSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _topicMessagingSupported => _fcmNativeSupported;

  bool get _anyPushSupported =>
      _fcmNativeSupported ||
      kIsWeb ||
      DesktopNoticeWatch.instance.supported;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (Firebase.apps.isEmpty || !_anyPushSupported) {
      return;
    }

    FirebaseAuth.instance.authStateChanges().listen((_) {
      unawaited(syncTopicsForCurrentUser());
    });

    if (_fcmNativeSupported) {
      await _initFcmNative();
    } else if (kIsWeb) {
      await _initFcmWebForeground();
    }
    if (DesktopNoticeWatch.instance.supported) {
      await localPushEnsureInitialized();
    }

    await syncTopicsForCurrentUser();
  }

  Future<void> _initFcmNative() async {
    final fm = _messaging;
    if (fm == null) return;
    final settings = await fm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (kDebugMode) {
      debugPrint('FCM permission status: ${settings.authorizationStatus}');
    }

    await fm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    await localPushEnsureInitialized();

    FirebaseMessaging.onMessage.listen(_onForegroundMessage);

    try {
      final t = await fm.getToken();
      if (kDebugMode && t != null) {
        debugPrint('FCM token acquired (${t.length} chars)');
      } else if (kDebugMode && t == null) {
        debugPrint('FCM token is null — check Google Play services / network');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('FCM getToken failed: $e');
        debugPrint('$st');
      }
    }

    fm.onTokenRefresh.listen((_) {
      if (kDebugMode) debugPrint('FCM token refreshed');
      unawaited(syncTopicsForCurrentUser());
    });

  }

  Future<void> _initFcmWebForeground() async {
    final fm = _messaging;
    if (fm == null) return;
    try {
      await ensureFcmWebScriptLoaded();
    } catch (e) {
      if (kDebugMode) debugPrint('FCM web script load failed: $e');
    }
    await fm.requestPermission(alert: true, badge: true, sound: true);
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    try {
      final vk = kFcmWebVapidPublicKey.trim();
      if (vk.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            'FCM web: missing FIREBASE_VAPID_KEY — add '
            '--dart-define=FIREBASE_VAPID_KEY=...',
          );
        }
      } else {
        final t = await fm.getToken(vapidKey: vk);
        if (kDebugMode && t != null) {
          debugPrint('FCM web token acquired (${t.length} chars)');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('FCM web getToken failed: $e');
    }
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final auth = AuthRepository.instance;
    final kind = (message.data['kind'] as String? ?? '').toLowerCase();
    if (auth.adminCheckDone && auth.isAdmin) {
      if (kind == 'sessioncode' || kind == 'missedsession') return;
      if (!_adminShouldDisplayPushData(message.data)) return;
    }
    if (auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin) {
      if (kind == 'missedsession' || kind == 'sessioncode') return;
    }

    if (kind == 'sessioncode') {
      final code = SessionCodePushUtils.codeFromPushData(message.data);
      if (code != null &&
          await SessionCodePushUtils.isRemoteLearningSessionCode(code)) {
        return;
      }
    }

    final (title, body) = pushDisplayCopyForMessage(message);

    if (kIsWeb) {
      showForegroundPushDisplay(title, body);
      return;
    }

    await localPushShow(
      id: message.hashCode,
      title: title,
      body: body,
    );
  }

  /// Call after [AttendanceStore] is populated (e.g. after [loadAll]).
  Future<void> syncListTopicsFromStore() async {
    if (Firebase.apps.isEmpty || !_topicMessagingSupported) {
      return;
    }
    final run = _topicSyncSerialized.then((_) => _syncListTopicsFromStoreBody());
    _topicSyncSerialized = run.catchError((Object? _, StackTrace? __) {});
    return run;
  }

  Future<void> _syncListTopicsFromStoreBody() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final auth = AuthRepository.instance;
    final Set<String> desired;
    if (auth.adminCheckDone && auth.isAdmin) {
      desired = {};
    } else if (AttendanceRepository.isStudentScopedUser()) {
      await _ensureAttendanceLoadedForTopicSync();
      desired = _desiredListTopicsForSignedInStudent();
    } else {
      desired = {};
    }

    final toAdd = desired.difference(_subscribedListTopics);
    final toRemove = _subscribedListTopics.difference(desired);
    if (toAdd.isEmpty && toRemove.isEmpty) {
      await _syncStudentNoticeTopic();
      await _syncLecturerNoticeTopic();
      return;
    }

    final fm = _messaging;
    if (fm == null) return;

    for (final topic in toRemove) {
      try {
        await fm.unsubscribeFromTopic(topic);
        _subscribedListTopics.remove(topic);
      } catch (e) {
        if (kDebugMode) debugPrint('FCM unsubscribe $topic: $e');
      }
    }
    for (final topic in toAdd) {
      try {
        await fm.subscribeToTopic(topic);
        _subscribedListTopics.add(topic);
        if (kDebugMode) debugPrint('FCM subscribed: $topic');
      } catch (e) {
        if (kDebugMode) debugPrint('FCM subscribe $topic: $e');
      }
    }
    if (kDebugMode &&
        _lastLoggedListTopicCount != _subscribedListTopics.length) {
      _lastLoggedListTopicCount = _subscribedListTopics.length;
      debugPrint(
        'FCM list topics desired=${desired.length} current=${_subscribedListTopics.length}',
      );
    }
    await _syncStudentNoticeTopic();
    await _syncLecturerNoticeTopic();
  }

  Set<String> _desiredListTopicsForSignedInStudent() {
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) return {};
    final student = AttendanceStore.findStudentByReg(reg);
    final studentId = student?.id.trim() ?? '';
    if (studentId.isEmpty) return {};
    final topics = <String>{};
    for (final si in AttendanceStore.signIns) {
      if (si.studentId == studentId) {
        topics.add(fcmListNoticeTopic(si.listId));
      }
    }
    return topics;
  }

  Future<void> syncTopicsForCurrentUser() async {
    if (Firebase.apps.isEmpty || !_anyPushSupported) return;
    final run = _topicSyncSerialized.then((_) => _syncTopicsForCurrentUserBody());
    _topicSyncSerialized = run.catchError((Object? _, StackTrace? __) {});
    return run;
  }

  Future<void> _syncTopicsForCurrentUserBody() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (_topicMessagingSupported) {
        await _unsubscribeAllKnownTopics();
      }
      await DesktopNoticeWatch.instance.stop();
      return;
    }

    await _waitForRoleReady();
    if (!AuthRepository.instance.roleCheckDone) {
      if (kDebugMode) {
        debugPrint('Push sync skipped: role checks not finished yet');
      }
      return;
    }

    if (_topicMessagingSupported) {
      final fm = _messaging;
      if (fm == null) return;
      if (!_subscribedAllNotices) {
        try {
          await fm.subscribeToTopic(kFcmAllNoticesTopic);
          _subscribedAllNotices = true;
          if (kDebugMode) debugPrint('FCM subscribed: $kFcmAllNoticesTopic');
        } catch (e) {
          if (kDebugMode) debugPrint('FCM subscribe all_notices: $e');
        }
      }
      await _syncListTopicsFromStoreBody();
    }

    if (DesktopNoticeWatch.instance.supported) {
      await DesktopNoticeWatch.instance.restart();
    }
  }

  Future<void> _waitForRoleReady() async {
    final auth = AuthRepository.instance;
    for (var i = 0; i < 40 && !auth.roleCheckDone; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _ensureAttendanceLoadedForTopicSync() async {
    await _waitForRoleReady();
    if (!AuthRepository.instance.roleCheckDone) return;
    final repo = AttendanceRepository.instance;
    if (repo.isLoaded || repo.hasCachedStore) return;
    try {
      await repo.bootstrapLoadIfNeeded();
    } catch (_) {}
  }

  Future<void> _unsubscribeAllKnownTopics() async {
    final copy = Set<String>.from(_subscribedListTopics);
    _subscribedListTopics.clear();
    _subscribedAllNotices = false;
    _lastLoggedListTopicCount = -1;
    final fm = _messaging;
    if (fm == null) return;
    await Future.wait<void>([
      fm.unsubscribeFromTopic(kFcmAllNoticesTopic).catchError((_) {}),
      for (final topic in copy)
        fm.unsubscribeFromTopic(topic).catchError((_) {}),
      _unsubscribeStudentTopicOnly(),
      _unsubscribeLecturerTopicOnly(),
    ]);
  }

  Future<void> _syncLecturerNoticeTopic() async {
    if (!_topicMessagingSupported) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await _unsubscribeLecturerTopicOnly();
      return;
    }
    final desired = _desiredLecturerTopic();
    if (desired == _subscribedLecturerTopic) return;
    await _unsubscribeLecturerTopicOnly();
    if (desired == null || desired.isEmpty) return;
    final fm = _messaging;
    if (fm == null) return;
    try {
      await fm.subscribeToTopic(desired);
      _subscribedLecturerTopic = desired;
      if (kDebugMode) debugPrint('FCM subscribed: $desired');
    } catch (e) {
      if (kDebugMode) debugPrint('FCM subscribe lecturer topic: $e');
    }
  }

  String? _desiredLecturerTopic() {
    final auth = AuthRepository.instance;
    if (auth.adminCheckDone && auth.isAdmin) return null;
    if (!auth.lecturerCheckDone || !auth.isLecturer) return null;
    final uid = auth.currentFirebaseUid?.trim();
    if (uid == null || uid.isEmpty) return null;
    return fcmLecturerNoticeTopic(uid);
  }

  /// Admins only receive FCM for broadcast (`allAppUsers`) notices.
  bool _adminShouldDisplayPushData(Map<String, dynamic> data) {
    final aud = (data['audience'] as String? ?? 'allAppUsers')
        .trim()
        .toLowerCase();
    if (aud == 'classlist' ||
        aud == 'class_list' ||
        aud == 'student' ||
        aud == 'targetstudent' ||
        aud == 'lecturer') {
      return false;
    }
    final kind = (data['kind'] as String? ?? '').toLowerCase();
    if (kind == 'sessioncode' ||
        kind == 'missedsession' ||
        kind == 'lecturertakeattendance') {
      return false;
    }
    return true;
  }

  Future<void> _unsubscribeLecturerTopicOnly() async {
    final t = _subscribedLecturerTopic;
    if (t == null || t.isEmpty) return;
    final fm = _messaging;
    if (fm == null) return;
    try {
      await fm.unsubscribeFromTopic(t);
    } catch (_) {}
    _subscribedLecturerTopic = null;
  }

  Future<void> _syncStudentNoticeTopic() async {
    if (!_topicMessagingSupported) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await _unsubscribeStudentTopicOnly();
      return;
    }
    final desired = _desiredStudentTopic();
    if (desired == _subscribedStudentTopic) return;
    await _unsubscribeStudentTopicOnly();
    if (desired == null || desired.isEmpty) return;
    final fm = _messaging;
    if (fm == null) return;
    try {
      await fm.subscribeToTopic(desired);
      _subscribedStudentTopic = desired;
      if (kDebugMode) debugPrint('FCM subscribed: $desired');
    } catch (e) {
      if (kDebugMode) debugPrint('FCM subscribe student topic: $e');
    }
  }

  String? _desiredStudentTopic() {
    if (AuthRepository.instance.adminCheckDone &&
        AuthRepository.instance.isAdmin) {
      return null;
    }
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) return null;
    final upper = reg.toUpperCase();
    for (final s in AttendanceStore.students) {
      if (s.registrationNumber.trim().toUpperCase() == upper) {
        final id = s.id.trim();
        if (id.isEmpty) return null;
        return fcmStudentNoticeTopic(id);
      }
    }
    return null;
  }

  Future<void> _unsubscribeStudentTopicOnly() async {
    final t = _subscribedStudentTopic;
    if (t == null || t.isEmpty) return;
    final fm = _messaging;
    if (fm == null) return;
    try {
      await fm.unsubscribeFromTopic(t);
    } catch (_) {}
    _subscribedStudentTopic = null;
  }

  Future<void> resetForSignOut() async {
    await DesktopNoticeWatch.instance.stop();
    if (Firebase.apps.isEmpty || !_topicMessagingSupported) {
      _subscribedListTopics.clear();
      _subscribedStudentTopic = null;
      _subscribedLecturerTopic = null;
      return;
    }
    await _unsubscribeAllKnownTopics();
  }
}
