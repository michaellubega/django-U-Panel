# U-Panel — what you need to run the app

**Version 1.0.0** · Last updated for current U-Panel builds

This guide explains what phones, computers, browsers, and internet you need to use **U-Panel** at Kampala International University (KIU). It is written for **students, lecturers, QA staff, and administrators** — not for programmers.

| If you are… | Start here |
|-------------|------------|
| **Student or lecturer** | [What every user needs](#what-every-user-needs), then your device section ([phone](#android-phones-and-tablets), [computer](#windows-pc), or [browser](#web-in-a-browser)) |
| **QA or admin staff** | Same as above; a **tablet or laptop with a wide screen** makes attendance lists and reports easier |
| **IT or technical staff** | [For installers and developers](#for-installers-and-developers) — setup, builds, and Firebase |

For how the product works day to day, see [PROJECT_OVERVIEW.md](./PROJECT_OVERVIEW.md). For cloud setup steps, see [FIREBASE_SETUP.md](../FIREBASE_SETUP.md).

---

## In short

- U-Panel is a **university attendance and notices app**. It stores data in the cloud (Google Firebase), not only on your device.
- You need **internet** for sign-in, syncing attendance, notices, and most uploads. Some attendance actions can **wait on your device** and send later when you are back online.
- You need a **valid U-Panel account** from your institution.
- **Phones are best for students checking in** (location and notices). **Laptops or tablets with a wide screen** are best for staff managing class lists and sessions.

---

## What every user needs

| What | What it means for you |
|------|------------------------|
| **Internet** | Wi‑Fi or mobile data. Slow or unstable internet may delay sign-in or saving attendance. |
| **University account** | Email and password (or details) provided by KIU / your admin. |
| **Screen size** | On a **wide screen** (about tablet size or larger), menus appear on the side — easier for staff. On a narrow phone, menus are at the bottom — fine for students. |
| **Language** | The app interface is in **English** in current versions. |

### Optional but important for some tasks

| Feature on your device | Who needs it | Why |
|------------------------|--------------|-----|
| **Location (GPS)** | Students checking in to **on-campus** sessions | The app checks you are near the classroom. **Long-distance learning sessions** do **not** require location — your lecturer starts those without a radius check. |
| **Notifications** | Students and staff who want alerts for notices | Lets the app show class or university messages. **Not available on the Windows desktop app** (see below). |
| **Camera or photo gallery** | Staff using finance receipts or file uploads | To attach photos or files where the app asks for them. |
| **Some free storage on the device** | Everyone, especially with poor internet | A small amount of space saves attendance or uploads until connection returns (usually tens of megabytes, not gigabytes). |

---

## Which device should I use?

| Role | Best choice | Works but not ideal |
|------|-------------|---------------------|
| **Student** — sign in, session code, check-in | **Android phone** or **iPhone** | Web browser on a phone; Windows PC (no push alerts) |
| **Lecturer** — start session, view roll | **Android tablet/phone** or **laptop** (wide window) | Small phone only |
| **QA admin** — lists, reports, notices | **Laptop or desktop** (wide screen) | Phone only |

---

## Android (phones and tablets)

### Operating system

| | Guidance |
|---|----------|
| **Minimum** | **Android 7.0 (Nougat)** or newer |
| **Recommended** | **Android 10 or newer** — better notifications and location prompts |

### Device

| | Minimum | Recommended |
|---|---------|-------------|
| **Memory** | 2 GB RAM | 4 GB or more |
| **Storage** | About 200 MB free | About 500 MB if you upload many files |
| **Screen** | Normal smartphone | Larger phone or tablet for lecturer dashboards |
| **Location** | GPS or network location for **on-campus** check-in | GPS + good Wi‑Fi or mobile data |

### Allow on your phone when asked

- **Location** — for classroom attendance (not required for long-distance sessions).
- **Notifications** — on **Android 13 and newer**, allow notifications so you see university and class notices.

### Good to know

- If internet drops during check-in, the app may **save your attempt on the phone** and complete it when you are online again.
- The app uses Google’s messaging service for notices; most standard Android phones support this.

### CPU architectures (Android install package)

Release builds include native code for:

| Architecture | Typical devices |
|--------------|-----------------|
| **arm64-v8a** | Most phones and tablets sold today |
| **armeabi-v7a** | Older 32-bit ARM Android devices |
| **x86_64** | Android emulators and some Intel tablets |
| **x86** | Older 32-bit Android emulators |

Google Play delivers the correct slice automatically when you install from the store. Sideloaded APKs work on the matching CPU type.

---

## Windows PC

U-Panel can be installed as a **Windows desktop app** (not only in a browser).

### Operating system

| | Guidance |
|---|----------|
| **Minimum** | **Windows 10**, **64-bit (x64)**, updated (version 1809 or later) |
| **Recommended** | **Windows 10 (latest)** or **Windows 11**, **64-bit (x64)**, with Windows Update current |
| **CPU** | **Intel or AMD 64-bit (x64)** — standard university and office PCs |
| **Not supported** | **32-bit Windows (x86)** — Flutter does not provide a 32-bit Windows desktop engine |
| **Note** | **ARM-based Windows PCs** (some thin laptops) are not a supported build target for this project |

### Computer

| | Minimum | Recommended |
|---|---------|-------------|
| **Memory** | 4 GB RAM | 8 GB or more |
| **Disk space** | About 500 MB free | 1 GB or more |
| **Screen** | 1280 × 720 | 1920 × 1080; **wide window** for staff menus on the side |

### Before first use (usually done by IT)

- The app must be **installed and linked to your university’s cloud project** by technical staff. If that step was skipped, sign-in and sync will not work.
- **Internet** is required for login and data.
- **Windows location** (Settings → Privacy → Location) may be needed if you use attendance on a PC; **phones are still better for student check-in**.

### CPU architecture (Windows desktop app)

| Architecture | Supported? | Notes |
|--------------|------------|-------|
| **x64** (64-bit Intel/AMD) | **Yes** | Default and only official Flutter Windows target |
| **x86** (32-bit Windows) | **No** | Not available from the Flutter SDK |
| **ARM64 Windows** | **No** | Not built by this project |

Installers and `flutter build windows` output are **64-bit (x64)** only.

### Limitations on Windows

- **No push notifications** on the desktop app — open U-Panel to read notices, or use a phone/tablet for alerts.
- If the window is very narrow, the app looks like the phone layout (menus at the bottom). **Make the window wider** for the side menu.

---

## Web (in a browser)

You can open U-Panel in **Chrome, Edge, Firefox, or Safari** without installing an app.

### Browsers that work well

Use a **recent, up-to-date** browser:

- Google Chrome  
- Microsoft Edge (Chromium)  
- Mozilla Firefox  
- Safari (on Mac, iPhone, or iPad)

**Avoid:** Internet Explorer, very old browsers, or browsers with JavaScript or cookies turned off.

### What you need

| Topic | Plain explanation |
|-------|-------------------|
| **Website address** | Must be **https://** (secure) in production — not a random HTTP link. |
| **Location** | The browser will ask permission to use your location for on-campus check-in. On iPhone/iPad Safari: tap **aA** → **Website Settings** → allow **Location**. |
| **Notifications** | Allow notifications in the browser if you want notice alerts. |
| **Internet** | Stable connection; uploading receipts or large files needs reasonable speed. |
| **Screen** | Wide browser window recommended for staff (same as tablet width or larger). |

### Web limitations

- Some notice targeting used on phones may behave differently on web until your IT team configures web push fully.
- Printing or downloading reports depends on your browser (use Print or Download in the app as offered).

---

## iPhone and iPad

### Operating system

| | Guidance |
|---|----------|
| **Minimum** | **iOS 13** or newer |
| **Recommended** | **iOS 15 or newer** — clearer permission screens for location and notifications |
| **Devices** | iPhone and iPad |

### Device

| | Minimum | Recommended |
|---|---------|-------------|
| **Storage** | About 200 MB free | About 500 MB for heavy file use |
| **Location** | Required for **on-campus** check-in | Wi‑Fi + GPS for faster location |

### Allow when asked

- **Location while using the app** — for classroom attendance.  
- **Notifications** — for class and university notices.  
- Your institution’s IT must have connected the app to **Apple’s push service** (handled in Firebase — not something end users configure).

### Good to know

- If you open U-Panel in **Safari as a website** instead of the native app, location and notification rules follow **Safari’s per-website settings**.

---

## Internet and Wi‑Fi

| Situation | What to do |
|-----------|------------|
| **University Wi‑Fi with login page** | Complete the captive portal (browser login) **before** opening U-Panel. |
| **Guest or restricted Wi‑Fi** | Some networks block messaging or cloud sync; try mobile data or another network. |
| **Weak signal** | Attendance may queue on your device and sync later; wait for a stronger connection. |
| **Security** | The app talks to Google’s secure servers over encrypted connections (HTTPS). Your data access follows university rules set in the cloud admin console. |

Technical staff may need to allow traffic to Google and Firebase domains through firewalls — see [For installers and developers](#for-installers-and-developers).

---

## Quick comparison

| Platform | Oldest supported version | CPU / arch | Notice alerts | On-campus location check-in | Best for staff wide screen |
|----------|--------------------------|------------|---------------|-----------------------------|----------------------------|
| **Windows PC** | Windows 10 (64-bit) | **x64** Intel/AMD only | **No** | Limited; phone preferred | Yes, if window is wide |
| **Android** | Android 7.0 | ARM + **x86 / x86_64** | **Yes** | **Yes** | Yes on tablet |
| **Web browser** | Recent Chrome, Edge, Firefox, Safari | **Yes** (with permission + HTTPS) | **Yes** (browser location) | Yes, wide window |
| **iPhone / iPad** | iOS 13 | **Yes** | **Yes** | Yes on iPad |

---

## Attendance modes (for everyone)

| Session type | Location required? | Session code notice to students? |
|--------------|-------------------|----------------------------------|
| **Normal (on-campus)** | **Yes** — you must be within the radius set by the lecturer | **Yes** — students may get a push with the code (if notifications are on) |
| **Long-distance learning** | **No** — check in from anywhere during the session time | **No** — lecturer shares the join code manually (e.g. in class chat or LMS) |

---

## Troubleshooting (non-technical)

| Problem | Things to try |
|---------|----------------|
| **Cannot sign in** | Check internet; confirm email/password; ask admin if your account is active. |
| **“Too far from class”** | Turn on location; move closer; ask if the session is long-distance (no radius). |
| **No notices** | On **Windows desktop**, notices only appear inside the app. On phone, allow notifications in system settings. |
| **Session code not working** | Code may have expired; get a new code from the lecturer. Enter the **3-digit session code**, not your personal student code. |
| **Works offline then errors online** | Wait a few seconds on good Wi‑Fi; pull to refresh or restart the app. |
| **App says not configured** | Contact IT — the install may be missing cloud setup. |

---

## For installers and developers

End users do **not** need the items below. This section is for staff who deploy or maintain U-Panel.

| Item | Detail |
|------|--------|
| **Cloud** | Firebase project: Authentication, Cloud Firestore, Cloud Storage, Cloud Messaging |
| **App version** | **1.0.0+1** (see `pubspec.yaml`) |
| **Build tools** | Flutter **3.35.x**, Dart **3.x**; Android SDK API 24+; Xcode for iOS 13+; **Visual Studio 2022** with **Desktop development with C++** and **x64** toolchains for Windows |
| **Android package** | `com.u_panel` (Play Store / Firebase) |
| **Setup** | [README.md](../README.md), [FIREBASE_SETUP.md](../FIREBASE_SETUP.md) |
| **Firestore rules** | Deploy after rule changes: `firebase deploy --only firestore:rules` |

### Build outputs by CPU architecture

| Command | Architectures included |
|---------|------------------------|
| `flutter build apk --release` | `armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64` (configured in `android/app/build.gradle.kts`) |
| `flutter build appbundle --release` | Same ABIs; Play Store serves the right one per device |
| `flutter build windows --release` | **x64** Windows only (Intel/AMD 64-bit) |

```bash
flutter pub get
flutter run
flutter build apk --release           # Android (ARM + x86 ABIs)
flutter build appbundle --release     # Google Play
flutter build ios                     # iOS (on macOS)
flutter build web                     # Web
flutter build windows --release       # Windows x64 desktop
```

---

*When the university changes minimum phone versions, Windows support, or cloud setup, IT should update this document and the app version number at the top.*
