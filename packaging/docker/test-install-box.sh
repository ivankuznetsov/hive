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
{
  printf 'BEGIN argc=%s\n' "$#"
  argument_index=1
  for argument do
    printf 'ARG %s=<%s>\n' "$argument_index" "$argument"
    argument_index=$((argument_index + 1))
  done
  printf 'END\n'
} >>"$DOCKER_STUB_LOG"
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

assert_files_equal() {
  expected="$1"
  actual="$2"
  diff -u "$expected" "$actual" || {
    printf 'FAIL: %s did not match %s\n' "$actual" "$expected" >&2
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

cat >"$fixture_root/happy.expected" <<EOF
BEGIN argc=1
ARG 1=<info>
END
BEGIN argc=4
ARG 1=<ps>
ARG 2=<-a>
ARG 3=<--format>
ARG 4=<{{.Names}}>
END
BEGIN argc=2
ARG 1=<pull>
ARG 2=<ghcr.io/ivankuznetsov/hivebox:latest>
END
BEGIN argc=11
ARG 1=<run>
ARG 2=<-d>
ARG 3=<--name>
ARG 4=<hivebox>
ARG 5=<--restart>
ARG 6=<unless-stopped>
ARG 7=<-p>
ARG 8=<127.0.0.1:4567:4567>
ARG 9=<-v>
ARG 10=<$data_dir:/data>
ARG 11=<ghcr.io/ivankuznetsov/hivebox:latest>
END
EOF
assert_files_equal "$fixture_root/happy.expected" "$stub_log"
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
cat >"$fixture_root/existing.expected" <<'EOF'
BEGIN argc=1
ARG 1=<info>
END
BEGIN argc=4
ARG 1=<ps>
ARG 2=<-a>
ARG 3=<--format>
ARG 4=<{{.Names}}>
END
EOF
assert_files_equal "$fixture_root/existing.expected" "$fixture_root/existing.log"
assert_contains "$fixture_root/existing.err" "a container named hivebox already exists"
assert_contains "$fixture_root/existing.err" "docker start hivebox"

printf 'install-box.sh: all cases green\n'
