import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Short success strip at the **top** of the scaffold (via [MaterialBanner]).
void showAttendanceTopSuccessBanner(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.clearMaterialBanners();
  messenger.showMaterialBanner(
    MaterialBanner(
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      leading: const Icon(
        Icons.check_circle_rounded,
        color: AppTheme.success,
        size: 28,
      ),
      backgroundColor: AppTheme.success.withValues(alpha: 0.14),
      content: Text(
        message,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => messenger.hideCurrentMaterialBanner(),
          child: Text('OK', style: TextStyle(color: AppTheme.primary)),
        ),
      ],
    ),
  );
  unawaited(
    Future<void>.delayed(const Duration(seconds: 4), () {
      messenger.hideCurrentMaterialBanner();
    }),
  );
}
