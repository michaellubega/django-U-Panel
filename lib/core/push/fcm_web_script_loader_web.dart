import 'dart:js_interop';

@JS('upanelEnsureFirebaseMessagingScript')
external JSPromise _ensureMessagingScript();

Future<void> ensureFcmWebScriptLoaded() async {
  await _ensureMessagingScript().toDart;
}
