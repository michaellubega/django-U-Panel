import 'fcm_web_script_loader_stub.dart'
    if (dart.library.js_interop) 'fcm_web_script_loader_web.dart' as impl;

Future<void> ensureFcmWebScriptLoaded() => impl.ensureFcmWebScriptLoaded();
