/// Shapes notice text for the system tray.
(String title, String body) pushDisplayCopyForMessage({
  required Map<String, dynamic> data,
  String? notificationTitle,
  String? notificationBody,
}) {
  var title = (notificationTitle ?? data['title'] as String? ?? 'Notice').trim();
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

  final kind = (data['kind'] as String? ?? '').toLowerCase();
  var body = (notificationBody ?? data['body'] as String? ?? '').trim();
  if (kind == 'sessioncode') {
    return (title, 'Your class is ready. Open the app.');
  }
  if (kind == 'lecturertakeattendance') {
    body = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (body.isEmpty) {
      body =
          'Your class is ready — open U-Panel and start the attendance session.';
    }
    return (title, body);
  }
  if (kind == 'qastartattendance') {
    body = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (body.isEmpty) {
      body =
          'A lecturer has not opened attendance 1 hour 30 minutes after lesson time. '
          'Open U-Panel to start the session.';
    }
    return (title, body);
  }

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
    data: {
      'title': title,
      'body': body,
      if (kind != null) 'kind': kind,
    },
  );
}
