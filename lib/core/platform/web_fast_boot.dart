import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'web_fast_boot_stub.dart'
    if (dart.library.js_interop) 'web_fast_boot_web.dart' as impl;

/// Web browser optimizations — skip mobile-only work and defer heavy sync so
/// first paint and login feel instant without the native app installed.
abstract final class WebFastBoot {
  static bool get enabled => kIsWeb;

  /// Sync hint from [index.html] localStorage probe (null if unknown).
  static bool? get cachedSessionHint => impl.cachedSessionHintImpl();

  /// Hides the HTML splash once Flutter content is ready to show.
  static void hideHtmlSplash() {
    if (!enabled) return;
    impl.hideHtmlSplashImpl();
  }

  /// Runs [callback] after the first Flutter frame (login / shell visible).
  static void afterFirstFrame(void Function() callback) {
    if (!enabled) {
      callback();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => callback());
  }
}
