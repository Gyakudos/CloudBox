#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the Windows installer for the CloudBox PC agent.

.DESCRIPTION
    Cross-compiles the agent for windows/amd64, stamps the build identity, then runs Inno
    Setup 6 to produce dist/cloudbox-setup-<version>.exe.

    Inno Setup 6 must be installed (https://jrsoftware.org/isdl.php). ISCC.exe is looked up in
    the usual per-user and per-machine locations; override with -Iscc.

.PARAMETER Iscc
    Explicit path to ISCC.exe.

.PARAMETER SkipAgent
    Reuse an existing agent/dist/cloudbox.exe instead of rebuilding it.

.EXAMPLE
    pwsh eng/build-installer.ps1

.EXAMPLE
    pwsh eng/build-installer.ps1 -SkipAgent -Iscc "C:\tools\Inno Setup 6\ISCC.exe"
#>
[CmdletBinding()]
param(
    [string]$Iscc,
    [switch]$SkipAgent
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$version  = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
$module   = 'github.com/Gyakudos/CloudBox/agent'

# ------------------------------------------------------------------- locate Inno Setup
if (-not $Iscc) {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    $Iscc = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if (-not $Iscc -or -not (Test-Path -LiteralPath $Iscc)) {
    throw "ISCC.exe (Inno Setup 6) not found. Install it, or pass -Iscc <path>."
}

# ------------------------------------------------------------------- build the agent
$agentDir = Join-Path $repoRoot 'agent'
$exePath  = Join-Path $agentDir 'dist\cloudbox.exe'

if (-not $SkipAgent) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $exePath) | Out-Null

    $commit = (git -C $repoRoot rev-parse --short HEAD 2>$null)
    if (-not $commit) { $commit = 'unknown' }
    $buildDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $ldflags = @(
        '-s', '-w',
        '-X', "$module/internal/version.Version=$version",
        '-X', "$module/internal/version.Commit=$commit",
        '-X', "$module/internal/version.BuildDate=$buildDate"
    ) -join ' '

    Write-Host "building agent $version ($commit) for windows/amd64"
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    Push-Location $agentDir
    try {
        & go build -trimpath -ldflags $ldflags -o $exePath ./cmd/cloudbox
        if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
        Remove-Item Env:CGO_ENABLED, Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $exePath)) {
    throw "agent binary not found at $exePath (drop -SkipAgent to build it)"
}

# ------------------------------------------------------------------- compile installer
$iss = Join-Path $repoRoot 'installer\cloudbox.iss'
Write-Host "running Inno Setup: $Iscc"
& $Iscc "/DVersion=$version" $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$output = Join-Path $repoRoot "dist\cloudbox-setup-$version.exe"
if (-not (Test-Path -LiteralPath $output)) {
    throw "expected installer at $output"
}

$sizeMB = [math]::Round((Get-Item -LiteralPath $output).Length / 1MB, 2)
Write-Host ""
Write-Host "CloudBox $version"
Write-Host "  installer  $output ($sizeMB MB)"
