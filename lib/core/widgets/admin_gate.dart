import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../errors/user_facing_errors.dart';
import '../theme/app_theme.dart';

/// Shows [child] only when the signed-in user is a QA admin.
class AdminGate extends StatelessWidget {
  const AdminGate({
    super.key,
    required this.child,
    this.title = 'Admin only',
    this.message = UserFacingErrors.adminOnly,
  });

  final Widget child;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        final auth = AuthRepository.instance;
        if (!auth.adminCheckDone) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (!auth.isAdmin) {
          return Scaffold(
            appBar: AppBar(
              title: Text(title),
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
            ),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
          );
        }
        return child;
      },
    );
  }
}
