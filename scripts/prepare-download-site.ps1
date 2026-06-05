# Copies release builds into website/downloads and updates releases.json.
# Run from the project root after:
#   flutter build apk --release
#   Inno Setup compile -> installer/U-Panel-<version>-windows-setup.exe
#     (or pass -WindowsInstaller path\to\your-setup.exe)

param(
    [string]$Version = "",
    [string]$WindowsInstaller = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$pubspec = Get-Content "pubspec.yaml" -Raw
if ($Version -eq "") {
    if ($pubspec -match 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)') {
        $Version = $Matches[1]
        $Build = [int]$Matches[2]
    } else {
        throw "Could not read version from pubspec.yaml"
    }
} else {
    $Build = 1
}

$website = Join-Path $root "website"
$downloads = Join-Path $website "downloads"
$assets = Join-Path $website "assets"
$siteDomain = "https://kiu.orion13.us"
New-Item -ItemType Directory -Force -Path $downloads, $assets | Out-Null

$iconSrc = Join-Path $root "kiu\playstore.png"
$iconDst = Join-Path $assets "icon.png"
if (Test-Path $iconSrc) {
    Copy-Item $iconSrc $iconDst -Force
}

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N0} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

$release = [ordered]@{
    version    = $Version
    build      = $Build
    releasedAt = (Get-Date -Format "yyyy-MM-dd")
    hostBase   = $siteDomain
    ios        = [ordered]@{
        label   = "iPhone & iPad"
        status  = "coming_soon"
        webUrl  = "https://u-panel-2026.web.app/"
        message = "Native iOS app coming soon. Use the web app in Safari for now."
    }
    android    = [ordered]@{
        file         = "$siteDomain/downloads/U-Panel-$Version-android.apk"
        label        = "Android APK"
        minAndroid   = "7.0 (Nougat)"
        available    = $false
    }
    windows    = [ordered]@{
        file         = "$siteDomain/downloads/U-Panel-$Version-windows-setup.exe"
        label        = "Windows installer"
        minWindows   = "Windows 10 (64-bit)"
        available    = $false
    }
    web        = [ordered]@{
        url          = "https://u-panel-2026.web.app/"
        alternateUrl = "https://u-panel-2026.firebaseapp.com/"
        label        = "Web app"
        available    = $true
    }
}

$apkSrc = Join-Path $root "build\app\outputs\flutter-apk\app-release.apk"
$apkDst = Join-Path $downloads "U-Panel-$Version-android.apk"
if (Test-Path $apkSrc) {
    Copy-Item $apkSrc $apkDst -Force
    $release.android.available = $true
    $release.android.size = Format-Size (Get-Item $apkDst).Length
    Write-Host "Android: $apkDst"
} else {
    Write-Warning "APK not found. Run: flutter build apk --release"
}

$winDst = Join-Path $downloads "U-Panel-$Version-windows-setup.exe"
$winSrc = $null

function Find-WindowsInstaller {
    param([string]$Version, [string]$ProjectRoot)

    $candidates = @(
        (Join-Path $ProjectRoot "installer\U-Panel-$Version-windows-setup.exe"),
        (Join-Path $ProjectRoot "installer\UPanelSetup.exe"),
        (Join-Path $env:USERPROFILE "Desktop\output\UPanelSetup.exe"),
        (Join-Path $env:USERPROFILE "Desktop\output\U-Panel-$Version-windows-setup.exe")
    )

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    $searchDirs = @(
        (Join-Path $ProjectRoot "installer"),
        (Join-Path $env:USERPROFILE "Desktop\output")
    )

    foreach ($dir in $searchDirs) {
        if (-not (Test-Path $dir)) { continue }
        $latestExe = Get-ChildItem $dir -Filter "*.exe" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latestExe) { return $latestExe.FullName }
    }

    return $null
}

if ($WindowsInstaller -ne "") {
    $resolved = Resolve-Path -LiteralPath $WindowsInstaller -ErrorAction SilentlyContinue
    if ($resolved) { $winSrc = $resolved.Path }
} else {
    $winSrc = Find-WindowsInstaller -Version $Version -ProjectRoot $root
    if (-not $winSrc -and (Test-Path $winDst)) {
        $winSrc = $winDst
    }
}

if ($winSrc) {
    if ($winSrc -ne $winDst) {
        Copy-Item $winSrc $winDst -Force
    }
    $release.windows.available = $true
    $release.windows.size = Format-Size (Get-Item $winDst).Length
    Write-Host "Windows installer: $winDst"
} else {
    Write-Warning "Windows installer not found. Place UPanelSetup.exe in Desktop\output or installer\, or pass -WindowsInstaller path\to\setup.exe"
}

$jsonPath = Join-Path $website "releases.json"
$json = ($release | ConvertTo-Json -Depth 5)
# UTF-8 without BOM — a BOM breaks JSON.parse in browsers and disables all buttons.
[System.IO.File]::WriteAllText($jsonPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "Updated $jsonPath"

# Stage download page under build/web/download/ (Flutter app stays at site root).
$webBuild = Join-Path $root "build\web"
$webFlutterIndex = Join-Path $webBuild "index.html"
if (Test-Path $webFlutterIndex) {
    $downloadDest = Join-Path $webBuild "download"
    if (Test-Path $downloadDest) { Remove-Item $downloadDest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $downloadDest | Out-Null
    Copy-Item (Join-Path $website "index.html") $downloadDest -Force
    Copy-Item (Join-Path $website "styles.css") $downloadDest -Force
    Copy-Item (Join-Path $website "app.js") $downloadDest -Force
    Copy-Item (Join-Path $website "releases.json") $downloadDest -Force
    if (Test-Path (Join-Path $website "assets")) {
        Copy-Item (Join-Path $website "assets") (Join-Path $downloadDest "assets") -Recurse -Force
    }
    Write-Host "Staged download page: $downloadDest (installers hosted on GitHub Pages, not copied)"
    Write-Host "  Web app URL:       https://u-panel-2026.web.app/"
    Write-Host "  Landing page URL:  $siteDomain/"
    Write-Host "  APK / Windows URL: $siteDomain/downloads/"
} else {
    Write-Warning "Flutter web build not found. Run: flutter build web --release"
    Write-Warning "Then re-run this script before firebase deploy --only hosting"
}

Write-Host "Deploy with: firebase deploy --only hosting"
