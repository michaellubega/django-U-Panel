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

#### 2. Alias — kiu.orion13.us → orion13.us (URL Redirect, not DNS)

Spaceship puts redirects in the **domain panel**, not under Advanced DNS.

1. **Launchpad** → **Domain list** → click **orion13.us**.
2. In the **right-hand side panel**, choose **URL redirect** (not “DNS” / “Advanced DNS”).
   - Or: **Connections** → **+** on the domain → **URL Redirects**.
3. **First remove** any **CNAME** or **A** record for host **`kiu`** under **Advanced DNS** (otherwise Spaceship shows *“only one hosting service is allowed”*).
4. In **URL redirect**:
   - **From / source:** `kiu` (i.e. `kiu.orion13.us`)
   - **To / destination:** `https://orion13.us`
   - **Type:** **301 permanent** (not “masked” / frame)
5. **Save**.

Nameservers must be **Spaceship DNS** for URL redirect to work.

**Do not** add a URL redirect on `@` (apex) — that would break GitHub Pages. Only redirect the **`kiu`** subdomain.

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
