# U-Panel download website

Static landing page for **Android APK**, **Windows**, and the **web app**.

## Live URLs

| Page | URL |
|------|-----|
| **Landing page** | https://kiu.orion13.us/ |
| **Web app** | https://kiu.orion13.us/app/ |
| **APK & Windows installer** | https://kiu.orion13.us/downloads/ |

Published on every push to `main` via GitHub Pages. Custom domain: **kiu.orion13.us** (`website/CNAME`).

## Deploy web app + landing

```powershell
.\scripts\deploy-hosting.ps1 -ApiBaseUrl "http://169.58.135.136"
git add website
git commit -m "Publish web app"
git push origin main
```

With APK (after `flutter build apk --release`):

```powershell
.\scripts\deploy-hosting.ps1 -IncludeApk
git add website
git commit -m "Publish web app and APK"
git push origin main
```

## DNS (Spaceship)

| Type | Host | Value |
|------|------|-------|
| **CNAME** | `kiu` | `michaellubega.github.io` |

GitHub Pages → Custom domain: **kiu.orion13.us** → Enforce HTTPS.

## Local preview

```powershell
cd website
python -m http.server 8080
```
