# U-Panel download website

Static landing page for **Android APK**, **Windows**, and a link to the **web app**.

## Live URLs

| Page | URL |
|------|-----|
| **Landing page** | https://kiu.orion13.us/ |
| **APK & Windows installer** | https://kiu.orion13.us/downloads/ |
| **Web app** | https://u-panel-2026.web.app/ |
| **Web app (alt)** | https://u-panel-2026.firebaseapp.com/ |

**APK and `.exe` installers are hosted on GitHub Pages** (`website/downloads/`). Firebase only hosts the Flutter web app and a mirror of this landing page (buttons link to GitHub for installers).

This folder is published automatically to **GitHub Pages** on every push to `main` (see `.github/workflows/github-pages.yml`). Custom domain: **kiu.orion13.us** (`website/CNAME`).

### DNS on Spaceship (kiu.orion13.us → GitHub Pages)

1. Sign in at [spaceship.com](https://www.spaceship.com) → **Domains** → **orion13.us**.
2. **Nameservers** → use **Spaceship DNS**.
3. Open **DNS / Advanced DNS** → **Add record**:

| Type | Host | Value | TTL |
|------|------|-------|-----|
| **CNAME** | `kiu` | `michaellubega.github.io` | 3600 |

Use `michaellubega.github.io` only — no `https://`, no `/u_panel`.

4. **GitHub** → [u_panel Settings → Pages](https://github.com/michaellubega/u_panel/settings/pages) → Custom domain: **`kiu.orion13.us`** → Save → wait for DNS check → **Enforce HTTPS**.

5. Optional: redirect **orion13.us** → **kiu.orion13.us** in Spaceship (**URL redirect** or forwarding) so the short apex still works.

DNS can take a few minutes up to 48 hours.

Verify:

```powershell
nslookup kiu.orion13.us
```

You should see `michaellubega.github.io` in the answer.

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
