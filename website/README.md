# U-Panel download website

Static landing page for **Google Play (Android)**, **Windows installer**, and the **web app**.

## Live URLs

| Page | URL |
|------|-----|
| **Landing page** | https://kiu.orion13.us/ |
| **Web app** | https://kiu.orion13.us/app/ |
| **Google Play (Android)** | https://play.google.com/store/apps/details?id=com.u_panel |
| **Windows installer** | https://kiu.orion13.us/downloads/U-Panel-1.0.0-windows-setup.exe |

Published on every push to `main` via GitHub Pages. Custom domain: **kiu.orion13.us** (`website/CNAME`).

## Deploy web app + landing

```powershell
.\scripts\deploy-hosting.ps1 -ApiBaseUrl "http://169.58.135.136"
git add website
git commit -m "Publish web app"
git push origin main
```

With Windows installer (after building with Inno Setup / `UPanelSetup.exe`):

```powershell
.\scripts\prepare-download-site.ps1 -WindowsInstaller website\downloads\UPanelSetup.exe
git add website
git commit -m "Update download site: Play Store + Windows installer"
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
