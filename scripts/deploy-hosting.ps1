# Build and publish U-Panel Flutter web app to GitHub Pages (no Firebase).
#
# Usage:
#   .\scripts\deploy-hosting.ps1
#   .\scripts\deploy-hosting.ps1 -ApiBaseUrl "http://169.58.135.136"
#   .\scripts\deploy-hosting.ps1 -IncludeApk
#
# Publishes:
#   Web app  -> https://kiu.orion13.us/app/
#   Landing  -> https://kiu.orion13.us/  (git push website/)

param(
    [string]$ApiBaseUrl = "http://169.58.135.136",
    [string]$WebBaseHref = "/app/"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$siteDomain = "https://kiu.orion13.us"
$webAppUrl = "$siteDomain/app/"

Write-Host "==> Building Flutter web (API: $ApiBaseUrl, base-href: $WebBaseHref)"
flutter build web --release "--dart-define=UPANEL_API_BASE_URL=$ApiBaseUrl" "--base-href=$WebBaseHref"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "==> Finalizing web build"
& (Join-Path $PSScriptRoot "finalize-web-build.ps1")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "==> Copying build/web -> website/app/"
$webDest = Join-Path $root "website\app"
if (Test-Path $webDest) { Remove-Item $webDest -Recurse -Force }
New-Item -ItemType Directory -Force -Path $webDest | Out-Null
Copy-Item (Join-Path $root "build\web\*") $webDest -Recurse -Force
New-Item -ItemType File -Force -Path (Join-Path $root "website\.nojekyll") | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $webDest ".nojekyll") | Out-Null

$wellKnownSrc = Join-Path $root "web\.well-known"
if (Test-Path $wellKnownSrc) {
    $wellKnownDest = Join-Path $root "website\.well-known"
    New-Item -ItemType Directory -Force -Path $wellKnownDest | Out-Null
    Copy-Item (Join-Path $wellKnownSrc "*") $wellKnownDest -Force
    Write-Host "Staged Digital Asset Links: website\.well-known\"
}

Write-Host "==> Updating releases.json"
& (Join-Path $PSScriptRoot "prepare-download-site.ps1")

Write-Host ""
Write-Host "Web build published to website\app\"
Write-Host "  Web app URL:  $webAppUrl"
Write-Host "  Landing page: $siteDomain/"
Write-Host ""
Write-Host "Option A — push to GitHub (CI builds and deploys automatically on main):"
Write-Host "  git add website .github scripts"
Write-Host "  git commit -m `"Update web deploy config`""
Write-Host "  git push origin main"
Write-Host ""
Write-Host "Option B — publish website\app\ from this machine (must git add website/app):"
Write-Host "  git add website"
Write-Host "  git commit -m `"Publish web app`""
Write-Host "  git push origin main"
