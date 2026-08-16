# Windows installer (Inno Setup)

Build the U-Panel Windows `.exe` installer on a **Windows PC** (Flutter Windows desktop cannot be built on macOS/Linux).

## Prerequisites

1. [Flutter](https://docs.flutter.dev/get-started/install/windows) with Windows desktop enabled
2. Visual Studio 2022 — **Desktop development with C++**
3. [Inno Setup 6](https://jrsoftware.org/isinfo.php)

## One-command build

From the project root in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-windows-installer.ps1
```

With API URL and copy to download site:

```powershell
powershell -File scripts\build-windows-installer.ps1 `
  -ApiBaseUrl https://kiu.orion13.us `
  -PublishDownloads
```

## Output

| File | Purpose |
|------|---------|
| `installer\output\U-Panel-1.0.0-windows-setup.exe` | Inno Setup output |
| `installer\U-Panel-1.0.0-windows-setup.exe` | Copy used by `prepare-download-site.ps1` |

## Manual steps

```powershell
flutter pub get
flutter build windows --release `
  --dart-define=UPANEL_API_BASE_URL=https://kiu.orion13.us `
  --dart-define=ONESIGNAL_APP_ID=882dcbec-c505-4c12-95c5-78da7e8ef25c

"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\U-Panel.iss /DMyAppVersion=1.0.0
```

## Inno script

`installer/U-Panel.iss` is based on your setup script, with repo-relative paths:

- Release files: `build\windows\x64\runner\Release\*`
- Icon: `windows\runner\resources\app_icon.ico`
- App ID: `{B7E12B46-EFE2-406A-8C47-05DAD6FFF724}`

## Publish on kiu.orion13.us

```powershell
powershell -File scripts\prepare-download-site.ps1
git add website/downloads website/releases.json
git commit -m "Update Windows installer"
git push origin main
```

Then on the server: `bash scripts/contabo/deploy-web-on-server.sh`
