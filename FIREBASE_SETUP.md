# Firebase setup for U-Panel

Attendance data (lists, students, sign-ins) is stored in **Cloud Firestore**. To run the app with Firebase:

## 1. Create a Firebase project

1. Go to [Firebase Console](https://console.firebase.google.com/) and create a project (or use an existing one).
2. **Create the Firestore database** (required — without this, writes fail):
   - Open **Build → Firestore Database**.
   - Click **Create database**.
   - Choose **Start in production mode** or **Start in test mode** (test mode is fine for local development).
   - Pick a **location** (region) and finish the wizard.

If you skip this step, Android logcat will show warnings like:

`NOT_FOUND ... The database (default) does not exist for project YOUR_PROJECT_ID ... visit .../datastore/setup?project=...`

That is **not** an app bug: open the link in the message (or Firestore in Firebase Console) and **create the default Firestore database** for that project.

**Note:** `google-services.json` / `firebase_options.dart` can point to a project that exists while Firestore was never enabled for it — always confirm **Firestore Database** shows data/collections, not only “Project settings”.

### GCP console vs Firebase console

The same project appears in [Google Cloud Firestore → Databases](https://console.cloud.google.com/firestore/databases) (pick project **u-panel-2026** in the top bar) and in **Firebase Console → Firestore Database**. Either place is fine as long as a database actually exists and the app matches the project.

### “Database exists” but the app still shows `NOT_FOUND` / not connecting

1. **Database ID must match the SDK**  
   In Cloud Console → **Firestore → Databases**, check **Database ID** for the database you use.

   - This app’s **default** Firestore database ID is **`upanel`** (see `lib/core/firebase/u_panel_firestore.dart`). It must match the ID shown in GCP.
   - To use Google’s **`(default)`** database instead, run or build with:

   ```bash
   flutter run --dart-define=FIRESTORE_DATABASE_ID=(default)
   ```

   - To use any other named database:

   ```bash
   flutter run --dart-define=FIRESTORE_DATABASE_ID=your-exact-database-id
   ```

2. **Create Firestore from Firebase as well (recommended)**  
   Open [Firebase Console](https://console.firebase.google.com/) → project **u-panel-2026** → **Build → Firestore Database** and confirm the database is **Native mode** and active. That keeps Android/iOS clients and rules aligned with what FlutterFire expects.

3. **Rebuild the app** after changing `google-services.json` or `firebase_options.dart`:

   ```bash
   flutter clean
   flutter pub get
   flutter run
   ```

4. **Debug: Firebase init**  
   If `Firebase.initializeApp` fails, the app prints the error in **debug mode** (see `lib/main.dart`). Fix `google-services.json` / `applicationId` / `firebase_options.dart` until init succeeds.

## 2. Register your app with Firebase

- **Android**: In Project settings, add an Android app. Use your app’s package name (`com.u_panel` from `android/app/build.gradle.kts`). Download `google-services.json` and place it in `android/app/`.
- **iOS**: Add an iOS app, download `GoogleService-Info.plist`, and add it to the `ios/Runner` folder in Xcode.
- **Web**: Add a web app and copy the `firebaseConfig` object if you need it later.

## 3. Configure Flutter (Android)

In `android/build.gradle`, add the Google services classpath:

```gradle
buildscript {
  dependencies {
    // ... existing
    classpath 'com.google.gms:google-services:4.4.2'
  }
}
```

In `android/app/build.gradle`, at the bottom:

```gradle
apply plugin: 'com.google.gms.google-services'
```

## 4. Optional: FlutterFire CLI

For multi-platform config you can run:

```bash
dart run flutterfire_cli:flutterfire configure
```

Then in `lib/main.dart` use:

```dart
await Firebase.initializeApp(
  options: DefaultFirebaseOptions.currentPlatform,
);
```

(and add `import 'firebase_options.dart';`)

## 5. Run the app

```bash
flutter pub get
flutter run
```

On first open of the Attendance tab, the app loads data from Firestore. If Firebase is not configured, you’ll see “Could not load attendance data” with a Retry button.

## Firestore structure

- **attendance_lists**: one document per attendance list (id, time, room, whoTaught, date, courses, year, sem, optional **lecturerUid** linking the list to a lecturer’s Firebase Auth uid).
- **attendance_sessions**: live session (listId, sessionCode, location, times, status).
- **attendance_records**: session check-ins (sessionId, studentId, course, timestamp, selfie path, verified).
- **students**: one document per student (id, name, registrationNumber, threeDigitCode, initials).
- **sign_ins**: one document per sign-in (id, listId, studentId, course, signedInAt).
- **admins**: QA staff / full admins (`isAdmin: true`, optional denormalized `email`, `registrationNumber`).
- **lecturers**: lecturer accounts (`isLecturer: true`, `staffNumber` like `KIU-0001`, `loginEmail` synthetic auth address).
- **staff_numbers**: one document per `KIU-####` id used to reserve manual lecturer ids (`uid` after assignment).
- **meta/lecturer_staff_counter**: single doc with field **`next`** (int) for auto-generated staff numbers.

### Lecturer sign-in (synthetic email)

Lecturers type **KIU-####** at login. The app maps that to a deterministic Firebase email/password account, e.g. `kiu0001@staff.upanel.local`, created by an admin via **Settings → Register staff**. New lecturers receive the default password configured in **`lib/core/auth/staff_auth_email.dart`** (`defaultLecturerPassword`) until they change it in Settings — **override for production**.

## Security rules (`PERMISSION_DENIED`)

If logcat shows:

`Listen for Query(... attendance_lists where createdBy==... ) failed: PERMISSION_DENIED`

or `Write failed at notices/...: PERMISSION_DENIED`

then **Firestore rules** are blocking reads/writes (not the `GoogleApiManager` / `com.google.android.gms` lines — those are common on emulators and unrelated).

### Student self-registration email

Students must register with a KIU mailbox in the form **`firstname.lastname@studmc.kiu.ac.ug`** (stored lowercase) and a registration number **`YYYY-MM-#####`** (e.g. `2025-08-41310`). Each registration number is stored in **`student_registrations/{reg}`** and may only be linked to **one** Firebase account (one email). Deploy **`firestore.rules`** after changing this collection. After signup, Firebase sends a **verification link** to that address; the app blocks the main UI until the link is opened and the user taps **I verified my email — continue**.

In Firebase Console → **Authentication** → **Templates**, customize **Email address verification** and **Password reset** if needed. Students reset passwords from the app login screen (**Forgot password?**) using their `@studmc.kiu.ac.ug` address; staff **KIU-####** accounts must use Settings after sign-in or ask an administrator. Ensure **Email/Password** sign-in is enabled. If verification mail does not arrive, check **Spam/Junk** as well as the inbox. If the message is in spam, mark it **Not spam** (or **Not junk**) so the link works and later mail is not filtered. Confirm the address is a live `@studmc.kiu.ac.ug` mailbox.

This app uses **Firebase Authentication** and role documents:

| Role | Firestore doc | Required fields |
|------|----------------|-----------------|
| QA / admin | `admins/{your Firebase Auth uid}` | `isAdmin: true` (bool) |
| Lecturer | `lecturers/{your Firebase Auth uid}` | `isLecturer: true` (bool), `staffNumber` (e.g. `KIU-0001`) |

Lecturers may only read lists where **`lecturerUid`** or **`createdBy`** equals their Auth uid, and may publish **notices** only for class lists they own (or session-code notices for sessions they started). Rules in **`firestore.rules`** must be deployed to the **`upanel`** database (see below).

1. In [Firebase Console](https://console.firebase.google.com/) → **Firestore Database** → select database **`upanel`** (if you use multiple DBs) → **Rules**.
2. Publish the rules from this repo’s root file **`firestore.rules`**.

Or from the project root (with [Firebase CLI](https://firebase.google.com/docs/cli) logged in):

```bash
firebase deploy --only firestore
```

**Important:** With a named Firestore database (`upanel` in `firebase.json`), use `firebase deploy --only firestore` so rules are released to `cloud.firestore/upanel`. The target `firestore:rules` alone may not publish rules for named databases on some CLI versions.

`firebase.json` targets database **`upanel`**; keep that in sync with `lib/core/firebase/u_panel_firestore.dart`.

### Harmless Android warnings

Lines like `DynamiteModule` / `ProviderInstaller` / `providerinstaller.dynamite` are common on some devices and are **not** why Firestore fails. Fix **rules** for `PERMISSION_DENIED`.

### Production

Keep rules aligned with Authentication: only grant **`lecturers`** and **`meta`** writes to admins; ensure lecturers cannot read other lecturers’ profile docs unless your product requires it.

## Firestore data model (vs. generic “classes / sessions / attendance”)

U-Panel uses **stable collection names** in production data. They line up with the usual school model like this:

| Typical name | U-Panel collection | Notes |
|--------------|---------------------|--------|
| `users` | `app_users` (+ Firebase Auth) | Profile keyed by Auth uid; see `AuthRepository`. |
| Staff roles | `admins`, `lecturers` | QA staff use `admins`; lecturers use `lecturers` + optional `staff_numbers` / `meta` counter. |
| `classes` | `attendance_lists` | Class lists (lecturer, room, courses, timetable metadata, optional `lecturerUid`). |
| `sessions` | `attendance_sessions` | Join code, GPS centre, time window; `listId` links to a list. |
| `attendance` | `attendance_records` | One doc per student per session; **id = `{sessionId}_{studentId}`** (dedupe / upsert by id). |
| Enrolment / course | `sign_ins` | Student chose a course on a given list. |
| People | `students` | Shared student directory (registration #, etc.). |
| Broadcasts | `notices` | Optional `kind`, `sessionCode`, class targeting. |

**Offline “attempts”:** The Flutter app queues raw check-ins locally (`SharedPreferences`), then validates and writes **`attendance_records`** when online. There is **no** top-level `attempts` collection yet; that matches “don’t break existing code” while keeping the same **validate → final row** idea. A future Firestore `attempts` (audit / replay) can be added without changing attendance doc ids.

Canonical string constants live in **`lib/core/firebase/firestore_collections.dart`** (use them in new code instead of hard-coded collection names).

### Composite indexes

`firestore.indexes.json` includes indexes required by deployed queries (e.g. scheduled cleanup on **`notices`**). After editing indexes, deploy:

```bash
firebase deploy --only firestore:indexes
```

## Web push (FCM notices)

Web needs three pieces (already wired in the repo except the VAPID key):

1. **`web/firebase-messaging-sw.js`** — Firebase Messaging service worker (background notifications).
2. **`web/index.html`** — loads `firebase-messaging-compat.js` and registers that service worker.
3. **VAPID public key** — Firebase Console → **Project settings** → **Cloud Messaging** → **Web Push certificates** → create or copy the **public** key.

Pass the key when you run or build web:

```bash
flutter run -d chrome --dart-define=FIREBASE_VAPID_KEY=YOUR_PUBLIC_VAPID_KEY_HERE
```

```bash
flutter build web --dart-define=FIREBASE_VAPID_KEY=YOUR_PUBLIC_VAPID_KEY_HERE
```

Without `FIREBASE_VAPID_KEY`, the app cannot obtain an FCM web token, so **topic subscriptions** (class notices) will not work on web. Foreground messages still use the browser **Notification** API after the user allows notifications.

Use **HTTPS** (or `localhost`) so the browser allows notifications and the service worker.

## Android push (FCM)

Notices are sent by Cloud Functions to FCM **topics** (`all_notices`, `list_<classListId>`, `stu_<studentId>`). The app subscribes after sign-in when role checks finish and attendance data is loaded.

**Students** must be signed in with a registration number that matches a row in **`students`**, and must have **signed in to a class list** at least once — otherwise the app cannot subscribe to `list_*` topics and class/session pushes will not arrive.

**Check on device (debug build):** logcat lines like `FCM subscribed: list_…` or `FCM token acquired`. If you see `FCM subscribe …` errors or `GoogleApiManager … DEVELOPER_ERROR`, use a **physical device** or an emulator image **with Google Play**, and ensure the app has **notification permission** (Android 13+).

**Background:** when the app is not in the foreground, FCM still delivers via the system tray (and a local notification fallback in the background isolate).

## Desktop push (Windows / Linux / macOS)

Firebase **does not** provide FCM on Windows desktop. U-Panel uses:

- **Windows** — Windows Action Center toasts via `windows_notification` while the app is running.
- **Linux / macOS** — `flutter_local_notifications` while the app is running.
- **Polling** — every ~45s the app reads new rows in **`notices`** (same rules as the Notices screen) and shows a toast for anything new since last run.

Desktop toasts require the **app to be open** (or minimized), not fully quit. For alerts when the app is closed, use the **Android** or **web** build with FCM.

On first desktop launch after sign-in, existing notices are **not** all toasted (watermark is set to the newest notice only).
