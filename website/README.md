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

### DNS on Spaceship (orion13.us → GitHub Pages)

1. Sign in at [spaceship.com](https://www.spaceship.com) → **Domains** → **orion13.us**.
2. **Nameservers** → use **Spaceship DNS** (not external/parking DNS).
3. Open **DNS / Advanced DNS** → **Add record** (create **four separate A records**):

| Type | Host | Value | TTL |
|------|------|-------|-----|
| **A** | `@` | `185.199.108.153` | 3600 (or Auto) |
| **A** | `@` | `185.199.109.153` | 3600 |
| **A** | `@` | `185.199.110.153` | 3600 |
| **A** | `@` | `185.199.111.153` | 3600 |

4. **Remove** any other **A** or **ALIAS** records on `@` that point elsewhere (parking, old host, etc.).
5. **Required for www** — add **CNAME** (fixes GitHub `InvalidDNSError` on `www.orion13.us`):

| Type | Host | Value | TTL |
|------|------|-------|-----|
| **CNAME** | `www` | `michaellubega.github.io` | 3600 |

   Do **not** point `www` at `orion13.us`. It must be `michaellubega.github.io` (no `https://`, no `/u_panel`).

6. Optional IPv6 — four **AAAA** records on `@`: `2606:50c0:8000::153` … `2606:50c0:8003::153`.
7. **GitHub** → [u_panel Settings → Pages](https://github.com/michaellubega/u_panel/settings/pages) → Custom domain: **`orion13.us`** only (not `www.orion13.us`) → Save → wait for DNS check → **Enforce HTTPS**.

DNS can take a few minutes up to 48 hours. The repo already includes `website/CNAME` with `orion13.us`.

### `www.orion13.us` — InvalidDNSError

GitHub checks **www** even when the custom domain is the apex. Add the **CNAME** in step 5 above, wait 15–60 minutes, then click **Check again** on GitHub Pages.

Verify from your PC:

```powershell
nslookup www.orion13.us
```

You should see `michaellubega.github.io` in the answer. If `nslookup` fails, the CNAME is missing or still propagating.

**If you do not want www at all:** remove `www.orion13.us` from the GitHub Pages custom-domain field (use only `orion13.us`), keep the CNAME anyway so GitHub’s check passes.

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
