#!/bin/sh
# hivebox image smoke: boot the container fresh, assert the golden-path
# front door (health, claimable login, owner gate), shut down clean.
# Usage: smoke.sh <image-ref>   (used by CI pre-push, release post-publish,
# and the macOS verification job — keep it POSIX, docker-cli-only).
set -eu

IMAGE="${1:?usage: smoke.sh <image-ref>}"
NAME="hivebox-smoke-$$"

# Random host port: parallel-safe on shared runners and dev machines that
# already run a hivebox on 4567.
docker run -d --name "$NAME" -p 127.0.0.1::4567 "$IMAGE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
PORT="$(docker port "$NAME" 4567/tcp | head -1 | sed 's/.*://')"

i=0
until curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then
    echo "FAIL /health never came up"
    docker logs "$NAME" 2>&1 | tail -50
    exit 1
  fi
  sleep 1
done

# A fresh box must be CLAIMABLE out of the box (shipped client_id default):
# this single assertion proves config defaults, the web tier, and the claim
# flow all survived the image build.
body="$(curl -fsS "http://127.0.0.1:${PORT}/login")"
case "$body" in
  *"first GitHub sign-in becomes its owner"*) ;;
  *)
    echo "FAIL login page is not claimable"
    printf '%s\n' "$body" | head -30
    exit 1
    ;;
esac

# Everything else is owner-gated.
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/")"
if [ "$code" != "302" ]; then
  echo "FAIL unauthenticated / expected 302, got $code"
  exit 1
fi

echo "PASS hivebox image smoke ($IMAGE)"
