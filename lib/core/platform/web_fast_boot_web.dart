import 'dart:js_interop';

@JS('upanelHideSplash')
external void _upanelHideSplash();

@JS('upanelMarkBootOk')
external void _upanelMarkBootOk();

@JS('upanelCachedSessionHint')
external bool? get _upanelCachedSessionHint;

void hideHtmlSplashImpl() {
  _upanelMarkBootOk();
  _upanelHideSplash();
}

bool? cachedSessionHintImpl() => _upanelCachedSessionHint;
