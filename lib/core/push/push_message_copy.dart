import 'package:firebase_messaging/firebase_messaging.dart';

/// Shapes FCM / notice text for the system tray (matches Cloud Functions copy).
(String title, String body) pushDisplayCopyForMessage(RemoteMessage message) {
  final n = message.notification;
  var title = (n?.title ?? message.data['title'] as String? ?? 'Notice').trim();
  title = title
      .replaceFirst(
        RegExp(r'^Check-in is open:\s*', caseSensitive: false),
        '',
      )
      .replaceFirst(
        RegExp(r'^Check in is open:\s*', caseSensitive: false),
        '',
      )
      .trim();
  if (title.isEmpty) title = 'Notice';

  final kind = (message.data['kind'] as String? ?? '').toLowerCase();
  if (kind == 'sessioncode') {
    return (title, 'Your class is ready. Open the app.');
  }

  var body = (n?.body ?? message.data['body'] as String? ?? '').trim();
  if (kind == 'missedsession') {
    body = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (body.length > 220) {
      body = '${body.substring(0, 217)}...';
    }
    if (body.isEmpty) {
      body =
          'You were marked absent for a class session. Open the app to read the full notice.';
    }
    return (title, body);
  }
  body = body
      .replaceAll(
          RegExp(r'open\s+attendance[^.!?]*[.!?]?', caseSensitive: false), '')
      .replaceAll(
          RegExp(r'\b(location|gps)\s+check-?in\b', caseSensitive: false), '')
      .replaceAll(
          RegExp(r'\b(location|gps)\b[^.!?]*[.!?]?', caseSensitive: false),
          '')
      .replaceAll(RegExp(r'\bcheck-?in\b', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (body.contains('read the full notice')) {
    body = 'You have a new message in the app.';
  }
  if (body.isEmpty) {
    body = 'You have a new message in the app.';
  }
  return (title, body);
}

(String title, String body) pushDisplayCopyForNotice({
  required String title,
  required String body,
  String? kind,
}) {
  return pushDisplayCopyForMessage(
    RemoteMessage(
      data: {
        'title': title,
        'body': body,
        if (kind != null) 'kind': kind,
      },
    ),
  );
}
