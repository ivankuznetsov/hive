#!/usr/bin/env bash
set -euo pipefail

prefix="${HIVE_RC_CHANNEL_PREFIX:?}"
candidate="${HIVE_RC_CHANNEL_CANDIDATE_ROOT:?}"
run_root="${HIVE_RC_CHANNEL_RUN_ROOT:?}"
receipt="${HIVE_RC_CHANNEL_RECEIPT:?}"
channel="${HIVE_RC_CHANNEL:?}"

case "$prefix:$candidate:$run_root:$receipt" in
  *..*|*//*)
    echo "channel-update-fixture: unsafe path" >&2
    exit 64
    ;;
esac
case "$prefix" in "$run_root"/*) ;; *) exit 64 ;; esac
case "$candidate" in /*) ;; *) exit 64 ;; esac
case "$receipt" in "$run_root"/*) ;; *) exit 64 ;; esac
[[ -d "$candidate" && ! -L "$candidate" ]]

if [[ "$channel" == "linux-bash" ]]; then
  expected_prefix=""
  for argument in "$@"; do
    case "$argument" in --prefix=*) expected_prefix="${argument#--prefix=}" ;; esac
  done
  [[ "$expected_prefix" == "$prefix" ]]
elif [[ "$channel" != "homebrew-local-formula" ]]; then
  exit 64
fi

stage="${run_root}/channel-candidate-stage"
retired="${run_root}/channel-baseline-applied"
[[ ! -e "$stage" && ! -L "$stage" && ! -e "$retired" && ! -L "$retired" ]]
mkdir -p "$stage"
cp -R "$candidate/." "$stage/"

if [[ "$channel" == "linux-bash" ]]; then
  mkdir -p "$stage/hive"
  printf 'bash\n' > "$stage/hive/install-channel"
  printf '%s\n' "$prefix" > "$stage/hive/install-prefix"
else
  mkdir -p "$stage/share/hive"
  printf 'brew\n' > "$stage/share/hive/install-channel"
fi

mv "$prefix" "$retired"
mv "$stage" "$prefix"
(set -o noclobber; printf '%s\n' "$channel" > "$receipt")
