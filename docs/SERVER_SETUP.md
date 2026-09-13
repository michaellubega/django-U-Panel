# Contabo server setup (post-deploy checklist)

Server: **169.58.135.136** · SSH: **port 443** (move to 22 before HTTPS — see below)

| Stack | Public URL | Disk | Compose | Host HTTP |
|-------|------------|------|---------|-----------|
| **Production** | https://kiu.orion13.us | `/opt/upanel` | `docker-compose.prod.yml` + `.env.production` | **:80** (Cloudflare Flexible) |
| **Test** | https://test.orion13.us | `/opt/test` | `docker-compose.test.yml` + `.env.test` (project `upanel-test`) | Hostname via Docker network **`upanel-edge`** → `upanel-test-nginx:80`; host **TEST_HTTP_PORT** (default **:8080**, often **:8085**) for direct IP only |

```bash
ssh -p 443 -i ~/.ssh/id_ed25519 root@169.58.135.136
```

## Important: SSH on port 443 vs HTTPS

If you SSH with `ssh -p 443`, **sshd is using port 443** — the same port HTTPS needs.

Before running `setup-https.sh`, move SSH to port **22** (or **2222**):

```bash
nano /etc/ssh/sshd_config
```

Set:

```
Port 22
```

Then:

```bash
systemctl restart ssh
```

From your Mac (use hotspot if port 22 is blocked on Wi‑Fi):

```bash
ssh -i ~/.ssh/id_ed25519 root@169.58.135.136
```

Once SSH is off 443, run `setup-https.sh` to enable `https://api.orion13.us`.

---

## Step 0 — First-time server (not a git clone)

If `git pull` says **not a git repository**, `/opt/upanel` was copied manually. Bootstrap once:

```bash
curl -fsSL https://raw.githubusercontent.com/michaellubega/django-U-Panel/main/scripts/contabo/bootstrap-server.sh | bash
```

This backs up your `.env.production`, clones the repo, and deploys the web app at `/app/`.

---

## Step 1 — Confirm stack is running

```bash
cd /opt/upanel
docker compose -f docker-compose.prod.yml --env-file .env.production up -d
docker ps
curl http://127.0.0.1/api/health/
```

Expected: `{"status": "ok", "service": "upanel-api"}`

---

## Test environment (`/opt/test` → https://test.orion13.us)

Isolated from production (`/opt/upanel`). Separate Docker project (`upanel-test`), volumes, and Postgres DB.

**Hostname path (Cloudflare → origin :80):** production nginx and test nginx both join external Docker network **`upanel-edge`**. Prod nginx `proxy_pass http://upanel-test-nginx:80;` (Docker DNS alias) — **not** `host.docker.internal` or a host port. That avoids 502s when the host bind is `127.0.0.1`-only or the wrong port is left in conf.

**Direct IP path:** host port **TEST_HTTP_PORT** (default **8080**; prefer **8085** when `:8080` is occupied). Prefer the hostname for browsers and Flutter.

`scripts/contabo/deploy-test-on-server.sh` resolves the port as: shell `TEST_HTTP_PORT` if set → else existing `.env.test` value → else `8080`. It does **not** overwrite an existing `.env.test` `TEST_HTTP_PORT` when the shell env is unset. It creates `upanel-edge` if missing, brings up the test stack on that network, copies the Docker-DNS nginx conf into `/opt/upanel`, ensures prod compose joins `upanel-edge`, rebuilds prod nginx, and normalizes `.env.test` / Flutter web as before.

**DNS (once in Cloudflare):** A record `test` → `169.58.135.136`, Proxied, SSL mode Flexible (same as `kiu`). See [CLOUDFLARE_DNS_SETUP.md](CLOUDFLARE_DNS_SETUP.md).

```bash
# On Contabo as root — default BRANCH is set in the script (override with BRANCH=...)
bash /opt/test/scripts/contabo/deploy-test-on-server.sh

# When :8080 is taken (recommended on this VPS) — still needed for direct IP:
TEST_HTTP_PORT=8085 bash /opt/test/scripts/contabo/deploy-test-on-server.sh
# Or set TEST_HTTP_PORT=8085 in /opt/test/.env.test — later deploys preserve it.

# Or first time after cloning into /opt/test:
#   cd /opt/test && BRANCH=<feature-branch> TEST_HTTP_PORT=8085 bash scripts/contabo/deploy-test-on-server.sh
```

From your Mac:

```bash
ssh -p 443 -i ~/.ssh/id_ed25519 root@169.58.135.136 \
  'bash -s' < scripts/contabo/deploy-test-on-server.sh
```

Then open **https://test.orion13.us/app/** (API health: `/api/health/`). Direct IP fallback: `http://169.58.135.136:8085/app/` (or whatever `TEST_HTTP_PORT` you chose; default was `:8080`).

**Flutter must rebuild on Contabo.** The deploy script fails if `flutter` is missing or if `website/app/main.dart.js` does not contain `KIU-QAAT` (stale Aug-era bundles look like the old ops UI).

**Sanity checks on Contabo** (after deploy):

