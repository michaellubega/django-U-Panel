bool get oneSignalImplSupported => false;

void oneSignalImplInitializeSdk() {}

Future<void> oneSignalImplAttachHandlers({
  void Function(Map<String, dynamic>)? onOpened,
  void Function(Map<String, dynamic>)? onForeground,
  void Function()? onSubscriptionChanged,
}) async {}

void oneSignalImplSetupIntegrationVerification(
  void Function(void Function() onRequestPermission) showDialog,
) {}

Future<String?> oneSignalImplGetPlayerId() async => null;

Future<void> oneSignalImplLogin(String externalUserId) async {}

Future<void> oneSignalImplSetTags(Map<String, String> tags) async {}

Future<void> oneSignalImplLogout() async {}

Future<bool> oneSignalImplRequestPermission() async => false;
