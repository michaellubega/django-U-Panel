# U-Panel download website

Static landing page for **Android APK**, **Windows**, and a link to the **web app**.

## Live URLs

| Page | URL |
|------|-----|
| **Landing page** | https://orion13.us/ |
| **APK & Windows installer** | https://orion13.us/downloads/ |
| **Web app** | https://u-panel-2026.web.app/ |
| **Web app (alt)** | https://u-panel-2026.firebaseapp.com/ |

**APK and `.exe` installers are hosted on GitHub Pages** (`website/downloads/`). Firebase only hosts the Flutter web app and a mirror of this landing page (buttons link to GitHub for installers).

This folder is published automatically to **GitHub Pages** on every push to `main` (see `.github/workflows/github-pages.yml`). Custom domain: **orion13.us** (`website/CNAME`).

### DNS for orion13.us (at your domain registrar)

Point the apex domain to GitHub Pages:

| Type | Name | Value |
|------|------|--------|
| **A** | `@` | `185.199.108.153` |
| **A** | `@` | `185.199.109.153` |
| **A** | `@` | `185.199.110.153` |
| **A** | `@` | `185.199.111.153` |

Optional IPv6 (**AAAA**): `2606:50c0:8000::153` through `2606:50c0:8003::153` (same set GitHub documents for Pages).

Then in **GitHub → u_panel → Settings → Pages**, set custom domain to `orion13.us` and enable **Enforce HTTPS** when available.

## Deploy everything

```powershell
.\scripts\deploy-hosting.ps1
```

Or step by step:

```powershell
flutter build web --release
flutter build apk --release
# Build Windows with Inno Setup, then copy or output to:
#   installer/U-Panel-<version>-windows-setup.exe
.\scripts\prepare-download-site.ps1
firebase deploy --only hosting
```

### Windows installer (Inno Setup)

1. `flutter build windows --release`
2. Compile your Inno Setup script to produce a `.exe` installer.
3. Place the file at `Desktop\output\UPanelSetup.exe`, `installer/U-Panel-<version>-windows-setup.exe`, or run:

```powershell
.\scripts\prepare-download-site.ps1 -WindowsInstaller "C:\path\to\U-Panel-Setup.exe"
```

The script copies it to `website/downloads/`, updates `releases.json` with GitHub download URLs, and enables the download buttons. Commit and push to `main` so GitHub Pages serves the new binaries.

## Local preview

Download page only:

```powershell
cd website
python -m http.server 8080
```

Flutter web (after `flutter build web`):

```powershell
cd build/web
python -m http.server 8080
```
