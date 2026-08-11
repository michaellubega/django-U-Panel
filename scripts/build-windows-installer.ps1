# Build U-Panel Windows desktop installer (.exe) with Inno Setup.
#
# Prerequisites (Windows only):
#   - Flutter SDK with Windows desktop enabled
#   - Visual Studio 2022 (Desktop development with C++)
#   - Inno Setup 6: https://jrsoftware.org/isinfo.php
#
# Usage (from project root):
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows-installer.ps1
#   powershell -File scripts\build-windows-installer.ps1 -ApiBaseUrl https://kiu.orion13.us
#   powershell -File scripts\build-windows-installer.ps1 -PublishDownloads
#
# Output:
#   installer\output\U-Panel-<version>-windows-setup.exe

param(
    [string]$ApiBaseUrl = "https://kiu.orion13.us",
    [string]$OneSignalAppId = "882dcbec-c505-4c12-95c5-78da7e8ef25c",
    [string]$InnoSetupPath = "",
    [switch]$PublishDownloads
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter not found on PATH. Install Flutter and enable Windows desktop."
}

$pubspec = Get-Content "pubspec.yaml" -Raw
if ($pubspec -notmatch 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)') {
    throw "Could not read version from pubspec.yaml"
}
$Version = $Matches[1]
$Build = [int]$Matches[2]

$dartDefines = @(
    "--dart-define=UPANEL_API_BASE_URL=$ApiBaseUrl",
    "--dart-define=ONESIGNAL_APP_ID=$OneSignalAppId"
)

Write-Host "==> flutter pub get"
flutter pub get

Write-Host "==> flutter build windows --release (v$Version build $Build)"
flutter build windows --release @dartDefines

$releaseExe = Join-Path $root "build\windows\x64\runner\Release\u_panel.exe"
if (-not (Test-Path -LiteralPath $releaseExe)) {
    throw "Windows release build missing: $releaseExe"
}

function Find-InnoSetupCompiler {
    param([string]$OverridePath)

    if ($OverridePath -and (Test-Path -LiteralPath $OverridePath)) {
        return (Resolve-Path -LiteralPath $OverridePath).Path
    }

    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 5\ISCC.exe"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    return $null
}

$iscc = Find-InnoSetupCompiler -OverridePath $InnoSetupPath
if (-not $iscc) {
    throw @"
Inno Setup compiler (ISCC.exe) not found.
Install Inno Setup 6 from https://jrsoftware.org/isinfo.php
or pass -InnoSetupPath 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
"@
}

$iss = Join-Path $root "installer\U-Panel.iss"
Write-Host "==> Inno Setup compile ($iscc)"
& $iscc $iss "/DMyAppVersion=$Version"

$built = Join-Path $root "installer\output\U-Panel-$Version-windows-setup.exe"
if (-not (Test-Path -LiteralPath $built)) {
    throw "Installer not created: $built"
}

$installerCopy = Join-Path $root "installer\U-Panel-$Version-windows-setup.exe"
Copy-Item -LiteralPath $built -Destination $installerCopy -Force

Write-Host ""
Write-Host "Built installer:"
Write-Host "  $built"
Write-Host "  $installerCopy"

if ($PublishDownloads) {
    Write-Host ""
    Write-Host "==> Copy to website/downloads"
    & (Join-Path $PSScriptRoot "prepare-download-site.ps1") -Version $Version
}

Write-Host ""
Write-Host "Upload to site: git add website/downloads && git commit && git push"
