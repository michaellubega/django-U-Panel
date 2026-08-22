# Copies KIU branding images from kiu/ into platform icon folders, web, and website.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$kiu = Join-Path $root "kiu"
if (-not (Test-Path (Join-Path $kiu "playstore.png"))) {
    Write-Error "kiu/playstore.png not found."
}

function Copy-IfExists {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) {
        Write-Warning "Skip missing: $Src"
        return
    }
    $dir = Split-Path $Dst -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Copy-Item $Src $Dst -Force
    Write-Host "  -> $Dst"
}

Write-Host "Android launcher mipmaps..."
$androidRes = Join-Path $root "android\app\src\main\res"
Get-ChildItem (Join-Path $kiu "android") -Directory -Filter "mipmap-*" | ForEach-Object {
    $dest = Join-Path $androidRes $_.Name
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $_.FullName "ic_launcher.png") (Join-Path $dest "ic_launcher.png") -Force
    Write-Host "  -> $dest\ic_launcher.png"
}

Write-Host "iOS AppIcon.appiconset..."
$iosIconDir = Join-Path $root "ios\Runner\Assets.xcassets\AppIcon.appiconset"
$kiuIconDir = Join-Path $kiu "Assets.xcassets\AppIcon.appiconset"
New-Item -ItemType Directory -Force -Path $iosIconDir | Out-Null
Get-ChildItem (Join-Path $kiuIconDir "_") -Filter "*.png" | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $iosIconDir $_.Name) -Force
}
$contentsPath = Join-Path $iosIconDir "Contents.json"
Copy-Item (Join-Path $kiuIconDir "Contents.json") $contentsPath -Force
$contents = Get-Content $contentsPath -Raw | ConvertFrom-Json
if (-not $contents.info) {
    $contents | Add-Member -NotePropertyName info -NotePropertyValue ([ordered]@{
        version = 1
        author  = "xcode"
    })
    ($contents | ConvertTo-Json -Depth 20) | Set-Content $contentsPath -Encoding UTF8
}
Write-Host "  -> $iosIconDir"

Write-Host "Web PWA icons..."
$webIcons = Join-Path $root "web\icons"
New-Item -ItemType Directory -Force -Path $webIcons | Out-Null
$icon192 = Join-Path $kiuIconDir "_\196.png"
if (-not (Test-Path $icon192)) { $icon192 = Join-Path $kiuIconDir "_\180.png" }
Copy-IfExists $icon192 (Join-Path $webIcons "Icon-192.png")
Copy-IfExists $icon192 (Join-Path $webIcons "Icon-maskable-192.png")
Copy-IfExists (Join-Path $kiu "playstore.png") (Join-Path $webIcons "Icon-512.png")
Copy-IfExists (Join-Path $kiu "playstore.png") (Join-Path $webIcons "Icon-maskable-512.png")
Copy-IfExists (Join-Path $kiuIconDir "_\48.png") (Join-Path $root "web\favicon.png")

Write-Host "Website landing icon..."
$websiteAssets = Join-Path $root "website\assets"
New-Item -ItemType Directory -Force -Path $websiteAssets | Out-Null
Copy-IfExists (Join-Path $kiu "playstore.png") (Join-Path $websiteAssets "icon.png")

Write-Host "Windows app_icon.ico..."
$winIconConfig = Join-Path $root "tool\flutter_launcher_icons_windows.yaml"
if (-not (Test-Path $winIconConfig)) {
    Write-Error "tool/flutter_launcher_icons_windows.yaml not found."
}
dart run flutter_launcher_icons -f $winIconConfig
if ($LASTEXITCODE -ne 0) {
    Write-Error "flutter_launcher_icons failed for Windows."
}
Write-Host "  -> windows\runner\resources\app_icon.ico"

Write-Host "KIU branding sync complete."
