# Fix login: Cloudflare + DNS for https://kiu.orion13.us/app/

The HTTPS web app **cannot** call `http://169.58.135.136` directly (browsers block mixed content). You need an **HTTPS API** endpoint.

Choose **one** option below.

---

## Option A — Recommended: Cloudflare Worker (one domain)

Use `https://kiu.orion13.us/api/` proxied to your VPS. No separate `api` subdomain required.

### 1. Add orion13.us to Cloudflare

1. Sign up at [cloudflare.com](https://cloudflare.com) (free).
2. **Add site** → enter `orion13.us`.
3. Cloudflare shows two nameservers (e.g. `ada.ns.cloudflare.com`).

### 2. Point Spaceship nameservers to Cloudflare

In **Spaceship** → Domain `orion13.us` → Nameservers → use Cloudflare’s two NS values.

Wait 5–30 minutes for DNS to propagate.

### 3. Cloudflare DNS records

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| CNAME | `kiu` | `michaellubega.github.io` | **Proxied** (orange cloud) |
| CNAME | `www` | `michaellubega.github.io` | Proxied (optional) |

### 4. Deploy the API Worker

1. Cloudflare → **Workers & Pages** → **Create** → **Worker**.
2. Paste the code from [`cloudflare/worker-api-proxy.js`](../cloudflare/worker-api-proxy.js).
3. **Deploy**.
4. **Triggers** → **Add route**:
   - `kiu.orion13.us/api/*`
   - `kiu.orion13.us/admin/*`

### 5. SSL mode

Cloudflare → **SSL/TLS** → **Overview** → **Flexible**

(Cloudflare serves HTTPS; your VPS stays on HTTP port 80.)

### 6. Server environment (SSH)

```bash
ssh -p 443 root@169.58.135.136
cd /opt/upanel
```

Ensure `.env.production` includes:

```env
DJANGO_ALLOWED_HOSTS=kiu.orion13.us,api.orion13.us,169.58.135.136,localhost,127.0.0.1
PUBLIC_API_URL=https://kiu.orion13.us
CORS_ALLOWED_ORIGINS=https://kiu.orion13.us,https://api.orion13.us,http://169.58.135.136
CSRF_TRUSTED_ORIGINS=https://kiu.orion13.us,https://api.orion13.us
APP_RETURN_URL=https://kiu.orion13.us/app/
```

Restart:

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production restart web worker beat
```

### 7. Verify

```bash
curl -s https://kiu.orion13.us/api/health/
```

Expected: `{"status": "ok", "service": "upanel-api"}`

Open https://kiu.orion13.us/app/ and sign in.

---

## Option B — Separate API subdomain (`api.orion13.us`)

### Cloudflare DNS

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| CNAME | `kiu` | `michaellubega.github.io` | Proxied |
| A | `api` | `169.58.135.136` | **Proxied** |

SSL: **Flexible**

Server `.env.production`:

```env
PUBLIC_API_URL=https://api.orion13.us
CORS_ALLOWED_ORIGINS=https://kiu.orion13.us,https://api.orion13.us
```

Verify:

```bash
curl -s https://api.orion13.us/api/health/
```

---

## Temporary workaround (no DNS changes)

Use the app on the VPS over HTTP:

**http://169.58.135.136/app/**

Login works there today. Switch to https://kiu.orion13.us/app/ after Option A or B is complete.

---

## GitHub Pages settings

https://github.com/michaellubega/django-U-Panel/settings/pages

- Branch: `gh-pages` / `(root)`
- Custom domain: `kiu.orion13.us`
- Enforce HTTPS: On
