import 'dart:js_interop';

@JS('upanelApiBaseUrl')
external String? get _upanelApiBaseUrlJs;

/// Set in [web/index.html] before Flutter boots.
String? get webRuntimeApiBaseUrl {
  try {
    final v = _upanelApiBaseUrlJs;
    if (v == null) return null;
    final trimmed = v.trim();
    return trimmed.isEmpty ? null : trimmed;
  } catch (_) {
    return null;
  }
}
