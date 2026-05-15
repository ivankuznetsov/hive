#!/usr/bin/env bash
set -euo pipefail

target="${1:-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "Checking Tebako availability for ${target}"
if ! command -v tebako >/dev/null 2>&1; then
  echo "tebako is not installed in this environment" >&2
  exit 69
fi

cd "${repo_root}"
bundle exec rake "build:release[${target}]"
