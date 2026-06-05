# Builds Flutter web + stages download page, then deploys Firebase Hosting.
# Result:
#   https://u-panel-2026.web.app/           -> U-Panel web app
#   https://u-panel-2026.web.app/download/  -> APK / Windows installer page

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "Building Flutter web (release)..."
flutter build web --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot "prepare-download-site.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Deploying Firebase Hosting..."
firebase deploy --only hosting
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Live URLs:"
Write-Host "  Web app:   https://u-panel-2026.web.app/"
Write-Host "  Downloads: https://u-panel-2026.web.app/download/"
