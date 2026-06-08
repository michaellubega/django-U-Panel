import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _androidChannelId = 'upanel_notices';
const _androidChannelName = 'U-Panel';

final FlutterLocalNotificationsPlugin _local =
    FlutterLocalNotificationsPlugin();

/// Shared plugin instance (also used by [LocalNotificationScheduler]).
FlutterLocalNotificationsPlugin get localNotificationsPlugin => _local;
bool _initialized = false;

Future<void> localPushEnsureInitialized() async {
  if (_initialized || kIsWeb) return;
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwinInit = DarwinInitializationSettings();
  const linuxInit = LinuxInitializationSettings(defaultActionName: 'Open');
  await _local.initialize(
    const InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
      macOS: darwinInit,
      linux: linuxInit,
    ),
  );
  if (defaultTargetPlatform == TargetPlatform.android) {
    final androidPlugin = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _androidChannelId,
        _androidChannelName,
        description: 'Announcements and updates for your classes',
        importance: Importance.high,
      ),
    );
  }
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    final iosPlugin = _local.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    await iosPlugin?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }
  _initialized = true;
}

Future<void> localPushShow({
  required int id,
  required String title,
  required String body,
}) async {
  if (!_initialized) await localPushEnsureInitialized();
  final androidDetails = defaultTargetPlatform == TargetPlatform.android
      ? const AndroidNotificationDetails(
          _androidChannelId,
          _androidChannelName,
          channelDescription: 'Announcements and updates for your classes',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        )
      : null;
  const darwinDetails = DarwinNotificationDetails();
  const linuxDetails = LinuxNotificationDetails();
  await _local.show(
    id,
    title,
    body,
    NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      linux: linuxDetails,
    ),
  );
}
