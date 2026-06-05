import 'package:flutter/foundation.dart';

import 'local_push_display_io.dart' as io;
import 'local_push_display_stub.dart' as stub;
import 'local_push_display_windows.dart' as win;

export 'local_push_display_io.dart'
    show localPushEnsureInitialized, localPushShow;

Future<void> localPushEnsureInitialized() async {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    await win.localPushEnsureInitialized();
  } else if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux)) {
    await io.localPushEnsureInitialized();
  } else {
    await stub.localPushEnsureInitialized();
  }
}

Future<void> localPushShow({
  required int id,
  required String title,
  required String body,
}) async {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    await win.localPushShow(id: id, title: title, body: body);
  } else if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux)) {
    await io.localPushShow(id: id, title: title, body: body);
  } else {
    await stub.localPushShow(id: id, title: title, body: body);
  }
}
