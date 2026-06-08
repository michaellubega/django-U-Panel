import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';
import 'local_push_display.dart';
import 'push_message_copy.dart';
import '../../features/attendance/data/session_code_push_utils.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  if (kDebugMode) {
    debugPrint('FCM background message: ${message.messageId}');
  }
  try {
    await localPushEnsureInitialized();
    final kind = (message.data['kind'] as String? ?? '').toLowerCase();
    if (kind == 'sessioncode') {
      final code = SessionCodePushUtils.codeFromPushData(message.data);
      if (code != null &&
          await SessionCodePushUtils.isRemoteLearningSessionCode(code)) {
        return;
      }
    }
    final (title, body) = pushDisplayCopyForMessage(message);
    await localPushShow(
      id: message.hashCode,
      title: title,
      body: body,
    );
  } catch (e) {
    if (kDebugMode) debugPrint('FCM background display failed: $e');
  }
}
