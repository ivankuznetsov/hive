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

configure_qmd_environment

run_qmd() {
  command -v qmd >/dev/null 2>&1 || return 0

  if command -v timeout >/dev/null 2>&1; then
    timeout "${LLM_WIKI_QMD_TIMEOUT:-900}" qmd "$@"
  else
    qmd "$@"
  fi
}

log_file="$project_root/.llm-wiki/post-commit-refresh.log"
lock_dir="$project_root/.llm-wiki/post-commit-refresh.lock"
changed_files="$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)"
ran_refresh=0

[ -n "$changed_files" ] || exit 0

if ! mkdir "$lock_dir" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$lock_dir"' EXIT

matches() {
  printf '%s\n' "$changed_files" | grep -Eq "$1"
}

run_refresh() {
  local prompt="$1"
  ran_refresh=1
  if command -v timeout >/dev/null 2>&1; then
    timeout "${LLM_WIKI_CODEX_TIMEOUT:-1800}" codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root" "$prompt" >>"$log_file" 2>&1 || true
  else
    codex exec --add-dir "$LLM_WIKI_QMD_CACHE_DIR" -C "$project_root" "$prompt" >>"$log_file" 2>&1 || true
  fi
}

if matches '(^|/)(schema\.rb|structure\.sql|db/migrate/|migrations/|models/|entities/|prisma/schema\.prisma)'; then
  run_refresh "$(cat <<'PROMPT'
Refresh this project's LLM wiki data-model coverage after a commit touched schema,
migration, model, or entity files. Read AGENTS.md, wiki/index.md,
wiki/architecture.md, wiki/dependencies.md, wiki/gaps.md, and recent wiki/log.md
entries first. Inspect the committed diff and relevant source files. Update affected
wiki pages, update wiki/index.md if page coverage changes, append wiki/log.md, and
record uncertainty in wiki/gaps.md. Do not run qmd update or qmd embed yourself; the
post-commit wrapper runs bounded qmd maintenance after refreshes finish. Do not
invent facts.
PROMPT
)"
fi

if matches '(^|/)(routes|controllers|handlers|resolvers|src/commands/|lib/.*commands|bin/|README\.md)'; then
  run_refresh "$(cat <<'PROMPT'
Refresh this project's LLM wiki command and API surface coverage after a commit
touched routes, handlers, commands, executable entrypoints, or README content. Read
AGENTS.md, wiki/index.md, wiki/architecture.md, wiki/decisions.md, wiki/gaps.md,
and recent wiki/log.md entries first. Inspect the committed diff and relevant source
files. Update affected wiki pages, update wiki/index.md if page coverage changes,
append wiki/log.md, and record uncertainty in wiki/gaps.md. Do not run qmd update or
qmd embed yourself; the post-commit wrapper runs bounded qmd maintenance after
refreshes finish. Do not invent facts.
PROMPT
)"
fi

if matches '(^|/)(Gemfile|Gemfile\.lock|package\.json|package-lock\.json|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock|requirements\.txt|pyproject\.toml|poetry\.lock|composer\.json|composer\.lock)$'; then
  run_refresh "$(cat <<'PROMPT'
Refresh this project's LLM wiki dependency coverage after a commit touched dependency
files. Read AGENTS.md, wiki/index.md, wiki/dependencies.md, wiki/gaps.md, and recent
wiki/log.md entries first. Inspect the committed diff and dependency files. Update
wiki/dependencies.md and related pages if facts changed, update wiki/index.md if page
coverage changes, append wiki/log.md, and record uncertainty in wiki/gaps.md. Do not
run qmd update or qmd embed yourself; the post-commit wrapper runs bounded qmd
maintenance after refreshes finish. Do not
invent facts.
PROMPT
)"
fi

if matches '(^|/)(docs/|wiki/|raw/notes/|plans/|todos/)|(^|/)(CHANGELOG\.md|AGENTS\.md|CLAUDE\.md)$'; then
  run_refresh "$(cat <<'PROMPT'
Refresh this project's LLM wiki planning and documentation coverage after a commit
touched docs, plans, notes, context files, or the wiki itself. Read AGENTS.md,
wiki/index.md, wiki/decisions.md, wiki/gaps.md, and recent wiki/log.md entries first.
Inspect the committed diff and relevant source files. Update stale pages, update
wiki/index.md if page coverage changes, append wiki/log.md, and record uncertainty in
wiki/gaps.md. Do not run qmd update or qmd embed yourself; the post-commit wrapper
runs bounded qmd maintenance after refreshes finish. Do not invent facts.
PROMPT
)"
fi

if [ "$ran_refresh" -eq 1 ]; then
  if command -v qmd >/dev/null 2>&1; then
    run_qmd update >>"$log_file" 2>&1 || true
    run_qmd embed --max-docs-per-batch 64 --max-batch-mb 64 >>"$log_file" 2>&1 || true
  fi

  for sync_dir in "$HOME/wikis/.sync-needed" "$(dirname "$project_root")/wikis/.sync-needed"; do
    if [ -d "$(dirname "$sync_dir")" ]; then
      mkdir -p "$sync_dir"
      touch "$sync_dir/hive"
    fi
  done
fi
