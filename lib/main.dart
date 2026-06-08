import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'core/connectivity/app_connectivity.dart';
import 'core/platform/web_fast_boot.dart';
import 'core/storage/attendance_local_queues.dart';
import 'core/theme/app_theme.dart';
import 'core/navigation/app_navigator.dart';
import 'core/navigation/auth_gate.dart';
import 'core/auth/auth_repository.dart';
import 'core/push/push_background_handler.dart';
import 'core/push/push_controller.dart';
import 'core/notifications/background_notification_entry.dart';
import 'core/session/app_session_reset.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (WebFastBoot.enabled) {
    // Show Flutter UI ASAP; storage + Firebase init must not block runApp.
    unawaited(_initStorageForWeb());
    unawaited(_initFirebaseForWeb());
    runApp(const UPanelApp());
    return;
  }

  try {
    await AttendanceLocalQueues.ensureInitialized();
    unawaited(AttendanceLocalQueues.sanitizeCorruptStorage());
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('AttendanceLocalQueues startup failed: $e');
      debugPrint('$st');
    }
    await AttendanceLocalQueues.recoverFromCorruptStorage();
    unawaited(AttendanceLocalQueues.sanitizeCorruptStorage());
  }
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    unawaited(initializeBackgroundNotificationTasks());
    unawaited(AppConnectivity.instance.initialize());
    if (Firebase.apps.isNotEmpty) {
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      }
      unawaited(PushController.instance.initialize());
    }
  } on UnsupportedError catch (e) {
    if (kDebugMode) {
      debugPrint('Firebase is not configured for this platform: $e');
      debugPrint(
        'Run `flutterfire configure --platforms=android,web,windows,linux,macos` '
        'for your target desktop OS, then rebuild.',
      );
    }
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('Firebase.initializeApp failed: $e');
      debugPrint('$st');
    }
  }
  runApp(const UPanelApp());
}

Future<void> _initStorageForWeb() async {
  try {
    await AttendanceLocalQueues.ensureInitialized();
    unawaited(AttendanceLocalQueues.sanitizeCorruptStorage());
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('Web storage init failed: $e');
      debugPrint('$st');
    }
  }
}

Future<void> _initFirebaseForWeb() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // Connectivity + FCM are not needed for the login screen — defer until after
    // first frame (PushController runs from [AppShell] once signed in).
    WebFastBoot.afterFirstFrame(() {
      unawaited(AppConnectivity.instance.initialize());
    });
  } on UnsupportedError catch (e) {
    if (kDebugMode) {
      debugPrint('Firebase is not configured for web: $e');
    }
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('Firebase.initializeApp (web) failed: $e');
      debugPrint('$st');
    }
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
    // Web fast boot: cached session / Firebase init must not clear attendance or
    // touch Firestore before [Firebase.initializeApp] completes.
    final signedOutForUi = !auth.isLoggedIn &&
        !auth.signingOut &&
        !auth.isAuthenticating &&
        !auth.hasFirebaseSession &&
        !auth.pendingWebSessionRestore &&
        auth.initialized;
    if (signedOutForUi) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        popToRootRoute();
      });
      AppSessionReset.onSignOutImmediate();
      unawaited(AppSessionReset.onSignOutDeferred());
    }
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
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
      home: const AuthGate(),
    );
  }
}
