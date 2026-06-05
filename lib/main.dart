import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'core/connectivity/app_connectivity.dart';
import 'core/storage/attendance_local_queues.dart';
import 'core/theme/app_theme.dart';
import 'core/navigation/app_navigator.dart';
import 'core/navigation/auth_gate.dart';
import 'core/auth/auth_repository.dart';
import 'core/push/push_background_handler.dart';
import 'core/push/push_controller.dart';
import 'core/session/app_session_reset.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await AttendanceLocalQueues.ensureInitialized();
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('AttendanceLocalQueues.ensureInitialized failed: $e');
      debugPrint('$st');
    }
  }
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    unawaited(AppConnectivity.instance.initialize());
    if (Firebase.apps.isNotEmpty) {
      // Web uses `web/firebase-messaging-sw.js`; mobile uses a Dart background isolate.
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      }
      unawaited(PushController.instance.initialize());
    }
  } on UnsupportedError catch (e) {
    // Firebase not configured for this platform.
    // App runs, but Firebase-backed features stay unavailable.
    if (kDebugMode) {
      debugPrint('Firebase is not configured for this platform: $e');
      debugPrint(
        'Run `flutterfire configure --platforms=android,web,windows,linux,macos` '
        'for your target desktop OS, then rebuild.',
      );
    }
  } catch (e, st) {
    // Other init errors (e.g. no config files, wrong google-services.json).
    if (kDebugMode) {
      debugPrint('Firebase.initializeApp failed: $e');
      debugPrint('$st');
    }
  }
  runApp(const UPanelApp());
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
    if (!auth.isLoggedIn &&
        !auth.signingOut &&
        !auth.isAuthenticating &&
        !auth.hasFirebaseSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        popToRootRoute();
      });
      AppSessionReset.onSignOutImmediate();
      unawaited(AppSessionReset.onSignOutDeferred());
    }
    if (mounted) setState(() {});
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
