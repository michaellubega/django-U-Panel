import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/auth_repository.dart';
import '../monitoring/app_sentry.dart';
import 'desktop_notice_watch.dart';
import 'local_push_display.dart';
import 'onesignal_service.dart';

/// Push: OneSignal on mobile, desktop notice polling on Windows/Linux/macOS.
class PushController {
  PushController._();
  static final PushController instance = PushController._();

  bool _initialized = false;

  bool get _desktopSupported => DesktopNoticeWatch.instance.supported;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    AuthRepository.instance.addListener(_onAuthChanged);
    await localPushEnsureInitialized();
    await OneSignalService.initialize();
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
    if (_desktopSupported) {
      await DesktopNoticeWatch.instance.restart();
    }
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
