# u_panel

**Landing page (downloads & web app):** https://kiu.orion13.us/ (also https://orion13.us/ if apex A records are set)

**University operations platform** — leadership, finance, attendance, learning, and communication in one place.

Download the **Android APK** and **Windows installer** from GitHub (landing page above). The **web app** and mobile/desktop clients talk to a **Django REST API** backend.

| Environment | Public URL | Server path | Notes |
|-------------|------------|-------------|--------|
| **Production** | https://kiu.orion13.us | `/opt/upanel` | Live stack (compose project `upanel`) |
| **Test** | https://test.orion13.us | `/opt/test` | Isolated stack (`upanel-test`), host port **8080**; IP fallback `http://169.58.135.136:8080` |

Contabo deploy: [docs/SERVER_SETUP.md](docs/SERVER_SETUP.md) · web publish: [docs/WEB_DEPLOYMENT.md](docs/WEB_DEPLOYMENT.md) · Cloudflare DNS: [docs/CLOUDFLARE_DNS_SETUP.md](docs/CLOUDFLARE_DNS_SETUP.md).

- **Desktop**: Fixed left sidebar, top bar (search, notifications, profile), card-based main area.
- **Mobile**: Bottom navigation (varies by role; includes Attendance, Notices, Profile), large cards, drawer for full menu.
- **Design**: Deep blue theme, Inter font, rounded cards, clear status indicators (Approved / Pending / Rejected).

## Features

| Area | Capabilities |
|------|--------------|
| **Dashboard** | Today’s attendance summary; QAAT-style **oversight** home for VC, DVC, DQA, Dean, HOD (read-only); pending finance approvals, recent notices, activity feed |
| **Attendance** | Create session, QR check-in, manual check-in, export reports (capture unchanged for lecturers / QA) |
| **Finance** | Upload receipt (image/PDF), amount & description, submit for approval, approve/reject workflow, status tracking |
| **Materials** | Upload PDF/slides/docs, organize by course, download & view, comments |
| **Notices** | Create notice, schedule, send push notification |
| **Assignments** | Create assignment, set deadline, collect submissions, grade & feedback |
| **Communication** | Group and course conversations |
| **Reports** | Attendance, finance, activity, materials usage — export |
| **Settings** | Profile, notifications, security, university, appearance; admins can provision leadership (oversight) accounts |

### Roles (attendance / oversight)

| Role | Access |
|------|--------|
| **Student** | Check-in, notices, settings |
| **Lecturer / KIU admin** | Session capture, rolls, notices |
| **QA staff / Administrator** | Full operational attendance tools + quality overview |
| **VC, DVC, DQA, Dean, HOD** | Read-only QAAT-style dashboards (lists/sessions/records GET only; no session write tools) |

## Run

### Flutter client

```bash
flutter pub get

# Local Django
flutter run --dart-define=UPANEL_API_BASE_URL=http://127.0.0.1:8000

# Production API (iPhone / Android — must include https://)
flutter run -d <device-id> --dart-define=API_URL=https://kiu.orion13.us

# Contabo test API
flutter run --dart-define=UPANEL_API_BASE_URL=https://test.orion13.us
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

**Attendance read API** (KIU-QAAT tokens / export): [docs/ATTENDANCE_API.md](docs/ATTENDANCE_API.md).

**Test stack deploy** (on Contabo): `bash scripts/contabo/deploy-test-on-server.sh` → https://test.orion13.us (see [SERVER_SETUP.md](docs/SERVER_SETUP.md)).

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
    oversight/     # QAAT-style read-only leadership dashboards
    attendance/
    notices/
    settings/
  main.dart
scripts/contabo/   # Production + test VPS deploy helpers
```

## Tech

- Flutter 3.x + Django 6.x (REST API)
- PostgreSQL, Redis, Celery
- OneSignal (push), Sentry (monitoring)
- Material 3
- Responsive layout: breakpoint 840px (desktop sidebar vs mobile bottom nav)
