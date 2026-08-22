import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../push/local_push_display_io.dart' as io;

/// Schedules and cancels device-local notifications (Android / iOS).
class LocalNotificationScheduler {
  LocalNotificationScheduler._();

  static bool _timeZonesReady = false;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> ensureReady() async {
    if (!supported) return;
    await io.localPushEnsureInitialized();
    if (_timeZonesReady) return;
    tz_data.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }
    _timeZonesReady = true;
  }

  static Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime when,
  }) async {
    if (!supported) return;
    await ensureReady();
    if (!when.isAfter(DateTime.now())) return;

    final androidDetails = defaultTargetPlatform == TargetPlatform.android
        ? const AndroidNotificationDetails(
            'upanel_notices',
            'U-Panel',
            channelDescription: 'Announcements and updates for your classes',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          )
        : null;
    const darwinDetails = DarwinNotificationDetails();
    final scheduled = tz.TZDateTime.from(when, tz.local);

    await io.localNotificationsPlugin.zonedSchedule(
      id,
      title,
      body,
      scheduled,
      NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  static Future<void> cancel(int id) async {
    if (!supported) return;
    await ensureReady();
    await io.localNotificationsPlugin.cancel(id);
  }

  static Future<void> cancelMany(Iterable<int> ids) async {
    for (final id in ids) {
      await cancel(id);
    }
  }
}
