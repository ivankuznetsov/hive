# hivebox one-command install for Windows PowerShell:
#   irm https://hivecli.sh/box.ps1 | iex
# Same contract as install-box.sh: pull the published image, start the box
# with a persistent data directory, print the URL. Overridable via
# $env:HIVEBOX_IMAGE / _NAME / _PORT / _DATA.
$ErrorActionPreference = "Stop"

$Image = if ($env:HIVEBOX_IMAGE) { $env:HIVEBOX_IMAGE } else { "ghcr.io/ivankuznetsov/hivebox:latest" }
$Name  = if ($env:HIVEBOX_NAME)  { $env:HIVEBOX_NAME }  else { "hivebox" }
$Port  = if ($env:HIVEBOX_PORT)  { $env:HIVEBOX_PORT }  else { "4567" }
$Data  = if ($env:HIVEBOX_DATA)  { $env:HIVEBOX_DATA }  else { Join-Path $HOME "hivebox-data" }
# Localhost by default: a fresh box is claimable by its FIRST login — do
# not publish it to network peers before the owner signs in.
$Bind  = if ($env:HIVEBOX_BIND)  { $env:HIVEBOX_BIND }  else { "127.0.0.1" }

function Fail($Message) {
    # Write-Host, not Write-Error: error records emitted while `exit`
    # unwinds are droppable by the host and invisible to file/pipe capture.
    Write-Host "hivebox install: $Message"
    exit 1
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail "Docker is required. Install Docker Desktop (with the WSL 2 backend), then re-run."
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "Docker is installed but not running. Start Docker Desktop and re-run."
}

$existing = docker ps -a --format '{{.Names}}' | Where-Object { "$_".Trim() -eq $Name }
if ($existing) {
    Fail "a container named '$Name' already exists - 'docker start $Name' resumes it; remove it to reinstall."
}

New-Item -ItemType Directory -Force -Path $Data | Out-Null
docker pull $Image
if ($LASTEXITCODE -ne 0) { Fail "docker pull failed." }
docker run -d --name $Name --restart unless-stopped -p "${Bind}:${Port}:4567" -v "${Data}:/data" $Image | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "docker run failed." }

Write-Host ""
Write-Host "hivebox is running."
Write-Host ""
Write-Host "  Open:  http://localhost:$Port"
Write-Host "  Data:  $Data"
Write-Host ""
Write-Host "The first GitHub sign-in claims the box as its owner."
