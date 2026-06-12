#!/bin/sh
# hivebox one-command install: pull the published image, start the box,
# print the URL. The whole box state lives in one directory — back it up
# and you have backed up everything. Designed to be served as
# https://hivecli.sh/box and piped to sh; every variable is overridable.
set -eu

IMAGE="${HIVEBOX_IMAGE:-ghcr.io/ivankuznetsov/hivebox:latest}"
NAME="${HIVEBOX_NAME:-hivebox}"
PORT="${HIVEBOX_PORT:-4567}"
DATA="${HIVEBOX_DATA:-$HOME/hivebox-data}"

die() {
  printf 'hivebox install: %s\n' "$1" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 ||
  die "Docker is required. Install Docker Desktop (macOS/Windows) or docker-ce (Linux), then re-run."
docker info >/dev/null 2>&1 ||
  die "Docker is installed but not reachable (daemon stopped, or this user needs the docker group). Start it and re-run."

if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  die "a container named '$NAME' already exists — 'docker start $NAME' resumes it; remove it to reinstall."
fi

mkdir -p "$DATA"
docker pull "$IMAGE"
docker run -d --name "$NAME" --restart unless-stopped \
  -p "${PORT}:4567" -v "${DATA}:/data" "$IMAGE" >/dev/null

printf '\nhivebox is running.\n\n'
printf '  Open:  http://localhost:%s\n' "$PORT"
printf '  Data:  %s\n\n' "$DATA"
printf 'The first GitHub sign-in claims the box as its owner.\n'
