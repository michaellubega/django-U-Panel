import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/services.dart';

import 'u_panel_firestore.dart';

/// Firebase Realtime Database URL for check-in confirmation fan-out.
///
/// Override at compile time if needed:
/// `flutter run --dart-define=FIREBASE_DATABASE_URL=https://...`
const String uPanelRtdDatabaseUrl = String.fromEnvironment(
  'FIREBASE_DATABASE_URL',
  defaultValue:
      'https://u-panel-2026-default-rtdb.europe-west1.firebasedatabase.app',
);

/// Set after [MissingPluginException] (e.g. hot reload before full rebuild).
bool uPanelRtdPluginUnavailable = false;

/// Disables RTD for this process after a native plugin registration failure.
void markUPanelRtdUnavailable(Object error) {
  if (error is MissingPluginException) {
    uPanelRtdPluginUnavailable = true;
  }
}

/// RTD instance when Firebase is ready; null during web fast boot or when URL unset.
FirebaseDatabase? tryUPanelDatabase() {
  if (uPanelRtdPluginUnavailable || !isFirebaseInitialized) return null;
  final url = uPanelRtdDatabaseUrl.trim();
  if (url.isEmpty) return null;
  try {
    return FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: url,
    );
  } catch (e) {
    markUPanelRtdUnavailable(e);
    return null;
  }
}
