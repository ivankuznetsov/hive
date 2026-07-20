#!/bin/sh
# hivebox image smoke: boot the container fresh, assert the golden-path
# front door (health, claimable login, owner gate), shut down clean.
# Usage: smoke.sh <image-ref>   (used by CI pre-push, release post-publish,
# and the macOS verification job — keep it POSIX, docker-cli-only).
set -eu

IMAGE="${1:?usage: smoke.sh <image-ref>}"
NAME="hivebox-smoke-$$"
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=10

smoke_curl() {
  curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$@"
}

# Random host port: parallel-safe on shared runners and dev machines that
# already run a hivebox on 4567.
docker run -d --name "$NAME" -p 127.0.0.1::4567 "$IMAGE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
PORT="$(docker port "$NAME" 4567/tcp | head -1 | sed 's/.*://')"

i=0
health_deadline=$(($(date +%s) + 120))
until smoke_curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 120 ] || [ "$(date +%s)" -ge "$health_deadline" ]; then
    echo "FAIL /health never came up"
    docker logs "$NAME" 2>&1 | tail -50
    exit 1
  fi
  sleep 1
done

# Rails liveness is insufficient for the golden-path appliance: the web
# supervisor may still be crashlooping its daemon child because the installed
# hive-cli bundle is incomplete. Wait for the same deep contract used by the
# runtime HEALTHCHECK so an image cannot be published with a healthy front
# door and a dead pipeline. Eleven consecutive one-second probes span the
# supervisor's ten-second fast-failure window; one transient success from a
# crashlooping daemon is not enough.
i=0
stable_deep_health=0
deep_health_deadline=$(($(date +%s) + 120))
while [ "$stable_deep_health" -lt 11 ]; do
  if smoke_curl -fsS "http://127.0.0.1:${PORT}/health?deep=1" >/dev/null 2>&1; then
    stable_deep_health=$((stable_deep_health + 1))
  else
    stable_deep_health=0
  fi
  i=$((i + 1))
  if [ "$i" -gt 120 ] || [ "$(date +%s)" -ge "$deep_health_deadline" ]; then
    echo "FAIL /health?deep=1 never stayed healthy"
    docker logs "$NAME" 2>&1 | tail -50
    exit 1
  fi
  [ "$stable_deep_health" -ge 11 ] || sleep 1
done

# A fresh box must be CLAIMABLE out of the box (shipped client_id default):
# this single assertion proves config defaults, the web tier, and the claim
# flow all survived the image build.
body="$(smoke_curl -fsS "http://127.0.0.1:${PORT}/login")"
case "$body" in
  *"first GitHub sign-in becomes its owner"*) ;;
  *)
    echo "FAIL login page is not claimable"
    printf '%s\n' "$body" | head -30
    exit 1
    ;;
esac

# A rendered page is not a usable UI when its Propshaft manifest points at
# files missing from the image. Require the entrypoints, then fetch every
# digest-stamped stylesheet/module advertised by Rails so the smoke exercises
# the same initial asset graph as a browser.
stylesheet_path="$(printf '%s\n' "$body" | sed -n 's/.*<link rel="stylesheet" href="\([^"]*\)".*/\1/p' | head -1)"
javascript_path="$(printf '%s\n' "$body" | sed -n 's/.*<link rel="modulepreload" href="\([^"]*application-[^"]*\.js\)".*/\1/p' | head -1)"
case "$stylesheet_path:$javascript_path" in
  /assets/*.css:/assets/*.js) ;;
  *)
    echo "FAIL login page did not advertise compiled CSS and JavaScript"
    exit 1
    ;;
esac
asset_paths="$(printf '%s\n' "$body" | sed -n \
  -e 's/.*href="\([^"]*\/assets\/[^"]*\.css\)".*/\1/p' \
  -e 's/.*href="\([^"]*\/assets\/[^"]*\.js\)".*/\1/p' \
  -e 's/.*src="\([^"]*\/assets\/[^"]*\.js\)".*/\1/p' | sort -u)"
for asset_path in $asset_paths; do
  case "$asset_path" in
    /assets/*.css|/assets/*.js) ;;
    *)
      echo "FAIL login page advertised an unexpected asset path: $asset_path"
      exit 1
      ;;
  esac
  smoke_curl -fsS "http://127.0.0.1:${PORT}${asset_path}" >/dev/null
done

# Exercise the exact managed-install readiness predicate against the real
# Propshaft manifest produced by this image build. Unit fixtures alone cannot
# protect the release from a manifest-format drift.
docker exec "$NAME" ruby -rhive/web/app_bundle -e \
  'abort "managed web asset manifest is not ready" unless Hive::Web::AppBundle.assets_ready?("/app/web")'

# Everything else is owner-gated.
code="$(smoke_curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/")"
if [ "$code" != "302" ]; then
  echo "FAIL unauthenticated / expected 302, got $code"
  exit 1
fi

# Recheck after exercising the front door so a daemon death during the browser
# boundary assertions cannot slip between the stable window and publication.
if ! smoke_curl -fsS "http://127.0.0.1:${PORT}/health?deep=1" >/dev/null 2>&1; then
  echo "FAIL /health?deep=1 regressed after front-door checks"
  docker logs "$NAME" 2>&1 | tail -50
  exit 1
fi

echo "PASS hivebox image smoke ($IMAGE)"
