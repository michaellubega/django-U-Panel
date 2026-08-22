import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'onesignal_service.dart';

/// OneSignal integration verification dialog (required by SDK setup guide).
class OneSignalIntegrationVerification {
  OneSignalIntegrationVerification._();

  static bool _wired = false;

  static void wireIfNeeded(BuildContext context) {
    if (_wired || !OneSignalService.supported) return;
    _wired = true;
    OneSignalService.setupIntegrationVerification((requestPermission) {
      final navigator = Navigator.of(context, rootNavigator: true);
      if (!navigator.mounted) return;
      _showDialog(navigator.context, requestPermission);
    });
  }

  static void _showDialog(
    BuildContext context,
    void Function() requestPermission,
  ) {
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      showCupertinoDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('Your OneSignal SDK integration is complete!'),
          content: const Text(
            'You can now send Push Notifications & In-App Messages through OneSignal. '
            'Tap below to enable push notifications.',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () {
                Navigator.pop(dialogContext);
                requestPermission();
              },
              child: const Text('Got it'),
            ),
          ],
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Your OneSignal SDK integration is complete!'),
        content: const Text(
          'You can now send Push Notifications & In-App Messages through OneSignal. '
          'Tap below to enable push notifications.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              requestPermission();
            },
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
