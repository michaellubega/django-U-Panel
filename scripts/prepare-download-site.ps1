# Copies release builds into website/downloads and updates releases.json.
# Run from the project root after:
#   flutter build apk --release
#   Inno Setup compile -> installer/U-Panel-<version>-windows-setup.exe
#     (or pass -WindowsInstaller path\to\your-setup.exe)
#     Default search: installer\, Desktop\Output\UPanelSetup.exe (OneDrive Desktop OK)

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

& (Join-Path $PSScriptRoot "sync-kiu-branding.ps1")
$iconDst = Join-Path $assets "icon.png"

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N0} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

$webAppUrl = "$siteDomain/app/"
$release = [ordered]@{
    version    = $Version
    build      = $Build
    releasedAt = (Get-Date -Format "yyyy-MM-dd")
    hostBase   = $siteDomain
    ios        = [ordered]@{
        label   = "iPhone & iPad"
        status  = "coming_soon"
        webUrl  = $webAppUrl
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
        url          = $webAppUrl
        label        = "Web app"
        available    = $true
    }
}

function Copy-ReleaseBinary {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$MaxAttempts = 8
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Release copy source not found: $Source"
    }

    $destDir = Split-Path -Parent $Destination
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }

    $temp = "$Destination.part"
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $temp -Force
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force
            }
            Move-Item -LiteralPath $temp -Destination $Destination -Force
            return
        } catch {
            if ($attempt -ge $MaxAttempts) { throw }
            $waitMs = 250 * $attempt
            Write-Host "  Copy retry $attempt/$MaxAttempts ($waitMs ms): $($_.Exception.Message)"
            Start-Sleep -Milliseconds $waitMs
        } finally {
            if (Test-Path -LiteralPath $temp) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$apkSrc = Join-Path $root "build\app\outputs\flutter-apk\app-release.apk"
$apkDst = Join-Path $downloads "U-Panel-$Version-android.apk"
if (Test-Path $apkSrc) {
    Copy-ReleaseBinary -Source $apkSrc -Destination $apkDst
    $release.android.available = $true
    $release.android.size = Format-Size (Get-Item $apkDst).Length
    Write-Host "Android: $apkDst"
} else {
    Write-Warning "APK not found. Run: flutter build apk --release"
}

$winDst = Join-Path $downloads "U-Panel-$Version-windows-setup.exe"
$winSrc = $null

function Get-WindowsInstallerSearchDirs {
    param([string]$ProjectRoot)

    $dirs = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    function Add-Dir([string]$path) {
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        $full = $path
        if (Test-Path -LiteralPath $path) {
            $full = (Resolve-Path -LiteralPath $path).Path
        }
        $key = $full.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$dirs.Add($full)
        }
    }

    Add-Dir (Join-Path $ProjectRoot "installer")

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) {
        Add-Dir (Join-Path $desktop "Output")
        Add-Dir (Join-Path $desktop "output")
    }

    # Legacy path when Desktop is not under OneDrive.
    Add-Dir (Join-Path $env:USERPROFILE "Desktop\Output")
    Add-Dir (Join-Path $env:USERPROFILE "Desktop\output")

    return $dirs
}

function Find-WindowsInstaller {
    param([string]$Version, [string]$ProjectRoot)

    $searchDirs = Get-WindowsInstallerSearchDirs -ProjectRoot $ProjectRoot
    $desktop = [Environment]::GetFolderPath('Desktop')

    $candidates = @(
        (Join-Path $ProjectRoot "installer\U-Panel-$Version-windows-setup.exe"),
        (Join-Path $ProjectRoot "installer\UPanelSetup.exe")
    )

    if ($desktop) {
        $candidates += @(
            (Join-Path $desktop "Output\UPanelSetup.exe"),
            (Join-Path $desktop "Output\U-Panel-$Version-windows-setup.exe"),
            (Join-Path $desktop "output\UPanelSetup.exe"),
            (Join-Path $desktop "output\U-Panel-$Version-windows-setup.exe")
        )
    }

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    foreach ($dir in $searchDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $latestExe = Get-ChildItem -LiteralPath $dir -Filter "*.exe" -File -ErrorAction SilentlyContinue |
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
        Copy-ReleaseBinary -Source $winSrc -Destination $winDst
    }
    $release.windows.available = $true
    $release.windows.size = Format-Size (Get-Item $winDst).Length
    Write-Host "Windows installer: $winDst"
} else {
    Write-Warning "Windows installer not found. Place UPanelSetup.exe in Desktop\Output (or installer\), or pass -WindowsInstaller path\to\setup.exe"
}

$jsonPath = Join-Path $website "releases.json"
$json = ($release | ConvertTo-Json -Depth 5)
# UTF-8 without BOM — a BOM breaks JSON.parse in browsers and disables all buttons.
[System.IO.File]::WriteAllText($jsonPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "Updated $jsonPath"
Write-Host "  Web app URL:       $webAppUrl"
Write-Host "  Landing page URL:  $siteDomain/"
Write-Host "  APK / Windows URL: $siteDomain/downloads/"
Write-Host "Publish: git add website && git commit && git push origin main"
