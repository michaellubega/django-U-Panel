import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client_config.dart';
import '../auth/auth_repository.dart';
import '../monitoring/app_sentry.dart';
import '../../features/attendance/data/session_code_auto_check_in.dart';
import 'desktop_notice_watch.dart';
import 'local_push_display.dart';
import 'onesignal_service.dart';
import 'push_message_copy.dart';

/// Push: OneSignal on mobile, notice polling on web/desktop while the app runs.
class PushController {
  PushController._();
  static final PushController instance = PushController._();

  bool _initialized = false;

  bool get _foregroundWatchSupported => DesktopNoticeWatch.instance.supported;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    AuthRepository.instance.addListener(_onAuthChanged);
    await localPushEnsureInitialized();
    await loadClientConfig();
    await OneSignalService.initialize(
      onOpened: _handlePushOpened,
      onForeground: _handlePushForeground,
      onSubscriptionChanged: () => unawaited(syncTopicsForCurrentUser()),
    );
    await syncTopicsForCurrentUser();
  }

  void _onAuthChanged() {
    unawaited(syncTopicsForCurrentUser());
  }

  Future<void> syncListTopicsFromStore() async {
    await syncTopicsForCurrentUser();
  }

  Future<void> syncTopicsForCurrentUser() async {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || auth.needsEmailVerification) {
      await OneSignalService.logout();
      await DesktopNoticeWatch.instance.stop();
      clearSentryUser();
      return;
    }
    if (!auth.roleCheckDone) {
      await _waitForRoleReady();
    }
    if (!auth.roleCheckDone) {
      if (kDebugMode) {
        debugPrint('Push sync skipped: role checks not finished yet');
      }
      return;
    }

    setSentryUser(
      id: auth.currentUserId,
      email: auth.currentUserEmail,
      role: auth.resolvedRole.name,
    );

    if (OneSignalService.supported) {
      await OneSignalService.syncForCurrentUser();
    }
    if (_foregroundWatchSupported) {
      await DesktopNoticeWatch.instance.restart();
    }
  }

  void _handlePushOpened(Map<String, dynamic> data) {
    unawaited(SessionCodeAutoCheckIn.handlePushData(data));
  }

  void _handlePushForeground(Map<String, dynamic> data) {
    final (title, body) = pushDisplayCopyForMessage(data: data);
    if (kDebugMode) {
      debugPrint('Push foreground: $title — $body');
    }
    unawaited(SessionCodeAutoCheckIn.handlePushData(data));
  }

  Future<void> _waitForRoleReady() async {
    final auth = AuthRepository.instance;
    for (var i = 0; i < 40 && !auth.roleCheckDone; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> resetForSignOut() async {
    await OneSignalService.logout();
    await DesktopNoticeWatch.instance.stop();
    clearSentryUser();
  }
}
