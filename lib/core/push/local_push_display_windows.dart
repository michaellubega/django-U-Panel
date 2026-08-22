import 'package:windows_notification/notification_message.dart';
import 'package:windows_notification/windows_notification.dart';

WindowsNotification? _winNotify;
bool _initialized = false;

Future<void> localPushEnsureInitialized() async {
  if (_initialized) return;
  _winNotify = WindowsNotification(applicationId: null);
  _initialized = true;
}

Future<void> localPushShow({
  required int id,
  required String title,
  required String body,
}) async {
  if (!_initialized) await localPushEnsureInitialized();
  final plugin = _winNotify;
  if (plugin == null) return;
  final message = NotificationMessage.fromPluginTemplate(
    'upanel_$id',
    title,
    body,
    group: 'upanel_notices',
  );
  try {
    plugin.showNotificationPluginTemplate(message);
  } catch (_) {}
}
