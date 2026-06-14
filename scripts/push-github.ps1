# Stage, commit, and push U-Panel changes to GitHub (origin).
#
# Usage:
#   .\scripts\push-github.ps1 -Message "Fix offline check-in roll labels."
#   .\scripts\push-github.ps1 -Message "Ship attendance sync fixes." -All
#   .\scripts\push-github.ps1 -StatusOnly
#   .\scripts\push-github.ps1 -Message "WIP" -DryRun -All
#
# Options:
#   -Message       Commit message (required unless -StatusOnly)
#   -All           Stage all tracked + untracked changes before commit
#   -DryRun        Show what would happen; no commit or push
#   -SkipPush      Commit locally but do not push
#   -NoPull        Skip fetch / rebase before push
#   -Branch        Push branch (default: current branch)
#   -SetupHooks    Set core.hooksPath to .githooks (strips Cursor co-author trailers)
#   -AllowSecrets  Skip warnings for files that look like credentials

param(
    [string]$Message = "",
    [switch]$All,
    [switch]$DryRun,
    [switch]$SkipPush,
    [switch]$NoPull,
    [string]$Branch = "",
    [switch]$SetupHooks,
    [switch]$AllowSecrets,
    [switch]$StatusOnly
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Command)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git @Command 2>&1
        if ($LASTEXITCODE -ne 0) {
            if ($output) { $output | ForEach-Object { Write-Host $_ } }
            throw "git $($Command -join ' ') failed (exit $LASTEXITCODE)"
        }
        return $output
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Test-SecretPath([string]$Path) {
    $normalized = $Path -replace '\\', '/'
    $patterns = @(
        '\.env(\.|$)',
        'credentials\.json$',
        'google-services\.json$',
        'GoogleService-Info\.plist$',
        'key\.properties$',
        '\.jks$',
        '\.p12$',
        '\.pem$',
        'serviceAccount.*\.json$',
        'firebase-adminsdk.*\.json$'
    )
    foreach ($p in $patterns) {
        if ($normalized -match $p) { return $true }
    }
    return $false
}

if (-not (Test-Path (Join-Path $root ".git"))) {
    throw "Not a git repository: $root"
}

if ($SetupHooks) {
    Write-Step "Configuring git hooks (.githooks)"
    Invoke-Git -Command @('config', 'core.hooksPath', '.githooks')
    Write-Host "Hooks path set to .githooks"
}

$currentBranch = (Invoke-Git -Command @('branch', '--show-current')).Trim()
if ($Branch -eq "") { $Branch = $currentBranch }

Write-Step "Repository: $root"
Write-Host "Branch: $currentBranch"
$remoteUrl = (Invoke-Git -Command @('remote', 'get-url', 'origin'))
if ($remoteUrl) {
    Write-Host "Remote: origin -> $remoteUrl"
} else {
    throw "No 'origin' remote configured. Add one with: git remote add origin <url>"
}

Write-Step "Working tree status"
Invoke-Git -Command @('status', '-sb') | ForEach-Object { Write-Host $_ }

if ($StatusOnly) { exit 0 }

if ($Message.Trim() -eq "") {
    throw "Commit message required. Pass -Message `"Your summary.`" or use -StatusOnly."
}

$secretCandidates = @()
foreach ($line in (Invoke-Git -Command @('status', '--porcelain'))) {
    if ($line.Length -lt 4) { continue }
    $path = $line.Substring(3).Trim('"')
    if ($path -match ' -> ') {
        $path = ($path -split ' -> ', 2)[1].Trim('"')
    }
    if (Test-SecretPath $path) { $secretCandidates += $path }
}
if ($secretCandidates.Count -gt 0 -and -not $AllowSecrets) {
    Write-Host ""
    Write-Host "Possible secret/credential files detected:" -ForegroundColor Yellow
    $secretCandidates | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    throw "Refusing to continue. Remove these from the commit or pass -AllowSecrets if intentional."
}

if ($All) {
    Write-Step "Staging all changes (git add -A)"
    if ($DryRun) {
        Write-Host "[dry-run] git add -A"
    } else {
        Invoke-Git -Command @('add', '-A')
    }
}

$staged = Invoke-Git -Command @('diff', '--cached', '--name-only')
if (-not $staged -and -not $DryRun) {
    throw "Nothing staged. Stage files manually or re-run with -All."
}

if ($staged) {
    Write-Step "Staged files"
    $staged | ForEach-Object { Write-Host "  $_" }

    $large = @()
    foreach ($f in $staged) {
        $full = Join-Path $root $f
        if ((Test-Path $full) -and -not (Test-Path $full -PathType Container)) {
            $len = (Get-Item $full).Length
            if ($len -ge 50MB) { $large += "$f ($([math]::Round($len / 1MB, 1)) MB)" }
        }
    }
    if ($large.Count -gt 0) {
        Write-Host ""
        Write-Host "Large staged files (>50 MB):" -ForegroundColor Yellow
        $large | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }
}

Write-Step "Commit"
Write-Host $Message
if ($DryRun) {
    Write-Host "[dry-run] git commit -m <message>"
} else {
    Invoke-Git -Command @('commit', '-m', $Message)
}

if ($SkipPush) {
    Write-Host ""
    Write-Host "Committed locally (-SkipPush). Push when ready with: git push origin $Branch"
    exit 0
}

if (-not $NoPull) {
    Write-Step "Fetching origin"
    if ($DryRun) {
        Write-Host "[dry-run] git fetch origin"
        Write-Host "[dry-run] git rebase origin/$Branch (if behind)"
    } else {
        Invoke-Git -Command @('fetch', 'origin')
        $upstream = "origin/$Branch"
        $behind = Invoke-Git -Command @('rev-list', '--count', "$Branch..$upstream")
        if ($behind -and [int]$behind -gt 0) {
            Write-Host "Branch is $behind commit(s) behind $upstream. Rebasing..."
            Invoke-Git -Command @('rebase', $upstream)
        }
    }
}

Write-Step "Pushing to origin/$Branch"
if ($DryRun) {
    Write-Host "[dry-run] git push -u origin $Branch"
} else {
    Invoke-Git -Command @('push', '-u', 'origin', $Branch)
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
if ($remoteUrl -match 'github\.com[:/](.+?)(\.git)?$') {
    $repo = $Matches[1]
    Write-Host "Repo: https://github.com/$repo"
}
