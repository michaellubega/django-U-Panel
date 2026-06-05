# u_panel

**Landing page (downloads & web app):** https://kiu.orion13.us/ (also https://orion13.us/ if apex A records are set)

**University operations platform** — leadership, finance, attendance, learning, and communication in one place.

Download the **Android APK** and **Windows installer** from GitHub (landing page above). The **web app** runs on Firebase.

- **Desktop**: Fixed left sidebar, top bar (search, notifications, profile), card-based main area.
- **Mobile**: Bottom navigation (varies by role; includes Attendance, Notices, Profile), large cards, drawer for full menu.
- **Design**: Deep blue theme, Inter font, rounded cards, clear status indicators (Approved / Pending / Rejected).

## Features

| Area | Capabilities |
|------|--------------|
| **Dashboard** | Today’s attendance summary, pending finance approvals, recent notices, upcoming events, assignment updates, activity feed |
| **Attendance** | Create session, QR check-in, manual check-in, export reports |
| **Finance** | Upload receipt (image/PDF), amount & description, submit for approval, approve/reject workflow, status tracking |
| **Materials** | Upload PDF/slides/docs, organize by course, download & view, comments |
| **Notices** | Create notice, schedule, send push notification |
| **Assignments** | Create assignment, set deadline, collect submissions, grade & feedback |
| **Communication** | Group and course conversations |
| **Reports** | Attendance, finance, activity, materials usage — export |
| **Settings** | Profile, notifications, security, university, appearance |

## Run

```bash
flutter pub get
flutter run
```

Targets: **Windows**, **macOS**, **Web**, **Android**, **iOS** (configure as needed).

**System requirements** (Windows, Android, Web, iOS): [docs/SYSTEM_REQUIREMENTS.md](docs/SYSTEM_REQUIREMENTS.md).

## Project structure

```
lib/
  core/
    theme/         # Deep blue theme, cards, typography
    constants/     # Breakpoints, app name
    navigation/    # App shell (sidebar + bottom nav)
  features/
    dashboard/
    attendance/
    finance/
    materials/
    notices/
    communication/
    reports/
    settings/
  main.dart
```

## Tech

- Flutter 3.x
- Material 3
- `google_fonts` (Inter)
- Responsive layout: breakpoint 840px (desktop sidebar vs mobile bottom nav)
