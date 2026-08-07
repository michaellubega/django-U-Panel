# Deploy U-Panel web app (GitHub Pages — no Firebase)

| What | URL |
|------|-----|
| **Web app** | https://kiu.orion13.us/app/ |
| **Landing + downloads** | https://kiu.orion13.us/ |

## Windows

```powershell
cd C:\Users\dieve\OneDrive\Desktop\django\U-Panel

.\scripts\deploy-hosting.ps1 -ApiBaseUrl "http://169.58.135.136"

git add website
git commit -m "Publish web app"
git push origin main
```

GitHub Actions publishes `website/` to **kiu.orion13.us** automatically.

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
