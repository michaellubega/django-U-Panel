# Post-process build/web before static hosting deploy:
# - legacy AssetManifest.json (cached old main.dart.js may still request it)
# - verify critical boot files exist (avoid SPA rewrite serving index.html as JS/JSON)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$webBuild = Join-Path $root "build\web"
$assetsDir = Join-Path $webBuild "assets"

if (-not (Test-Path (Join-Path $webBuild "index.html"))) {
    Write-Error "build/web not found. Run: flutter build web --release"
    exit 1
}

function Write-LegacyAssetManifest {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return }

    $rootPath = (Resolve-Path $Dir).Path
    $manifest = [ordered]@{}

    Get-ChildItem $Dir -Recurse -File | Where-Object {
        $base = $_.Name
        $base -notmatch '^AssetManifest' -and
            $base -ne 'FontManifest.json' -and
            $base -ne 'NOTICES'
    } | ForEach-Object {
        $rel = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
        $manifest[$rel] = @($rel)
    }

    $outPath = Join-Path $Dir "AssetManifest.json"
    $json = $manifest | ConvertTo-Json -Depth 4 -Compress
    [System.IO.File]::WriteAllText($outPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote legacy $outPath ($($manifest.Count) assets)"
}

Write-LegacyAssetManifest -Dir $assetsDir

# CanvasKit dart2js builds only need full + chromium variants; drop unused WASM (~20MB).
$canvaskitDir = Join-Path $webBuild "canvaskit"
if (Test-Path $canvaskitDir) {
    @(
        "skwasm.js", "skwasm.wasm", "skwasm.js.symbols",
        "skwasm_heavy.js", "skwasm_heavy.wasm", "skwasm_heavy.js.symbols",
        "wimp.js", "wimp.wasm", "wimp.js.symbols"
    ) | ForEach-Object {
        $p = Join-Path $canvaskitDir $_
        if (Test-Path $p) { Remove-Item $p -Force }
    }
    $experimental = Join-Path $canvaskitDir "experimental_webparagraph"
    if (Test-Path $experimental) {
        Remove-Item $experimental -Recurse -Force
    }
    Get-ChildItem $canvaskitDir -Recurse -Filter "*.symbols" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force
    Write-Host "Trimmed unused CanvasKit variants from build/web/canvaskit"
}

$required = @(
    "index.html",
    "main.dart.js",
    "flutter_bootstrap.js",
    "flutter.js",
    "flutter_service_worker.js",
    "manifest.json",
    "version.json",
    "android_web_gate.js",
    "upanel_brand.js",
    "assets\AssetManifest.bin.json",
    "assets\FontManifest.json",
    "assets\AssetManifest.json",
    "canvaskit\canvaskit.js"
)

$missing = @()
foreach ($rel in $required) {
    $path = Join-Path $webBuild $rel
    if (-not (Test-Path $path)) {
        $missing += $rel
    }
}

if ($missing.Count -gt 0) {
    Write-Error @"
build/web is incomplete — the host may serve index.html for missing files and the app would crash.

Missing:
  $($missing -join "`n  ")

Run: flutter build web --release
Then: .\scripts\finalize-web-build.ps1
"@
    exit 1
}

Write-Host "Web build verification passed."
