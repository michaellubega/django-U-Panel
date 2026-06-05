import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../../features/auth/auth_screen.dart';
import '../../features/auth/email_verification_screen.dart';
import 'app_shell.dart';

/// Single [MaterialApp] home — swaps login / shell without replacing [home],
/// so the root navigator stack stays predictable on web and mobile.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        final auth = AuthRepository.instance;

        if (!auth.initialized || auth.isAuthenticating) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (!auth.isLoggedIn) {
          return AuthScreen(key: ValueKey('auth_${auth.sessionEpoch}'));
        }

        if (auth.needsStudentEmailVerification) {
          return const EmailVerificationScreen(
            key: ValueKey('student_email_verify'),
          );
        }

        return AppShell(
          key: ValueKey(
            'shell_${auth.sessionEpoch}_${auth.currentFirebaseUid}',
          ),
        );
      },
    );
  }
}
