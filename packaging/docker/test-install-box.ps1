# Exercises install-box.ps1 on real Windows PowerShell against a STUBBED
# docker CLI. Hosted Windows runners cannot run Linux containers (no WSL2 /
# nested virtualization), so the per-OS surface we CAN verify is our own
# script: quoting, $LASTEXITCODE handling, env overrides, failure copy.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $here "install-box.ps1"
$failures = 0

function Assert-Case($name, $ok, $detail) {
    if ($ok) {
        Write-Host "PASS $name"
    } else {
        Write-Host "FAIL $name`n$detail"
        $script:failures++
    }
}

function Invoke-Installer($extraPath, $stubLog) {
    $sysDirs = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
    # $PSHOME (read-only) holds the pwsh install dir; PS variable names are
    # case-insensitive, so the local must NOT be called $psHome.
    $psDir = $PSHOME
    $pathValue = if ($extraPath) { "$extraPath;$psDir;$sysDirs" } else { "$psDir;$sysDirs" }
    $out = & pwsh -NoProfile -Command "
        `$env:Path = '$pathValue'
        `$env:DOCKER_STUB_LOG = '$stubLog'
        `$env:HIVEBOX_DATA = Join-Path ([IO.Path]::GetTempPath()) ('hbdata-' + [guid]::NewGuid())
        & '$installer' 2>&1 | Out-String
        exit `$LASTEXITCODE
    "
    return @{ Output = ($out | Out-String); Code = $LASTEXITCODE }
}

# --- Case 1: docker present but unreachable → friendly failure, exit 1 -----
# (True PATH-absence is untestable on hosted runners: docker.exe is
# resolvable from system locations no PATH restriction can hide.)
$deadDir = Join-Path ([IO.Path]::GetTempPath()) ("deaddocker-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $deadDir | Out-Null
@'
@echo off
exit /b 1
'@ | Set-Content -Path (Join-Path $deadDir "docker.bat") -Encoding ascii
$r = Invoke-Installer $deadDir $null
Assert-Case "unreachable docker fails friendly" `
    (($r.Code -ne 0) -and ($r.Output -match "not reachable|not running")) `
    "exit=$($r.Code) output=$($r.Output)"

# --- Stub docker for the remaining cases -----------------------------------
$stubDir = Join-Path ([IO.Path]::GetTempPath()) ("dockerstub-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stubDir | Out-Null
$stubLog = Join-Path $stubDir "argv.log"
@'
@echo off
echo %* >> "%DOCKER_STUB_LOG%"
if "%1"=="info" exit /b 0
if "%1"=="ps" exit /b 0
if "%1"=="pull" exit /b 0
if "%1"=="run" ( echo deadbeef & exit /b 0 )
exit /b 0
'@ | Set-Content -Path (Join-Path $stubDir "docker.bat") -Encoding ascii

# --- Case 2: happy path drives pull + run and prints the URL ---------------
$r = Invoke-Installer $stubDir $stubLog
$argv = if (Test-Path $stubLog) { Get-Content $stubLog -Raw } else { "" }
Assert-Case "happy path runs the container and prints the URL" `
    (($r.Code -eq 0) -and ($r.Output -match "hivebox is running") -and
     ($argv -match "pull ghcr.io/ivankuznetsov/hivebox:latest") -and
     ($argv -match "run -d --name hivebox --restart unless-stopped -p 127.0.0.1:4567:4567 -v ") -and
     ($argv -match ":/data ghcr.io/ivankuznetsov/hivebox:latest")) `
    "exit=$($r.Code) output=$($r.Output) argv=$argv"

# --- Case 3: existing container name refuses with guidance -----------------
@'
@echo off
if "%1"=="info" exit /b 0
if "%1"=="ps" (
  echo hivebox
  exit /b 0
)
exit /b 0
'@ | Set-Content -Path (Join-Path $stubDir "docker.bat") -Encoding ascii
$r = Invoke-Installer $stubDir $null
Assert-Case "existing container refuses with resume guidance" `
    (($r.Code -ne 0) -and ($r.Output -match "already exists")) `
    "exit=$($r.Code) output=$($r.Output)"

if ($failures -gt 0) { exit 1 }
Write-Host "install-box.ps1: all cases green"
