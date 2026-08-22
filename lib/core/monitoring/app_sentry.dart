import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../api/api_config.dart';

typedef AppRunner = Future<void> Function();

/// Wraps [runApp] with Sentry when [SENTRY_DSN] is set at compile time.
Future<void> runAppWithSentry(AppRunner runner) async {
  if (!isSentryConfigured) {
    await runner();
    return;
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = uPanelSentryDsn;
      options.environment = kReleaseMode ? 'production' : 'development';
      options.tracesSampleRate = kReleaseMode ? 0.1 : 0.0;
      options.sendDefaultPii = false;
    },
    appRunner: () async {
      await runner();
    },
  );
}

void setSentryUser({String? id, String? email, String? role}) {
  if (!isSentryConfigured) return;
  Sentry.configureScope((scope) {
    scope.setUser(
      SentryUser(id: id, email: email, data: role == null ? null : {'role': role}),
    );
  });
}

void clearSentryUser() {
  if (!isSentryConfigured) return;
  Sentry.configureScope((scope) => scope.setUser(null));
}
