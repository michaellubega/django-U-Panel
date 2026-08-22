# Contabo server setup (post-deploy checklist)

Server: **169.58.135.136** · SSH: **port 443** (move to 22 before HTTPS — see below)

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

## Step 6 — Point Flutter app to production API

```bash
flutter run -d <device-id> --dart-define=API_URL=https://api.kiu.orion13.us
```

Until HTTPS is ready, use:

```bash
flutter run --dart-define=UPANEL_API_BASE_URL=http://169.58.135.136
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
