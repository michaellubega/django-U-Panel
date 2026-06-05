/// Web Push **public** VAPID key from Firebase Console → Project settings →
/// Cloud Messaging → **Web Push certificates** → Key pair.
///
/// Pass at build / run:
/// `flutter run -d chrome --dart-define=FIREBASE_VAPID_KEY=BK...`
///
/// Without this, FCM cannot issue a web token and **topic subscriptions** will
/// not work (notices will not arrive on web).
const String kFcmWebVapidPublicKey = String.fromEnvironment(
  'FIREBASE_VAPID_KEY',
  defaultValue: '',
);
