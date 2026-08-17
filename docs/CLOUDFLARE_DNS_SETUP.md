# Fix login on https://kiu.orion13.us/app/

HTTPS pages cannot call `http://169.58.135.136` (browser blocks it). You need **Cloudflare** in front of your VPS so `https://kiu.orion13.us/api/` works.

---

## Fastest fix (recommended): point `kiu` at the VPS

One DNS record for the site (`kiu`) plus an optional API host (`api.kiu`) for native clients.

### 1. Cloudflare

1. Sign up at [cloudflare.com](https://cloudflare.com) (free).
2. **Add site** → `orion13.us`.
3. Copy Cloudflare’s two nameservers.

### 2. Spaceship

Domain `orion13.us` → **Nameservers** → paste Cloudflare NS → save.

Wait 10–30 minutes.

### 3. Cloudflare DNS

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| **A** | `kiu` | `169.58.135.136` | **Proxied** (orange cloud) |
| **A** | `api.kiu` | `169.58.135.136` | **Proxied** (orange cloud) |

Remove any `kiu` CNAME to `michaellubega.github.io` (VPS serves the app instead of GitHub Pages).

**SSL/TLS** → **Flexible**

### 4. Server (SSH)

```bash
ssh -p 443 root@169.58.135.136
cd /opt/upanel
git pull origin main
bash scripts/contabo/fix-production-env.sh
bash scripts/contabo/deploy-web-on-server.sh
```

`fix-production-env.sh` fixes `PUBLIC_API_URL=PUBLIC_API_URL=...` typos and sets CORS/CSRF.

### 5. Verify

```bash
curl -s https://kiu.orion13.us/api/health/
curl -s https://api.kiu.orion13.us/api/health/
```

Expected: `{"status": "ok", "service": "upanel-api"}`

Open **https://kiu.orion13.us/app/** and sign in.

Native clients:

```bash
flutter run -d <device-id> --dart-define=API_URL=https://api.kiu.orion13.us
```

---

## Alternative: GitHub Pages + API subdomain

Keep `kiu` on GitHub Pages (CNAME `michaellubega.github.io`) and add:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `api` | `169.58.135.136` | Proxied |

Set `PUBLIC_API_URL=https://api.orion13.us` in `.env.production`.

Or deploy `cloudflare/worker-api-proxy.js` on routes `kiu.orion13.us/api/*` and `kiu.orion13.us/admin/*`.

---

## Temporary (no DNS)

**http://169.58.135.136/app/** — login works today over HTTP.

---

## GitHub Pages (landing only)

If `kiu` points at the VPS, use **www.orion13.us** or GitHub default URL for the marketing site, or serve landing from the VPS.

Settings: https://github.com/michaellubega/django-U-Panel/settings/pages
