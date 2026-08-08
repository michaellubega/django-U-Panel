import 'dart:async';

import 'package:flutter/material.dart';
import 'core/connectivity/app_connectivity.dart';
import 'core/platform/web_fast_boot.dart';
import 'core/storage/attendance_local_queues.dart';
import 'core/theme/app_theme.dart';
import 'core/navigation/app_navigator.dart';
import 'core/navigation/auth_gate.dart';
import 'core/auth/auth_repository.dart';
import 'core/api/api_auth.dart';
import 'core/api/api_client.dart';
import 'core/monitoring/app_sentry.dart';
import 'core/push/push_controller.dart';
import 'core/notifications/background_notification_entry.dart';
import 'core/session/app_session_reset.dart';

Future<void> main() async {
  await runAppWithSentry(_bootstrap);
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (WebFastBoot.enabled) {
    unawaited(_initStorageForWeb());
    unawaited(_initApiForWeb());
    runApp(const UPanelApp());
    WebFastBoot.afterFirstFrame(WebFastBoot.hideHtmlSplash);
    return;
  }

  runApp(const UPanelApp());
  unawaited(_initNativeStorageAndApi());
}

Future<void> _initNativeStorageAndApi() async {
  Future<void> storageFuture;
  try {
    storageFuture = AttendanceLocalQueues.ensureInitialized().then((_) {
      unawaited(AttendanceLocalQueues.sanitizeCorruptStorage());
    });
  } catch (e, st) {
    debugPrint('AttendanceLocalQueues startup failed: $e\n$st');
    storageFuture = AttendanceLocalQueues.recoverFromCorruptStorage().then((_) {
      unawaited(AttendanceLocalQueues.sanitizeCorruptStorage());
    });
  }

  try {
    await Future.wait<void>([
      storageFuture,
      ApiClient.instance.ensureLoaded(),
      ApiAuth.instance.restoreSession(),
    ]);
    unawaited(initializeBackgroundNotificationTasks());
    WebFastBoot.afterFirstFrame(() {
      unawaited(AppConnectivity.instance.initialize());
      unawaited(PushController.instance.initialize());
    });
    unawaited(AuthRepository.instance.loadInitialSession());
  } catch (e, st) {
    debugPrint('API startup failed: $e\n$st');
  }
}

Future<void> _initStorageForWeb() async {
  try {
    await AttendanceLocalQueues.ensureInitialized();
  } catch (e, st) {
    debugPrint('Web storage init failed: $e\n$st');
  }
}

Future<void> _initApiForWeb() async {
  try {
    await ApiClient.instance
        .ensureLoaded()
        .timeout(const Duration(seconds: 3));
    final token = ApiClient.instance.token;
    if (token != null && token.isNotEmpty) {
      await ApiAuth.instance
          .restoreSession()
          .timeout(const Duration(seconds: 5));
    }
    WebFastBoot.afterFirstFrame(() {
      unawaited(AppConnectivity.instance.initialize());
      unawaited(PushController.instance.initialize());
    });
  } catch (e, st) {
    debugPrint('API init (web) failed: $e\n$st');
    try {
      await ApiClient.instance.clearToken();
    } catch (_) {}
  }
}

class UPanelApp extends StatefulWidget {
  const UPanelApp({super.key});

  @override
  State<UPanelApp> createState() => _UPanelAppState();
}

class _UPanelAppState extends State<UPanelApp> {
  @override
  void initState() {
    super.initState();
    AuthRepository.instance.addListener(_onAuthChanged);
    AuthRepository.instance.loadInitialSession();
  }

  void _onAuthChanged() {
    final auth = AuthRepository.instance;
    final signedOutForUi = !auth.isLoggedIn &&
        !auth.signingOut &&
        !auth.isAuthenticating &&
        !auth.hasApiSession &&
        !auth.pendingWebSessionRestore &&
        auth.initialized;
    if (signedOutForUi) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        popToRootRoute();
      });
      AppSessionReset.onSignOutImmediate();
      unawaited(AppSessionReset.onSignOutDeferred());
    }
  }

  @override
  void dispose() {
    AuthRepository.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: uPanelRootNavigatorKey,
      scaffoldMessengerKey: uPanelRootScaffoldMessengerKey,
      title: 'U-Panel',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final defaultStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: AppTheme.textPrimary,
            ) ??
            TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontSizeBase,
              height: AppTheme.lineHeightBase / AppTheme.fontSizeBase,
            );
        return MediaQuery(
          data: media.copyWith(platformBrightness: Brightness.light),
          child: DefaultTextStyle(
            style: defaultStyle,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: const AuthGate(),
    );
  }
}
