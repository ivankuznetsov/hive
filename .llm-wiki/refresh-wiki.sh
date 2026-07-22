#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint for daily schedulers. Scheduled runs only drain
# work already queued by post-commit hooks; provider selection and all writes
# remain inside the canonical transactional runner's managed worktree.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_root="$(git -C "$project_root" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$project_root" ]; then
  printf 'llm-wiki: refresh-wiki.sh must be installed inside a Git worktree\n' >&2
  exit 1
fi

common_dir="$(git -C "$project_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
shared_runner="$common_dir/llm-wiki/post-commit-refresh.sh"
local_runner="$project_root/.llm-wiki/post-commit-refresh.sh"

supports_drain() {
  [ -x "$1" ] && \
    grep -Fqx '# LLM_WIKI_RUNNER_CAPABILITIES: drain' "$1" 2>/dev/null
}

if supports_drain "$shared_runner"; then
  runner="$shared_runner"
elif supports_drain "$local_runner"; then
  runner="$local_runner"
else
  printf 'llm-wiki: no drain-capable transactional refresh runner was found; run the llm-wiki upgrade command\n' >&2
  exit 1
fi

exec "$runner" --project "$project_root" --drain
