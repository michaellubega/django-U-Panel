import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

/// Firestore **database ID** (not project ID).
///
/// This project uses the named database **`upanel`** in GCP/Firestore by default.
/// Override at compile time if needed, e.g. `flutter run --dart-define=FIRESTORE_DATABASE_ID=(default)`
/// to use the default database instead.
const String _kFirestoreDatabaseIdFromEnv = String.fromEnvironment(
  'FIRESTORE_DATABASE_ID',
  defaultValue: 'upanel',
);

/// Resolved database id for Firestore reads/writes.
String get uPanelFirestoreDatabaseId {
  final v = _kFirestoreDatabaseIdFromEnv.trim();
  if (v.isEmpty) {
    return 'upanel';
  }
  return v;
}

/// Firestore instance for U-Panel (attendance, etc.).
FirebaseFirestore uPanelFirestore() {
  final id = uPanelFirestoreDatabaseId;
  if (id == '(default)') {
    return FirebaseFirestore.instance;
  }
  return FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: id,
  );
}
