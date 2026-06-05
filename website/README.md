# U-Panel download website

Static landing page for **Android APK**, **Windows**, and a link to the **web app**.

## Live URLs

| Page | URL |
|------|-----|
| **Landing page** | https://orion13.us/ |
| **Short alias** | https://kiu.orion13.us/ → redirects to orion13.us |
| **APK & Windows installer** | https://orion13.us/downloads/ |
| **Web app** | https://u-panel-2026.web.app/ |
| **Web app (alt)** | https://u-panel-2026.firebaseapp.com/ |

**APK and `.exe` installers are hosted on GitHub Pages** (`website/downloads/`). Firebase only hosts the Flutter web app and a mirror of this landing page (buttons link to GitHub for installers).

This folder is published automatically to **GitHub Pages** on every push to `main`. Custom domain: **orion13.us** (`website/CNAME`).

### DNS on Spaceship

#### 1. Apex — orion13.us (GitHub Pages)

Four **A** records on `@`:

| Type | Host | Value |
|------|------|-------|
| A | `@` | `185.199.108.153` |
| A | `@` | `185.199.109.153` |
| A | `@` | `185.199.110.153` |
| A | `@` | `185.199.111.153` |

Optional **www** CNAME: Host `www`, Value `michaellubega.github.io`

#### 2. Alias — kiu.orion13.us → orion13.us

In Spaceship → **orion13.us** → **DNS** (or **URL redirect / forwarding**):

- **Remove** any **CNAME** on `kiu` that points to `michaellubega.github.io` (that sends kiu to GitHub directly).
- Add **URL redirect** (or forwarding):
  - **Host:** `kiu`
  - **Target:** `https://orion13.us`
  - Use **permanent (301)** if Spaceship offers it.

Visitors who open **kiu.orion13.us** will land on **orion13.us** in the browser.

#### 3. GitHub Pages

[u_panel Settings → Pages](https://github.com/michaellubega/u_panel/settings/pages) → Custom domain: **`orion13.us`** → **Enforce HTTPS**.

Verify:

```powershell
nslookup orion13.us
nslookup kiu.orion13.us
```

`orion13.us` should return the four GitHub A addresses. `kiu.orion13.us` should resolve to Spaceship’s redirect/forwarding (not GitHub directly).

## Deploy everything

```powershell
.\scripts\deploy-hosting.ps1
```

Or step by step:

```powershell
flutter build web --release
flutter build apk --release
.\scripts\prepare-download-site.ps1
firebase deploy --only hosting
```

### Windows installer (Inno Setup)

```powershell
.\scripts\prepare-download-site.ps1 -WindowsInstaller "C:\path\to\U-Panel-Setup.exe"
```

Commit and push to `main` so GitHub Pages serves updated binaries.

## Local preview

```powershell
cd website
python -m http.server 8080
```
