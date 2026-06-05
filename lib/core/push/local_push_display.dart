import 'local_push_display_stub.dart'
    if (dart.library.io) 'local_push_display_conditional.dart' as impl;

Future<void> localPushEnsureInitialized() => impl.localPushEnsureInitialized();

Future<void> localPushShow({
  required int id,
  required String title,
  required String body,
}) =>
    impl.localPushShow(id: id, title: title, body: body);
