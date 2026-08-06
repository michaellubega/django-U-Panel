# U-Panel Django backend

REST API for the Flutter client: **Django + PostgreSQL + Redis + Celery + OneSignal + Sentry**.

## Quick start (Docker — recommended)

```bash
copy backend\.env.example backend\.env
docker compose up -d db redis
docker compose run --rm web python manage.py migrate
docker compose up web worker beat
```

API: http://127.0.0.1:8000/api/health/

## Quick start (local Python)

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
# Start Postgres + Redis locally, set DATABASE_URL and REDIS_URL in .env
python manage.py migrate
python manage.py seed_qa_demo_user
python manage.py runserver
```

**QA demo login** (after `seed_qa_demo_user`):

| Field | Value |
|-------|--------|
| Email / staff ID | `KIU-0001` |
| Password | `admin@kiu` |

Celery (separate terminals):

```bash
celery -A upanel worker -l info
celery -A upanel beat -l info
```

## Environment variables

| Variable | Purpose |
|----------|---------|
| `DATABASE_URL` | PostgreSQL connection string |
| `REDIS_URL` | Django cache |
| `CELERY_BROKER_URL` | Celery message broker |
| `CELERY_RESULT_BACKEND` | Celery results |
| `SENTRY_DSN` | Backend error monitoring |
| `ONESIGNAL_APP_ID` | Push notifications |
| `ONESIGNAL_REST_API_KEY` | OneSignal REST API |

Without `DATABASE_URL`, SQLite (`db.sqlite3`) is used for bare dev.

## Production deploy (Kamal)

See [docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md) for VPS deployment with Kamal, nginx, Redis, and Celery.

## Flutter client

```bash
flutter pub get
flutter run ^
  --dart-define=UPANEL_API_BASE_URL=http://127.0.0.1:8000 ^
  --dart-define=SENTRY_DSN=https://...@sentry.io/... ^
  --dart-define=ONESIGNAL_APP_ID=your-app-id
```

## Stack mapping (Firebase → new)

| Firebase | Replacement |
|----------|-------------|
| Firebase Auth | Django REST token auth |
| Firestore | PostgreSQL + DRF |
| Realtime Database | Celery + Redis cache (WebSockets later) |
| Cloud Functions | Celery tasks in `notices/tasks.py`, `attendance/tasks.py` |
| FCM | OneSignal (`/api/push/register/`) |

## Apps

| App | Purpose |
|-----|---------|
| `accounts` | Users, roles, push device registration |
| `attendance` | Lists, sessions, records, check-in attempts |
| `notices` | Notices + Celery push on publish |
| `campus` | Geofence and campus presence |
