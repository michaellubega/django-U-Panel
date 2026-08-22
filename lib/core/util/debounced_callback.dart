import 'dart:async';

import 'package:flutter/foundation.dart';

/// Coalesces rapid callbacks into one invocation after [delay].
class DebouncedCallback {
  DebouncedCallback({
    required this.delay,
    required this.callback,
  });

  final Duration delay;
  final VoidCallback callback;
  Timer? _timer;

  void schedule() {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      callback();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}
