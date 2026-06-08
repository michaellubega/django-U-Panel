import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Root [MaterialApp] navigator — used to clear pushed routes on sign-out.
final GlobalKey<NavigatorState> uPanelRootNavigatorKey =
    GlobalKey<NavigatorState>();

/// Root [ScaffoldMessenger] — snackbars float above bottom nav / nested scaffolds.
final GlobalKey<ScaffoldMessengerState> uPanelRootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

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
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      backgroundColor: isError ? AppTheme.error : null,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
