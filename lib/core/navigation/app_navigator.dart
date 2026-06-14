import 'package:flutter/material.dart';

import '../errors/user_facing_errors.dart';
import '../theme/app_theme.dart';
import 'instant_page_transitions.dart';

/// Root [MaterialApp] navigator — used to clear pushed routes on sign-out.
final GlobalKey<NavigatorState> uPanelRootNavigatorKey =
    GlobalKey<NavigatorState>();

/// Root [ScaffoldMessenger] — snackbars float above bottom nav / nested scaffolds.
final GlobalKey<ScaffoldMessengerState> uPanelRootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Push a screen with U-Panel's short fade/slide transition.
Future<T?> pushAppPage<T>(
  BuildContext context,
  Widget page, {
  bool fullscreenDialog = false,
}) {
  return Navigator.of(context).push<T>(
    UPanelPageRoute<T>(
      fullscreenDialog: fullscreenDialog,
      builder: (_) => page,
    ),
  );
}

/// Pops every route above the root so sign-out always lands on login.
void popToRootRoute() {
  uPanelRootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
}

ScaffoldMessengerState? _rootScaffoldMessenger() {
  final keyed = uPanelRootScaffoldMessengerKey.currentState;
  if (keyed != null) return keyed;
  final ctx = uPanelRootNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return null;
  return ScaffoldMessenger.maybeOf(ctx);
}

/// Hides the current root snackbar if one is showing.
void hideRootSnackBar() {
  _rootScaffoldMessenger()?.hideCurrentSnackBar();
}

/// Snackbar on the root scaffold (works after settings / shell dispose).
void showRootSnackBar(
  String message, {
  Duration duration = const Duration(seconds: 4),
  bool isError = false,
}) {
  final messenger = _rootScaffoldMessenger();
  if (messenger == null) return;
  final safe = UserFacingErrors.sanitize(
    message,
    fallback: UserFacingErrors.genericTryAgain,
  );
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(safe),
      duration: duration,
      backgroundColor: isError ? AppTheme.error : null,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
