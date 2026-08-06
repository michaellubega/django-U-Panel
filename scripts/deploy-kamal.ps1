# Deploy U-Panel Django API to VPS via Kamal.
# Usage: .\scripts\deploy-kamal.ps1 [-Setup] [-BootAccessories]
# Requires: Ruby/Kamal, SSH root@169.58.135.136, Docker Hub token (KAMAL_REGISTRY_PASSWORD)

param(
    [switch]$Setup,
    [switch]$BootAccessories
)

$ErrorActionPreference = "Stop"
$ServerIp = "169.58.135.136"

function New-RandomSecret([int]$Length = 48) {
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) -replace '[+/=]', 'x'
}

# Ensure required secrets exist (generate ephemeral ones if missing — override for production).
if (-not $env:DJANGO_SECRET_KEY) {
    $env:DJANGO_SECRET_KEY = New-RandomSecret 64
    Write-Host "Generated DJANGO_SECRET_KEY (set `$env:DJANGO_SECRET_KEY to persist across deploys)."
}
if (-not $env:POSTGRES_PASSWORD) {
    $env:POSTGRES_PASSWORD = New-RandomSecret 32
    Write-Host "Generated POSTGRES_PASSWORD (set `$env:POSTGRES_PASSWORD to persist across deploys)."
}
if (-not $env:DATABASE_URL) {
    $env:DATABASE_URL = "postgres://upanel:$($env:POSTGRES_PASSWORD)@upanel-db:5432/upanel"
}

if (-not $env:KAMAL_REGISTRY_PASSWORD) {
    Write-Error @"
KAMAL_REGISTRY_PASSWORD is not set.
Export your Docker Hub personal access token:
  `$env:KAMAL_REGISTRY_PASSWORD = 'your-docker-hub-token'
"@
}

Write-Host "Testing SSH to root@${ServerIp}..."
ssh -o ConnectTimeout=15 -o BatchMode=yes "root@${ServerIp}" "echo SSH OK" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error @"
Cannot SSH to root@${ServerIp}:22.
Open port 22 in your cloud firewall/security group, ensure the server is running,
and add your SSH public key to root (or set KAMAL_SSH_USER / deploy user in config/deploy.yml).
"@
}

Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    if ($BootAccessories) {
        Write-Host "Booting Postgres, Redis, nginx accessories..."
        kamal accessory boot db
        kamal accessory boot redis
        kamal accessory boot nginx
    }

    if ($Setup) {
        Write-Host "Running kamal setup (installs Docker, builds image, starts app)..."
        kamal setup
    }

    Write-Host "Deploying..."
    kamal deploy

    Write-Host ""
    Write-Host "API should be live at: http://${ServerIp}/api/health/"
    Write-Host "Flutter client: flutter run --dart-define=UPANEL_API_BASE_URL=http://${ServerIp}"
}
finally {
    Pop-Location
}
