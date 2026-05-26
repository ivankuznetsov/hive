#!/usr/bin/env bash
set -euo pipefail

project="${1:-hive}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$root"
exec bundle exec ruby bin/hive babysit --once "$project" --dry-run
