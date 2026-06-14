# Runs the Firestore → RTD session backfill with a service account key.
# Firebase CLI login alone is not enough for firebase-admin scripts.
#
# Setup (once):
#   1. Firebase Console → Project settings → Service accounts
#   2. "Generate new private key" for u-panel-2026
#   3. Save as functions/service-account.json (never commit this file)
#
# Usage:
#   .\scripts\run-backfill-sessions-rtd.ps1
#   .\scripts\run-backfill-sessions-rtd.ps1 -DryRun
#   .\scripts\run-backfill-sessions-rtd.ps1 -Limit 50
#   .\scripts\run-backfill-sessions-rtd.ps1 -CredentialsPath C:\path\to\key.json

param(
    [switch]$DryRun,
    [int]$Limit = 0,
    [string]$CredentialsPath = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$functionsDir = Join-Path $root "functions"

$candidates = @()
if ($CredentialsPath) {
    $candidates += $CredentialsPath
}
if ($env:GOOGLE_APPLICATION_CREDENTIALS) {
    $candidates += $env:GOOGLE_APPLICATION_CREDENTIALS
}
$candidates += @(
    (Join-Path $functionsDir "service-account.json"),
    (Join-Path $functionsDir "u-panel-2026-firebase-adminsdk.json"),
    (Join-Path $root "secrets\service-account.json")
)

$keyFile = $null
foreach ($path in $candidates) {
    if ($path -and (Test-Path $path)) {
        $keyFile = (Resolve-Path $path).Path
        break
    }
}

if (-not $keyFile) {
    Write-Host ""
    Write-Host "No Google service account key found." -ForegroundColor Red
    Write-Host ""
    Write-Host "This script needs Admin SDK credentials (Firebase login is not enough)."
    Write-Host ""
    Write-Host "1. Open: https://console.firebase.google.com/project/u-panel-2026/settings/serviceaccounts/adminsdk"
    Write-Host "2. Click 'Generate new private key' and save the JSON file."
    Write-Host "3. Save it as: functions\service-account.json"
    Write-Host "   (or pass -CredentialsPath C:\path\to\key.json)"
    Write-Host ""
    Write-Host "Optional: install Google Cloud SDK and run:"
    Write-Host "  gcloud auth application-default login"
    Write-Host ""
    exit 1
}

$env:GOOGLE_APPLICATION_CREDENTIALS = $keyFile
Write-Host "Using credentials: $keyFile"

Set-Location $functionsDir
$args = @()
if ($DryRun) { $args += "--dry-run" }
if ($Limit -gt 0) { $args += "--limit=$Limit" }

npm run backfill-sessions-rtd -- @args
exit $LASTEXITCODE
