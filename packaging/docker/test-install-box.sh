#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="$script_dir/install-box.sh"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

fake_bin="$fixture_root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/docker" <<'SH'
#!/usr/bin/env sh
set -eu
printf '%s\n' "$*" >>"$DOCKER_STUB_LOG"
case "$1" in
  info|pull) exit 0 ;;
  ps)
    if [ "${DOCKER_STUB_EXISTING:-0}" = "1" ]; then
      printf '%s\n' "${HIVEBOX_NAME:-hivebox}"
    fi
    ;;
  run) printf '%s\n' deadbeef ;;
esac
SH
chmod +x "$fake_bin/docker"

assert_contains() {
  file="$1"
  expected="$2"
  grep -F -- "$expected" "$file" >/dev/null || {
    printf 'FAIL: expected %s in %s\n' "$expected" "$file" >&2
    sed -n '1,160p' "$file" >&2
    exit 1
  }
}

stub_log="$fixture_root/docker.log"
data_dir="$fixture_root/data with spaces"
HOME="$fixture_root/home" \
DOCKER_STUB_LOG="$stub_log" \
PATH="$fake_bin:$PATH" \
HIVEBOX_DATA="$data_dir" \
  sh "$installer" >"$fixture_root/happy.out" 2>"$fixture_root/happy.err"

assert_contains "$stub_log" "pull ghcr.io/ivankuznetsov/hivebox:latest"
assert_contains "$stub_log" "run -d --name hivebox --restart unless-stopped -p 127.0.0.1:4567:4567 -v $data_dir:/data ghcr.io/ivankuznetsov/hivebox:latest"
assert_contains "$fixture_root/happy.out" "Open:  http://localhost:4567"

set +e
HOME="$fixture_root/home" \
DOCKER_STUB_LOG="$fixture_root/existing.log" \
DOCKER_STUB_EXISTING=1 \
PATH="$fake_bin:$PATH" \
  sh "$installer" >"$fixture_root/existing.out" 2>"$fixture_root/existing.err"
existing_status=$?
set -e

if [ "$existing_status" -eq 0 ]; then
  printf 'FAIL: existing Hivebox container was not refused\n' >&2
  exit 1
fi
assert_contains "$fixture_root/existing.err" "a container named hivebox already exists"
assert_contains "$fixture_root/existing.err" "docker start hivebox"

printf 'install-box.sh: all cases green\n'
