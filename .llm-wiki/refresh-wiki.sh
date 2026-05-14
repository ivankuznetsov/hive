#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

configure_qmd_environment() {
  local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
  if ! mkdir -p "$cache_home/qmd" 2>/dev/null || ! touch "$cache_home/qmd/.write-test" 2>/dev/null; then
    export XDG_CACHE_HOME="$project_root/.llm-wiki/qmd-cache"
    mkdir -p "$XDG_CACHE_HOME/qmd"
  else
    rm -f "$cache_home/qmd/.write-test"
  fi
}

configure_qmd_environment

run_qmd() {
  command -v qmd >/dev/null 2>&1 || return 0

  if command -v timeout >/dev/null 2>&1; then
    timeout "${LLM_WIKI_QMD_TIMEOUT:-900}" qmd "$@"
  else
    qmd "$@"
  fi
}

run_codex() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${LLM_WIKI_CODEX_TIMEOUT:-1800}" codex exec -C "$project_root" "$prompt"
  else
    codex exec -C "$project_root" "$prompt"
  fi
}

if command -v qmd >/dev/null 2>&1; then
  run_qmd update >/dev/null 2>&1 || true
fi

prompt="$(cat <<'PROMPT'
Refresh this project's LLM wiki.
Read .llm-wiki/config.json, AGENTS.md, CLAUDE.md, wiki/index.md, wiki/gaps.md,
and recent wiki/log.md entries first.
If .llm-wiki/config.json contains main_wiki_path, search that exact path before
changing project pages.
Also search default main cross-project wiki paths when they exist:
~/wikis/master/wiki/, ~/wikis/main/wiki/, ../wikis/master/wiki/, and
../wikis/main/wiki/.
Inspect recent git history and changed source files.
Update stale wiki pages, update wiki/index.md when page coverage changes, append
wiki/log.md, and record uncertainty in wiki/gaps.md.
Do not run qmd update or qmd embed yourself; the wrapper script runs bounded qmd
maintenance after this Codex refresh finishes.
Do not invent facts.
PROMPT
)"

codex_status=0
run_codex || codex_status=$?

run_qmd update >/dev/null 2>&1 || true
run_qmd embed --max-docs-per-batch 64 --max-batch-mb 64 >/dev/null 2>&1 || true

exit "$codex_status"
