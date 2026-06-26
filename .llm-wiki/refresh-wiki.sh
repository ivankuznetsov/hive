#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

configure_qmd_environment() {
  local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
  if ! mkdir -p "$cache_home/qmd" 2>/dev/null || ! touch "$cache_home/qmd/.write-test" 2>/dev/null; then
    export XDG_CACHE_HOME="$project_root/.llm-wiki/qmd-cache"
    mkdir -p "$XDG_CACHE_HOME/qmd"
    export LLM_WIKI_QMD_CACHE_DIR="$XDG_CACHE_HOME/qmd"
  else
    rm -f "$cache_home/qmd/.write-test"
    export LLM_WIKI_QMD_CACHE_DIR="$cache_home/qmd"
  fi
}

configure_git_tool_environment() {
  GIT_ENV_UNSET_ARGS=()
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && GIT_ENV_UNSET_ARGS+=("-u" "$name")
  done < <(git rev-parse --local-env-vars 2>/dev/null || true)
}

run_without_git_env() {
  env "${GIT_ENV_UNSET_ARGS[@]+"${GIT_ENV_UNSET_ARGS[@]}"}" "$@"
}

configure_qmd_environment
configure_git_tool_environment

find_qmd() {
  if [ -n "${HIVE_QMD_BIN:-}" ] && [ -x "$HIVE_QMD_BIN" ]; then
    printf '%s\n' "$HIVE_QMD_BIN"
    return 0
  fi

  if command -v qmd >/dev/null 2>&1; then
    command -v qmd
    return 0
  fi

  local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  local candidate
  for candidate in "$data_home/hive/qmd/bin/qmd" "$HOME/.local/share/hive/qmd/bin/qmd"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  local prefix_file="$data_home/hive/install-prefix"
  if [ -r "$prefix_file" ]; then
    local prefix
    prefix="$(sed -n '1p' "$prefix_file")"
    candidate="${prefix%/}/hive/qmd/bin/qmd"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

qmd_available() {
  find_qmd >/dev/null 2>&1
}

# run_qmd never aborts the caller: a missing qmd is a silent no-op,
# and a timeout (exit 124) or other failure is reported to stderr
# (captured by callers that log stderr) instead of propagating under
# `set -e`, so callers need no trailing `|| true`.
run_qmd() {
  local qmd_bin rc
  qmd_bin="$(find_qmd)" || return 0

  if command -v timeout >/dev/null 2>&1; then
    run_without_git_env timeout "${LLM_WIKI_QMD_TIMEOUT:-900}" "$qmd_bin" "$@" && return 0 || rc=$?
  else
    run_without_git_env "$qmd_bin" "$@" && return 0 || rc=$?
  fi

  if [ "$rc" -eq 124 ]; then
    echo "qmd $1 timed out after ${LLM_WIKI_QMD_TIMEOUT:-900}s; wiki index may be stale" >&2
  else
    echo "qmd $1 failed (exit $rc); wiki index may be stale" >&2
  fi
  return 0
}

run_codex() {
  if command -v timeout >/dev/null 2>&1; then
    run_without_git_env timeout "${LLM_WIKI_CODEX_TIMEOUT:-1800}" codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root" "$prompt"
  else
    run_without_git_env codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root" "$prompt"
  fi
}

if qmd_available; then
  run_qmd update >/dev/null 2>&1
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
Update stale wiki pages, update wiki/index.md when page coverage changes, add a
new wiki/log.d/<timestamp>-<slug>.md fragment without editing compiled wiki/log.md, and
record uncertainty in wiki/gaps.md.
Do not run qmd update or qmd embed yourself; the wrapper script runs bounded qmd
maintenance after this Codex refresh finishes.
Do not invent facts.
PROMPT
)"

codex_status=0
run_codex || codex_status=$?

run_qmd update >/dev/null 2>&1
run_qmd embed --max-docs-per-batch 64 --max-batch-mb 64 >/dev/null 2>&1

exit "$codex_status"
