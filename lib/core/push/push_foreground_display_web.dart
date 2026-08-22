// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

void showForegroundPushDisplay(String title, String body) {
  if (!html.Notification.supported) return;
  if (html.Notification.permission != 'granted') return;
  try {
    html.Notification(
      title,
      body: body.isEmpty ? null : body,
      tag: 'upanel_fg_${title.hashCode}_${body.hashCode}',
    );
  } catch (_) {}
}

Future<bool> requestWebNotificationPermission() async {
  if (!html.Notification.supported) return false;
  if (html.Notification.permission == 'granted') return true;
  if (html.Notification.permission == 'denied') return false;
  try {
    final result = await html.Notification.requestPermission();
    return result == 'granted';
  } catch (_) {
    return false;
  }
}
