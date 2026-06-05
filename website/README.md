# U-Panel download website

Static landing page for **Android APK**, **Windows**, and a link to the **web app**.

## Live URLs

| Page | URL |
|------|-----|
| **GitHub landing page** | https://michaellubega.github.io/u_panel/ |
| **APK & Windows installer** | https://michaellubega.github.io/u_panel/downloads/ |
| **Web app** | https://u-panel-2026.web.app/ |
| **Web app (alt)** | https://u-panel-2026.firebaseapp.com/ |

**APK and `.exe` installers are hosted on GitHub Pages** (`website/downloads/`). Firebase only hosts the Flutter web app and a mirror of this landing page (buttons link to GitHub for installers).

This folder is published automatically to **GitHub Pages** on every push to `main` (see `.github/workflows/github-pages.yml`).

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
