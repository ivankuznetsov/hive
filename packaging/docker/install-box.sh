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
# Localhost by default: a fresh box is CLAIMABLE — its first GitHub login
# becomes the owner — so it must not be reachable by network peers before
# the intended owner has signed in. Set HIVEBOX_BIND=0.0.0.0 to expose it
# AFTER claiming (or front it with a tunnel/proxy).
BIND="${HIVEBOX_BIND:-127.0.0.1}"

die() {
  printf 'hivebox install: %s\n' "$1" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 ||
  die "Docker is required. Install Docker Desktop (macOS/Windows) or docker-ce (Linux), then re-run."
docker info >/dev/null 2>&1 ||
  die "Docker is installed but not reachable (daemon stopped, or this user needs the docker group). Start it and re-run."

if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  printf 'hivebox install: a container named %s already exists.\n\n' "$NAME" >&2
  printf '  Resume it:        docker start %s\n' "$NAME" >&2
  printf '  Update to latest: docker pull %s && docker rm -f %s && re-run this script\n' "$IMAGE" "$NAME" >&2
  printf '                    (state lives in your data directory and survives the swap)\n' >&2
  exit 1
fi

mkdir -p "$DATA"
docker pull "$IMAGE"
docker run -d --name "$NAME" --restart unless-stopped \
  -p "${BIND}:${PORT}:4567" -v "${DATA}:/data" "$IMAGE" >/dev/null

printf '\nhivebox is running.\n\n'
printf '  Open:  http://localhost:%s\n' "$PORT"
printf '  Data:  %s\n\n' "$DATA"
printf 'The first GitHub sign-in claims the box as its owner.\n'
