# U-Panel download website

Static landing page for **Android APK**, **Windows**, and a link to the **web app**.

## Live URLs

| Page | URL |
|------|-----|
| **Landing page** | https://kiu.orion13.us/ |
| **Apex (optional)** | https://orion13.us/ |
| **APK & Windows installer** | https://kiu.orion13.us/downloads/ |
| **Web app** | https://u-panel-2026.web.app/ |
| **Web app (alt)** | https://u-panel-2026.firebaseapp.com/ |

**APK and `.exe` installers are hosted on GitHub Pages** (`website/downloads/`). Firebase only hosts the Flutter web app and a mirror of this landing page (buttons link to GitHub for installers).

Published on every push to `main`. Custom domain: **kiu.orion13.us** (`website/CNAME`).

### DNS on Spaceship (Advanced DNS)

#### kiu.orion13.us — main URL (CNAME)

**Advanced DNS** → **Custom records**:

| Type | Host | Value | TTL |
|------|------|-------|-----|
| **CNAME** | `kiu` | `michaellubega.github.io` | 3600 |

- No `https://`, no `/u_panel`
- Remove any other record on host **`kiu`** (old redirect, A, or duplicate CNAME)

#### orion13.us — optional apex (same site)

Keep four **A** records on `@` if you also want the apex to work:

| Type | Host | Value |
|------|------|-------|
| A | `@` | `185.199.108.153` |
| A | `@` | `185.199.109.153` |
| A | `@` | `185.199.110.153` |
| A | `@` | `185.199.111.153` |

Optional **www** CNAME: Host `www`, Value `michaellubega.github.io`

#### GitHub Pages

[u_panel Settings → Pages](https://github.com/michaellubega/u_panel/settings/pages) → Custom domain: **`kiu.orion13.us`** → wait for DNS check → **Enforce HTTPS**.

Verify:

```powershell
nslookup kiu.orion13.us
```

Should resolve to `michaellubega.github.io` (or GitHub Pages IPs).

## Deploy everything

```powershell
.\scripts\deploy-hosting.ps1
```

Or:

```powershell
flutter build web --release
flutter build apk --release
.\scripts\prepare-download-site.ps1
firebase deploy --only hosting
```

Commit and push after updating installers so GitHub Pages serves new binaries.

## Local preview

```powershell
cd website
python -m http.server 8080
```
