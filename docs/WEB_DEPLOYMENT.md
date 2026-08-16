# Deploy U-Panel web app

| What | URL |
|------|-----|
| **Web app** | https://kiu.orion13.us/app/ |
| **Landing + downloads** | https://kiu.orion13.us/ |

## How production updates (two steps)

Merging to `main` only **builds** the Flutter web app. It does **not** update
https://kiu.orion13.us by itself.

| Step | What happens |
|------|----------------|
| 1. **GitHub Actions** | Workflow `Deploy web app to GitHub Pages` builds Flutter web and pushes to the `gh-pages` branch. |
| 2. **Contabo server** | Run `bash scripts/contabo/deploy-web-on-server.sh` on the VPS. It pulls `gh-pages` → `website/app`, rebuilds the nginx image, and restarts the stack. |

**Without step 2**, users keep seeing the old `main.dart.js` baked into nginx.

### Automatic server sync (recommended)

Add repo secret **`CONTABO_SSH_PRIVATE_KEY`** (root SSH private key). Optional:
`CONTABO_HOST` (default `169.58.135.136`), `CONTABO_SSH_PORT` (default `443`).

Workflow **`Sync web to Contabo server`** runs after each successful Pages deploy.

### Manual server deploy (SSH)

```bash
ssh -p 443 -i ~/.ssh/id_ed25519 root@169.58.135.136
cd /opt/upanel && bash scripts/contabo/deploy-web-on-server.sh
```

Verify the live bundle changed:

```bash
curl -sI https://kiu.orion13.us/app/main.dart.js | grep -i content-length
```

Hard-refresh the browser (Ctrl+Shift+R) after deploy.

## Windows (commit website/ — optional)

```powershell
cd C:\Users\dieve\OneDrive\Desktop\django\U-Panel

.\scripts\deploy-hosting.ps1 -ApiBaseUrl "http://169.58.135.136"

git add website
git commit -m "Publish web app"
git push origin main
```

Then complete **step 2** on the server (or enable automatic sync above).

## Manual build

```powershell
flutter build web --release `
  "--dart-define=UPANEL_API_BASE_URL=http://169.58.135.136" `
  "--base-href=/app/"

.\scripts\finalize-web-build.ps1
# Copy build\web\* to website\app\
.\scripts\prepare-download-site.ps1
git push origin main
```

## Backend CORS (Contabo)

In `/opt/upanel/.env.production`:

```env
CORS_ALLOWED_ORIGINS=https://kiu.orion13.us,http://169.58.135.136
```

Restart: `docker compose -f docker-compose.prod.yml --env-file .env.production up -d`
