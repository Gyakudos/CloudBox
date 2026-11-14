#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end smoke test for the agent: boot it, pair, list volumes, shut down.

.DESCRIPTION
    Exercises the real HTTPS server rather than an in-process handler: TLS listener, identity
    creation on a fresh data directory, the pairing handshake with a real token, and an
    authenticated volume listing. Certificate trust is bypassed with curl -k here because pin
    verification is covered by unit tests (identity package).

    Exits 0 on success, 1 on any failed assertion. The server process and temp data directory
    are always cleaned up.
#>
[CmdletBinding()]
param(
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$agentDir = Join-Path $repoRoot 'agent'
$binary = Join-Path $agentDir 'bin/cloudbox.exe'
$stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$dataDir = Join-Path $env:TEMP "cloudbox-smoke-$stamp"
$outLog = Join-Path $env:TEMP "cloudbox-smoke-$stamp.out.log"
$errLog = Join-Path $env:TEMP "cloudbox-smoke-$stamp.err.log"
$process = $null

function Fail([string]$message) {
    throw "SMOKE FAILED: $message"
}

try {
    # ---------------------------------------------------------------- build
    Push-Location $agentDir
    & go build -o $binary ./cmd/cloudbox
    if ($LASTEXITCODE -ne 0) { Fail "go build exited $LASTEXITCODE" }
    Pop-Location

    $version = (& $binary version) -join ' '
    Write-Host "agent: $version"

    # ---------------------------------------------------------------- port
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()

    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

    # ---------------------------------------------------------------- boot
    $syncRoot = Join-Path $dataDir 'syncroot'
    New-Item -ItemType Directory -Force -Path $syncRoot | Out-Null

    $process = Start-Process -FilePath $binary `
        -ArgumentList @('serve', '--addr', "127.0.0.1:$port", '--dir', $dataDir, '--name', 'SMOKE', '--sync-root', $syncRoot) `
        -PassThru `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog

    $base = "https://127.0.0.1:$port"
    $health = $null
    for ($attempt = 1; $attempt -le 100; $attempt++) {
        Start-Sleep -Milliseconds 100
        if ($process.HasExited) { Fail "agent exited early (code $($process.ExitCode)); see $errLog" }
        $raw = & curl.exe -sk --max-time 1 "$base/healthz"
        if ($LASTEXITCODE -eq 0 -and ($raw -join '') -match '"status":\s*"ok"') {
            $health = ($raw -join "`n") | ConvertFrom-Json
            break
        }
    }
    if (-not $health) { Fail "health endpoint never became ready on $base" }
    Write-Host "health:  status=$($health.status) version=$($health.version) server=$($health.server_id)"
    if ($health.version -ne (($version -split ' ')[1])) {
        Fail "health version $($health.version) does not match binary version"
    }

    # ---------------------------------------------------------------- auth gate
    $unauthRaw = & curl.exe -sk --max-time 5 "$base/v1/system/volumes"
    if (($unauthRaw -join '') -notmatch 'UNAUTHORIZED') {
        Fail "volumes endpoint did not reject an unauthenticated request"
    }

    # ---------------------------------------------------------------- pair
    $payloadPath = Join-Path $dataDir 'pairing.json'
    if (-not (Test-Path $payloadPath)) { Fail "pairing.json was not written to $dataDir" }
    $payload = Get-Content -Path $payloadPath -Raw | ConvertFrom-Json
    if (-not $payload.tok) { Fail "pairing payload has no token" }
    if (-not $payload.pin) { Fail "pairing payload has no pin" }
    if (-not ($payload.eps -contains "127.0.0.1:$port")) {
        Fail "pairing endpoints do not include loopback: $($payload.eps -join ', ')"
    }

    $pairBody = @{
        token       = $payload.tok
        device_name = 'SmokePhone'
        platform    = 'android'
        app_version = 'smoke'
    } | ConvertTo-Json -Compress

    # Write the body to a file: PowerShell 5.1 mangles double quotes when inlining JSON as a
    # native-command argument, which silently produces invalid JSON.
    $pairBodyPath = Join-Path $dataDir 'pair-request.json'
    Set-Content -Path $pairBodyPath -Value $pairBody -Encoding ascii -NoNewline

    $pairRaw = & curl.exe -sk --max-time 5 -X POST -H 'Content-Type: application/json' --data-binary "@$pairBodyPath" "$base/v1/pair"
    $paired = ($pairRaw -join "`n") | ConvertFrom-Json
    if (-not $paired.device_token) { Fail "pair did not return a device token: $($pairRaw -join ' ')" }
    Write-Host "paired:  device=$($paired.device_id) server=$($paired.server_name)"

    # ---------------------------------------------------------------- replay
    $replayRaw = & curl.exe -sk --max-time 5 -X POST -H 'Content-Type: application/json' --data-binary "@$pairBodyPath" "$base/v1/pair"
    if (($replayRaw -join '') -notmatch 'INVALID_PAIRING_TOKEN') {
        Fail "pairing token was accepted twice"
    }
    Write-Host "replay:  correctly rejected"

    # ---------------------------------------------------------------- volumes
    $volRaw = & curl.exe -sk --max-time 5 -H "Authorization: Bearer $($paired.device_token)" "$base/v1/system/volumes"
    $volumes = (($volRaw -join "`n") | ConvertFrom-Json).volumes
    if (-not $volumes) { Fail "no volumes returned" }
    Write-Host "volumes: $($volumes.Count) found"
    foreach ($vol in $volumes) {
        $freeGB = [math]::Round($vol.free_bytes / 1GB, 1)
        $totalGB = [math]::Round($vol.total_bytes / 1GB, 1)
        Write-Host ("         {0,-4} {1,-12} {2,-7} {3} GB free of {4} GB" -f $vol.name, $vol.label, $vol.fs_type, $freeGB, $totalGB)
    }

    # ---------------------------------------------------------------- QR image
    $qrPath = Join-Path $dataDir 'pairing.png'
    if (-not (Test-Path $qrPath)) { Fail "pairing.png was not written" }
    $qrBytes = [IO.File]::ReadAllBytes($qrPath)
    $qrMagic = [BitConverter]::ToString($qrBytes[0..7])
    if ($qrMagic -ne '89-50-4E-47-0D-0A-1A-0A') { Fail "pairing.png is not a PNG (magic $qrMagic)" }
    Write-Host "qr:      $($qrBytes.Length) byte PNG written"

    # ---------------------------------------------------------------- upload
    $auth = "Authorization: Bearer $($paired.device_token)"
    $contentPath = Join-Path $dataDir 'hello.txt'
    $content = 'hello from the smoke test'
    Set-Content -Path $contentPath -Value $content -Encoding ascii -NoNewline
    $size = (Get-Item $contentPath).Length
    $hash = (& $binary hash $contentPath) -join ''

    $createBody = @{ hash = $hash; size = $size; folder_id = 'default' } | ConvertTo-Json -Compress
    $createBodyPath = Join-Path $dataDir 'create-upload.json'
    Set-Content -Path $createBodyPath -Value $createBody -Encoding ascii -NoNewline

    $createRaw = & curl.exe -sk --max-time 5 -X POST -H $auth -H 'Content-Type: application/json' --data-binary "@$createBodyPath" "$base/v1/uploads"
    $created = ($createRaw -join "`n") | ConvertFrom-Json
    if (-not $created.upload_id) { Fail "upload create failed: $($createRaw -join ' ')" }
    Write-Host "upload:  created $($created.upload_id) for $size bytes"

    # Send the bytes, then a deliberately wrong range to prove the resume hint works.
    $patchRaw = & curl.exe -sk --max-time 5 -X PATCH -H $auth -H "Content-Range: bytes 0-$($size - 1)/$size" --data-binary "@$contentPath" "$base/v1/uploads/$($created.upload_id)"
    $patched = ($patchRaw -join "`n") | ConvertFrom-Json
    if ($patched.offset -ne $size) { Fail "append offset = $($patched.offset), want $size" }

    $conflictRaw = & curl.exe -sk --max-time 5 -X PATCH -H $auth -H "Content-Range: bytes 0-0/$size" --data-binary "@$contentPath" "$base/v1/uploads/$($created.upload_id)"
    if (($conflictRaw -join '') -notmatch 'OFFSET_MISMATCH') {
        Fail "out-of-order append was not rejected"
    }
    Write-Host "resume:  out-of-order append correctly rejected"

    $mtimeMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $commitBody = @{ hash = $hash; path = 'DCIM/Smoke/hello.txt'; mtime_ms = $mtimeMs } | ConvertTo-Json -Compress
    $commitBodyPath = Join-Path $dataDir 'commit-upload.json'
    Set-Content -Path $commitBodyPath -Value $commitBody -Encoding ascii -NoNewline

    $commitRaw = & curl.exe -sk --max-time 5 -X POST -H $auth -H 'Content-Type: application/json' --data-binary "@$commitBodyPath" "$base/v1/uploads/$($created.upload_id)/commit"
    $committed = ($commitRaw -join "`n") | ConvertFrom-Json
    if (-not $committed.committed) { Fail "commit failed: $($commitRaw -join ' ')" }

    $landed = Join-Path $syncRoot 'DCIM\Smoke\hello.txt'
    if (-not (Test-Path $landed)) { Fail "committed file did not land at $landed" }
    if ((Get-Content $landed -Raw) -ne $content) { Fail "committed file contents differ" }
    Write-Host "commit:  $($committed.path) written to the sync folder"

    # Same bytes again: the server should dedupe and skip the transfer entirely.
    $dedupeRaw = & curl.exe -sk --max-time 5 -X POST -H $auth -H 'Content-Type: application/json' --data-binary "@$createBodyPath" "$base/v1/uploads"
    $deduped = ($dedupeRaw -join "`n") | ConvertFrom-Json
    if (-not $deduped.complete) { Fail "re-upload of identical content was not deduped" }
    Write-Host "dedupe:  identical content recognised, zero bytes re-sent"

    Write-Host ""
    Write-Host "SMOKE OK" -ForegroundColor Green
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if (Test-Path $errLog) {
        Write-Host "--- agent stderr ---" -ForegroundColor Yellow
        Get-Content $errLog | Select-Object -Last 20
    }
    exit 1
}
finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
    if (-not $KeepTemp) {
        Remove-Item -Recurse -Force $dataDir -ErrorAction SilentlyContinue
        Remove-Item -Force $outLog, $errLog -ErrorAction SilentlyContinue
    } else {
        Write-Host "kept temp data: $dataDir"
    }
}
