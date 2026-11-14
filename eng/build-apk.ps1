#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the CloudBox Android APK and stages it in dist/.

.DESCRIPTION
    Runs `flutter build apk --release` and copies the result to
    dist/cloudbox-<version>.apk, so release artifacts share one naming scheme with the
    Windows installer.

    Requires the Flutter SDK and the Android SDK on PATH (plus JAVA_HOME for Gradle).

.EXAMPLE
    pwsh eng/build-apk.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$version  = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
$appDir   = Join-Path $repoRoot 'app'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'flutter not found on PATH.'
}

Push-Location $appDir
try {
    & flutter build apk --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}

$built = Join-Path $appDir 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path -LiteralPath $built)) {
    throw "expected APK at $built"
}

$dist = Join-Path $repoRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$target = Join-Path $dist "cloudbox-$version.apk"
Copy-Item -LiteralPath $built -Destination $target -Force

$sizeMB = [math]::Round((Get-Item -LiteralPath $target).Length / 1MB, 2)
Write-Host "CloudBox $version"
Write-Host "  apk  $target ($sizeMB MB)"
