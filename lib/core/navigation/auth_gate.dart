import 'dart:async';

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
  var _showLoadingRetry = false;
  Timer? _loadingRetryTimer;

  @override
  void initState() {
    super.initState();
    AuthRepository.instance.addListener(_onAuthChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _hideHtmlSplashOnce());
    _scheduleLoadingRetryTimer();
  }

  @override
  void dispose() {
    _loadingRetryTimer?.cancel();
    AuthRepository.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleLoadingRetryTimer();
  }

  void _scheduleLoadingRetryTimer() {
    _loadingRetryTimer?.cancel();
    final auth = AuthRepository.instance;
    final awaitingAuthUi =
        !auth.initialized || auth.pendingWebSessionRestore;
    if (!awaitingAuthUi) {
      if (_showLoadingRetry) {
        setState(() => _showLoadingRetry = false);
      }
      return;
    }
    _loadingRetryTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      final stillWaiting = !AuthRepository.instance.initialized ||
          AuthRepository.instance.pendingWebSessionRestore;
      if (!stillWaiting) return;
      setState(() => _showLoadingRetry = true);
    });
  }

  void _hideHtmlSplashOnce() {
    if (_htmlSplashHidden || !WebFastBoot.enabled) return;
    _htmlSplashHidden = true;
    WebFastBoot.hideHtmlSplash();
  }

  Future<void> _retryFromLoadingScreen() async {
    setState(() => _showLoadingRetry = false);
    await AuthRepository.instance.abandonWebSessionRestore();
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
          child = WebAppLoadingScreen(
            message: _showLoadingRetry
                ? 'Still loading. The server may be restarting — tap Retry to open sign in.'
                : message,
            onRetry: _showLoadingRetry ? _retryFromLoadingScreen : null,
          );
        } else if (auth.isLoggedIn && auth.needsEmailVerification) {
          // After signup/sign-in, show verification before login/register UI — even
          // while [_beginAuthenticating] is winding down (otherwise users stay on
          // the create-account form after a successful registration).
          child = const EmailVerificationScreen(
            key: ValueKey('email_verify'),
          );
        } else if (!auth.isLoggedIn || auth.isAuthenticating) {
          if (auth.pendingWebSessionRestore) {
            child = WebAppLoadingScreen(
              message: 'Signing you in…',
              onRetry: _retryFromLoadingScreen,
            );
          } else {
            // Keep [AuthScreen] mounted while sign-in/register runs so errors
            // are not lost when Firebase briefly emits a session (e.g. rollback).
            child = AuthScreen(key: ValueKey('auth_${auth.sessionEpoch}'));
          }
        } else if (auth.needsKiuAdminOnboarding) {
          child = const KiuAdminOnboardingScreen(
            key: ValueKey('kiu_admin_onboarding'),
          );
        } else {
          child = AppShell(
            key: ValueKey(
              'shell_${auth.sessionEpoch}_${auth.currentUserId}',
            ),
          );
        }

        return child;
      },
    );
  }
}
