# Adds the release keystore SHA-256 fingerprint to web/.well-known/assetlinks.json.
# Run after configuring android/key.properties (release signing).

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$keyProps = Join-Path $root "android\key.properties"
$assetLinks = Join-Path $root "web\.well-known\assetlinks.json"

if (-not (Test-Path $keyProps)) {
    Write-Warning "android/key.properties not found - assetlinks.json keeps existing fingerprints only."
    exit 0
}

$props = @{}
Get-Content $keyProps | ForEach-Object {
    if ($_ -match '^\s*([^#=]+?)\s*=\s*(.+?)\s*$') {
        $props[$Matches[1].Trim()] = $Matches[2].Trim()
    }
}

$storeFile = $props["storeFile"]
$keyAlias = $props["keyAlias"]
$storePassword = $props["storePassword"]

if (-not $storeFile -or -not $keyAlias -or -not $storePassword) {
    Write-Warning "key.properties missing storeFile, keyAlias, or storePassword."
    exit 0
}

$candidates = @(
    (Join-Path $root "android\app\$storeFile"),
    (Join-Path $root "android\$storeFile"),
    (Join-Path $root $storeFile)
)
$storePath = $null
foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
        $storePath = $candidate
        break
    }
}
if (-not $storePath) {
    Write-Warning "Keystore not found: $storeFile"
    exit 0
}

$keytool = Get-Command keytool -ErrorAction SilentlyContinue
if (-not $keytool) {
    Write-Warning "keytool not found on PATH."
    exit 0
}

$keyPassword = $props["keyPassword"]
if (-not $keyPassword) { $keyPassword = $storePassword }

$out = & keytool -list -v -keystore $storePath -alias $keyAlias -storepass $storePassword -keypass $keyPassword 2>&1
$shaLine = $out | Select-String -Pattern "SHA256:\s*(.+)" | Select-Object -First 1
if (-not $shaLine) {
    Write-Warning "Could not read SHA256 from keystore."
    exit 0
}

$sha256 = ($shaLine.Matches[0].Groups[1].Value.Trim().ToUpper())
$jsonText = Get-Content $assetLinks -Raw
$json = $jsonText | ConvertFrom-Json
$fps = [System.Collections.Generic.List[string]]@($json[0].target.sha256_cert_fingerprints)
if ($fps -notcontains $sha256) {
    $fps.Add($sha256)
    $json[0].target.sha256_cert_fingerprints = $fps.ToArray()

    $formatted = @(
        "[",
        "  {",
        '    "relation": [',
        '      "delegate_permission/common.handle_all_urls",',
        '      "delegate_permission/common.get_related_apps",',
        '      "delegate_permission/common.get_login_creds"',
        "    ],",
        '    "target": {',
        '      "namespace": "android_app",',
        '      "package_name": "com.u_panel",',
        '      "sha256_cert_fingerprints": ['
    )
    foreach ($fp in $fps) {
        $formatted += "        `"$fp`","
    }
    if ($formatted[-1].EndsWith(",")) {
        $formatted[-1] = $formatted[-1].TrimEnd(",")
    }
    $formatted += @(
        "      ]",
        "    }",
        "  }",
        "]",
        ""
    )
    [System.IO.File]::WriteAllText($assetLinks, ($formatted -join "`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Added release SHA256 to assetlinks.json: $sha256"
} else {
    Write-Host "Release SHA256 already present in assetlinks.json."
}
