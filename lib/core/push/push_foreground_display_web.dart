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