```bash
curl -sS http://127.0.0.1:8085/api/health/   # or your TEST_HTTP_PORT
curl -sS -H 'Host: test.orion13.us' http://127.0.0.1/api/health/
docker compose -f /opt/upanel/docker-compose.prod.yml --env-file /opt/upanel/.env.production \
  exec nginx wget -q -O - http://upanel-test-nginx/api/health/
# Confirm the QAAT web bundle is live (must print a hit):
curl -sS https://test.orion13.us/app/main.dart.js | grep -o 'KIU-QAAT' | head -1
curl -sS https://test.orion13.us/app/version.json
```

### Oversight (QAAT) demo users on test

Seed read-only VC/DVC/DQA/Dean/HOD accounts on the **test** stack:

```bash
cd /opt/test
docker compose -p upanel-test -f docker-compose.test.yml --env-file .env.test \
  exec -T web python manage.py seed_oversight_demo_users
```

Sign in at https://test.orion13.us/app/ with staff ID (e.g. `KIU-VC01`) and password `qaat@kiu`.

You should see a dark **KIU-QAAT · LEADERSHIP OVERSIGHT** banner and slate KPI tiles. Nav is **Dashboard · Reports · Notices · Settings** (no Attendance tab). Banner shows build `v1.0.0+N` — confirm it matches `version.json`.

**Admin / QA officer** also land on this same QAAT Dashboard home (build 14+). Ops capture tools stay on **Attendance**; use **Open attendance / ops tools** on the banner.

If the UI still looks like the old green ops home: hard-refresh / clear site data for `test.orion13.us`, confirm you are not on production (`kiu.orion13.us`), and confirm `grep KIU-QAAT` on `main.dart.js` as above. Live `version.json` must be **≥ 14** (older Contabo images were build 12 without QAAT chrome).

Admins can also provision accounts in-app: Settings → Staff & accounts → Leadership (`POST /api/auth/provision-oversight/`).

```bash
# Fast path when Flutter is already built into git website/app:
USE_COMMITTED_WEB=1 TEST_HTTP_PORT=8085 \
  BRANCH=michael/oversight-dashboards-qaat-81ad \
  bash scripts/contabo/deploy-test-on-server.sh
```

Point a local Flutter build at the test API:

```bash
flutter run --dart-define=UPANEL_API_BASE_URL=https://test.orion13.us
```

---

## Step 2 — Create Django admin user

```bash
cd /opt/upanel
docker compose -f docker-compose.prod.yml exec web python manage.py createsuperuser
```

Follow prompts (email, password). Then open:

**http://169.58.135.136/admin/**

Optional QA demo user:

```bash
docker compose -f docker-compose.prod.yml exec web python manage.py seed_qa_demo_user
```

---

## Step 3 — DNS for API domain

In your DNS provider (where `orion13.us` is managed), add:

| Type | Name | Value |
|------|------|-------|
| **A** | `api` | `169.58.135.136` |

Verify (from your Mac):

```bash
dig +short api.orion13.us
# should print: 169.58.135.136
```

---

## Step 4 — Enable HTTPS (Let's Encrypt)

**Only after DNS resolves** (Step 3):

```bash
cd /opt/upanel
bash scripts/contabo/setup-https.sh
```

Then update `.env.production`:

```bash
nano /opt/upanel/.env.production
```

Change:

```env
PUBLIC_API_URL=https://api.orion13.us
CORS_ALLOWED_ORIGINS=https://kiu.orion13.us,https://api.orion13.us
```

Restart:

```bash
cd /opt/upanel && docker compose -f docker-compose.prod.yml --env-file .env.production up -d
```

Verify:

```bash
curl https://api.orion13.us/api/health/
```

---

## Step 5 — Firewall

```bash
cd /opt/upanel
bash scripts/contabo/finish-server-setup.sh
```

Or manually:

```bash
ufw allow 443/tcp    # SSH (your custom port)
ufw allow 80/tcp     # HTTP (redirect + cert renewal)
ufw allow 443/tcp    # HTTPS API
ufw enable
```

---

## Step 6 — Point Flutter app at Contabo

```bash
# Production
flutter run -d <device-id> --dart-define=UPANEL_API_BASE_URL=https://kiu.orion13.us

# Test stack
flutter run --dart-define=UPANEL_API_BASE_URL=https://test.orion13.us
```

Until Cloudflare HTTPS is ready for a given host, use HTTP IP (prod `:80` / test `TEST_HTTP_PORT`, often `:8085`):

```bash
flutter run --dart-define=UPANEL_API_BASE_URL=http://169.58.135.136
flutter run --dart-define=UPANEL_API_BASE_URL=http://169.58.135.136:8085
```

---

## Step 7 — Verify Mailjet email

After updating Mailjet keys in `.env.production` and restarting:

1. Register a test user in the app
2. Check verification email arrives
3. If not, check logs:

```bash
docker logs upanel-web-1 2>&1 | tail -50
```

Mailjet sender domain `orion13.us` must be verified in the Mailjet dashboard.

---

## Useful commands

```bash
# Logs
docker logs upanel-web-1 -f
docker logs upanel-worker-1 -f

# Restart after .env changes
cd /opt/upanel && docker compose -f docker-compose.prod.yml --env-file .env.production up -d

# Shell into Django
docker compose -f docker-compose.prod.yml exec web python manage.py shell
```
