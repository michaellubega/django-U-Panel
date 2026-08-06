# Deploying U-Panel with Kamal

Production stack:

| Component | Role |
|-----------|------|
| **Kamal** | Build, push, and run Docker containers on your VPS |
| **nginx** (accessory) | Gateway on ports 80/443 → Gunicorn |
| **Redis** (accessory) | Django cache + Celery broker/result backend |
| **PostgreSQL** (accessory) | Primary database |
| **web** | Django API (Gunicorn) |
| **worker** | Celery worker |
| **beat** | Celery beat scheduler |

## Prerequisites

- A Linux VPS (Ubuntu 22.04+ recommended) with SSH root access
- Docker Hub account **`ovirion`** (registry login uses a [personal access token](https://hub.docker.com/settings/security))
- Ruby 3.3+ and Kamal on your **deploy machine** (laptop/CI — not the server)

### Install Kamal (Windows)

Ruby was installed via winget. In a **new** PowerShell window:

```powershell
gem install kamal
kamal version
```

If `gem install` fails, run `ridk install 3` once, then retry.

## One-time setup

### 1. Edit `config/deploy.yml`

Replace placeholders:

- `YOUR_SERVER_IP` — VPS public IP (3 places: web/worker/beat hosts + accessories)
- `api.orion13.us` — API hostname (nginx + `DJANGO_ALLOWED_HOSTS`); add an **A record** → your VPS IP
- `https://kiu.orion13.us` — Flutter/web client origin for CORS (existing GitHub Pages site)

### 2. Configure secrets

```powershell
copy .kamal\secrets.example .kamal\secrets
```

Export variables before every deploy (PowerShell):

```powershell
$env:KAMAL_REGISTRY_PASSWORD = "your-docker-hub-token"
$env:DJANGO_SECRET_KEY = "long-random-secret"
$env:POSTGRES_PASSWORD = "strong-db-password"
$env:DATABASE_URL = "postgres://upanel:$env:POSTGRES_PASSWORD@upanel-db:5432/upanel"
# Optional:
$env:MAILJET_API_KEY = "..."
$env:MAILJET_SECRET_KEY = "..."
$env:ONESIGNAL_APP_ID = "..."
$env:ONESIGNAL_REST_API_KEY = "..."
$env:SENTRY_DSN = "..."
```

`DATABASE_URL` uses Docker hostnames (`upanel-db`, `upanel-redis`) that Kamal creates for accessories.

### 3. Boot infrastructure accessories

```powershell
kamal accessory boot db
kamal accessory boot redis
kamal accessory boot nginx
```

Postgres and Redis bind to `127.0.0.1` on the server so they are not exposed publicly. nginx uses host networking and listens on `:80`.

### 4. First application deploy

```powershell
kamal setup
kamal deploy
```

`kamal setup` installs Docker on the server, builds the image from `backend/Dockerfile`, and starts web/worker/beat.

## Day-to-day commands

```powershell
kamal deploy              # Deploy latest git commit
kamal app logs            # Tail web logs
kamal app exec -i worker "celery -A upanel inspect ping"
kamal accessory logs redis
kamal accessory reboot nginx
kamal app exec -i web "python manage.py seed_qa_demo_user"
```

## Flutter client

Point the app at your public API:

```powershell
flutter run --dart-define=UPANEL_API_BASE_URL=https://api.orion13.us
```

## HTTPS

The default nginx config serves HTTP on port 80. To add TLS:

1. Obtain certificates (e.g. Certbot) on the server
2. Mount them into the nginx accessory (`directories` in `config/deploy.yml`)
3. Extend `config/nginx/upanel.conf` with an `:443` server block
4. `kamal accessory reboot nginx`

## Architecture

```
Internet → nginx (:80/:443) → Gunicorn web (:8000, localhost only)
                                    ↓
                              upanel-db (Postgres)
                              upanel-redis (cache + Celery queues)
                              worker / beat (Celery)
```

Kamal's built-in proxy is **disabled** (`proxy: false`); nginx is the sole gateway.
