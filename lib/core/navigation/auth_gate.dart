import 'dart:async';

import 'package:flutter/material.dart';
import '../platform/web_fast_boot.dart';
import '../auth/auth_repository.dart';
import '../widgets/web_app_loading_screen.dart';
import '../navigation/app_navigator.dart';
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
    final auth = AuthRepository.instance;
    if (auth.shouldShowEmailVerificationUi) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        popToRootRoute();
      });
    }
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
        } else if (auth.shouldShowEmailVerificationUi) {
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
            // Nested navigator so staff-register / creating-account routes are
            // disposed when this branch is replaced by email verification.
            child = _AuthFlowNavigator(
              key: ValueKey('auth_flow_${auth.sessionEpoch}'),
              authScreen: AuthScreen(key: ValueKey('auth_${auth.sessionEpoch}')),
            );
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

/// Hosts [AuthScreen] and routes pushed from it (staff register, creating account).
///
/// When [AuthGate] swaps to [EmailVerificationScreen], this navigator is removed
/// from the tree and all stacked auth routes are cleared automatically.
class _AuthFlowNavigator extends StatelessWidget {
  const _AuthFlowNavigator({super.key, required this.authScreen});

  final Widget authScreen;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (settings) {
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => authScreen,
        );
      },
    );
  }
}
