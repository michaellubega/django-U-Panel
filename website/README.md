# U-Panel download website

Static landing page for **Google Play (Android)**, **Windows installer**, and the **web app**.

## Live URLs

| Page | URL |
|------|-----|
| **Landing page** | https://kiu.orion13.us/ |
| **Web app (production)** | https://kiu.orion13.us/app/ |
| **Web app (test)** | https://test.orion13.us/app/ |
| **Google Play (Android)** | https://play.google.com/store/apps/details?id=com.u_panel |
| **Windows installer** | https://kiu.orion13.us/downloads/U-Panel-1.0.0-windows-setup.exe |

Production is served from Contabo `/opt/upanel` (Cloudflare `kiu` → VPS). The **test** hostname is a separate stack at `/opt/test` — see [docs/SERVER_SETUP.md](../docs/SERVER_SETUP.md) and `scripts/contabo/deploy-test-on-server.sh`.

Published landing assets also flow via GitHub Pages (`website/CNAME`). Custom domain: **kiu.orion13.us**.

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

## DNS (Cloudflare)

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| **A** | `kiu` | `169.58.135.136` | Proxied |
| **A** | `test` | `169.58.135.136` | Proxied |

SSL/TLS mode: **Flexible**. Details: [docs/CLOUDFLARE_DNS_SETUP.md](../docs/CLOUDFLARE_DNS_SETUP.md).

If you still use GitHub Pages for marketing only, a CNAME `kiu` → `michaellubega.github.io` is an alternative — production API/web on Contabo currently uses the A-record setup above.

GitHub Pages → Custom domain: **kiu.orion13.us** → Enforce HTTPS.

## Local preview

```powershell
cd website
python -m http.server 8080
```
