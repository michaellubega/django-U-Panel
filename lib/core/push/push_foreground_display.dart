import 'push_foreground_display_stub.dart'
    if (dart.library.html) 'push_foreground_display_web.dart' as impl;

/// Browser notification when the app tab is open (web). No-op on other platforms.
void showForegroundPushDisplay(String title, String body) {
  impl.showForegroundPushDisplay(title, body);
}

/// Requests browser notification permission on web.
Future<bool> requestWebNotificationPermission() =>
    impl.requestWebNotificationPermission();
