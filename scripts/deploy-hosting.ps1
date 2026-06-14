# Builds Flutter web + stages download page, then deploys Firebase Hosting.
# Result:
#   https://u-panel-2026.web.app/           -> U-Panel web app
#   https://u-panel-2026.web.app/download/  -> landing page (installers link to GitHub)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

& (Join-Path $PSScriptRoot "sync-kiu-branding.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Building Flutter web (release)..."
flutter build web --release --no-wasm-dry-run -O4 --tree-shake-icons
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot "finalize-web-build.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot "update-android-assetlinks.ps1")
& (Join-Path $PSScriptRoot "prepare-download-site.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Deploying Firebase Hosting..."
$firebaseCmd = Get-Command firebase -ErrorAction SilentlyContinue
if ($firebaseCmd) {
    & firebase deploy --only hosting
} else {
    $nodeDir = Join-Path ${env:ProgramFiles} "nodejs"
    $npx = Join-Path $nodeDir "npx.cmd"
    if (-not (Test-Path $npx)) {
        Write-Error "Firebase CLI not found. Install Node.js or run: npm install -g firebase-tools"
        exit 1
    }
    $env:Path = "$nodeDir;$env:Path"
    & $npx --yes firebase-tools@latest deploy --only hosting
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Live URLs:"
Write-Host "  Web app:   https://u-panel-2026.web.app/"
Write-Host "  Landing:   https://kiu.orion13.us/"
Write-Host "  Installers: https://kiu.orion13.us/downloads/"
