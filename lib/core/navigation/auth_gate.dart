import 'package:flutter/material.dart';
import '../platform/web_fast_boot.dart';
import '../auth/auth_repository.dart';
import '../widgets/web_app_loading_screen.dart';
import '../../features/auth/auth_screen.dart';
import '../../features/auth/email_verification_screen.dart';
import '../../features/auth/kiu_admin_onboarding_screen.dart';
import 'app_shell.dart';

/// Single [MaterialApp] home — swaps login / shell without replacing [home],
/// so the root navigator stack stays predictable on web and mobile.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  var _htmlSplashHidden = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _hideHtmlSplashOnce());
  }

  void _hideHtmlSplashOnce() {
    if (_htmlSplashHidden || !WebFastBoot.enabled) return;
    _htmlSplashHidden = true;
    WebFastBoot.hideHtmlSplash();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        final auth = AuthRepository.instance;

        // Web session restore uses [pendingWebSessionRestore]. Email/password sign-in
        // shows progress in [_LoginVerificationScreen]; do not replace [AuthScreen]
        // home while that dialog is open — that caused setState-during-build loops.
        final awaitingAuthUi =
            !auth.initialized || auth.pendingWebSessionRestore;

        Widget child;
        if (awaitingAuthUi) {
          final message = !auth.initialized
              ? 'Starting U-Panel…'
              : 'Signing you in…';
          child = WebAppLoadingScreen(message: message);
        } else if (!auth.isLoggedIn || auth.isAuthenticating) {
          if (auth.pendingWebSessionRestore) {
            child = const WebAppLoadingScreen(message: 'Signing you in…');
          } else {
            // Keep [AuthScreen] mounted while sign-in/register runs so errors
            // are not lost when Firebase briefly emits a session (e.g. rollback).
            child = AuthScreen(key: ValueKey('auth_${auth.sessionEpoch}'));
          }
        } else if (auth.needsEmailVerification) {
          child = const EmailVerificationScreen(
            key: ValueKey('email_verify'),
          );
        } else if (auth.needsKiuAdminOnboarding) {
          child = const KiuAdminOnboardingScreen(
            key: ValueKey('kiu_admin_onboarding'),
          );
        } else {
          child = AppShell(
            key: ValueKey(
              'shell_${auth.sessionEpoch}_${auth.currentFirebaseUid}',
            ),
          );
        }

        return child;
      },
    );
  }
}
