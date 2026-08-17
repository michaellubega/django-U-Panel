# u_panel

**Landing page (downloads & web app):** https://kiu.orion13.us/ (also https://orion13.us/ if apex A records are set)

**University operations platform** — leadership, finance, attendance, learning, and communication in one place.

Download the **Android APK** and **Windows installer** from GitHub (landing page above). The **web app** and mobile/desktop clients talk to a **Django REST API** backend.

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

### Flutter client

```bash
flutter pub get

# Local Django
flutter run --dart-define=UPANEL_API_BASE_URL=http://127.0.0.1:8000

# Production API (iPhone / Android — must include https://)
flutter run -d <device-id> --dart-define=API_URL=https://kiu.orion13.us
```

`API_URL` and `UPANEL_API_BASE_URL` are equivalent. Always include `https://`. On iOS/Android the app defaults to `https://kiu.orion13.us` if you omit the define. `127.0.0.1` is the phone itself, so a physical iPhone cannot reach Django on your Mac that way.

### Django backend

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
docker compose up -d db redis   # Postgres + Redis
python manage.py migrate
python manage.py runserver
```

Or run everything in Docker: `docker compose up`

See [backend/README.md](backend/README.md) for Celery, OneSignal, and Sentry setup.

### Flutter with monitoring + push

```bash
flutter run --dart-define=UPANEL_API_BASE_URL=http://127.0.0.1:8000 --dart-define=SENTRY_DSN=... --dart-define=ONESIGNAL_APP_ID=...
```

Targets: **Windows**, **macOS**, **Web**, **Android**, **iOS** (configure as needed).

**System requirements** (Windows, Android, Web, iOS): [docs/SYSTEM_REQUIREMENTS.md](docs/SYSTEM_REQUIREMENTS.md).

## Project structure

```
backend/           # Django REST API
lib/
  core/
    api/           # HTTP client, auth, resource paths
    auth/          # Session, roles, registration
    theme/         # Deep blue theme, cards, typography
    navigation/    # App shell (sidebar + bottom nav)
  features/
    dashboard/
    attendance/
    notices/
    settings/
  main.dart
```

## Tech

- Flutter 3.x + Django 6.x (REST API)
- PostgreSQL, Redis, Celery
- OneSignal (push), Sentry (monitoring)
- Material 3
- Responsive layout: breakpoint 840px (desktop sidebar vs mobile bottom nav)
