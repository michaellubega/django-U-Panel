# U-Panel download website

Static landing page for **Android APK**, **Windows**, and a link to the **web app**.

## Live URLs

| Page | URL |
|------|-----|
| **GitHub landing page** | https://michaellubega.github.io/u_panel/ |
| **Web app** | https://u-panel-2026.web.app/ |
| **Web app (alt)** | https://u-panel-2026.firebaseapp.com/ |
| **Firebase downloads** | https://u-panel-2026.web.app/download/ |

This folder is published automatically to **GitHub Pages** on every push to `main` (see `.github/workflows/github-pages.yml`).

Firebase Hosting serves the Flutter web build at the **site root**. The same download page is also copied to `build/web/download/` before Firebase deploy.

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

The script copies it to `website/downloads/` and enables the download button.

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
