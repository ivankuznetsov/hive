#!/usr/bin/env bash
set -euo pipefail

# Worktree-safe LLM-wiki post-commit refresh.
#
# A commit in ANY git worktree triggers a wiki refresh, but the wiki is global
# state that lives on the MAIN checkout. So this script reads the just-committed
# code in the committing tree, but reads/writes/commits the wiki ONLY on the main
# checkout. The refresh agent is INSTRUCTED (via the WORKTREE REDIRECT directive
# below) to write the wiki only on the main checkout, so a compliant agent leaves
# the committing worktree's wiki/ untouched and its `git status` clean. All wiki
# commits are serialized (one writer) via a lock in the shared git dir, scoped to
# wiki/, guarded against re-triggering the hook, and never pushed.

committing_tree="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$committing_tree"

configure_qmd_environment() {
  local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
  if ! mkdir -p "$cache_home/qmd" 2>/dev/null || ! touch "$cache_home/qmd/.write-test" 2>/dev/null; then
    export XDG_CACHE_HOME="$committing_tree/.llm-wiki/qmd-cache"
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

run_qmd() {
  command -v qmd >/dev/null 2>&1 || return 0

  if command -v timeout >/dev/null 2>&1; then
    run_without_git_env timeout "${LLM_WIKI_QMD_TIMEOUT:-900}" qmd "$@"
  else
    run_without_git_env qmd "$@"
  fi
}

# --- Resolve the wiki home (main checkout) and whether we're a linked worktree.
git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
main_checkout="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
[ -n "$main_checkout" ] || main_checkout="$committing_tree"
wiki_root="$main_checkout"

linked=0
if [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ]; then
  linked=1
fi

log_file="$wiki_root/.llm-wiki/post-commit-refresh.log"
mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

log_line() {
  printf '[llm-wiki][%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$log_file" 2>/dev/null || true
}

# --- Serialize ALL refreshes/commits across every worktree on one lock in the
#     shared git dir, so N concurrent worktree commits never race the main index.
#     The lock records its owner PID + start time so a crash/SIGKILL/reboot that
#     skips the EXIT trap can be reclaimed instead of wedging refreshes forever.
lock_dir="$common_dir/llm-wiki/refresh.lock"
mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || true

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s %s\n' "$$" "$(date +%s 2>/dev/null || echo 0)" >"$lock_dir/owner" 2>/dev/null || true
    return 0
  fi

  # Lock held — reclaim only if the owner is gone or the lock outlived its TTL
  # (default 2x the agent timeout). Otherwise a peer refresh is genuinely active.
  local owner pid started now ttl
  owner="$(cat "$lock_dir/owner" 2>/dev/null || true)"
  pid="${owner%% *}"
  started="${owner##* }"
  now="$(date +%s 2>/dev/null || echo 0)"
  ttl="${LLM_WIKI_LOCK_TTL:-3600}"

  if { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } ||
     { [ "$now" -gt 0 ] && [ -n "$started" ] && [ "$started" -gt 0 ] && [ "$((now - started))" -gt "$ttl" ]; }; then
    log_line "reclaiming stale refresh lock (owner pid=${pid:-?}, age=$((now - ${started:-now}))s)"
    rm -rf "$lock_dir" 2>/dev/null || true
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s %s\n' "$$" "$now" >"$lock_dir/owner" 2>/dev/null || true
      return 0
    fi
  fi
  return 1
}

if ! acquire_lock; then
  # A peer refresh holds the lock; it reads HEAD fresh, so our update is covered.
  exit 0
fi
trap 'rm -rf "$lock_dir" 2>/dev/null || true' EXIT

changed_files="$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)"
[ -n "$changed_files" ] || exit 0

sha="$(git rev-parse HEAD 2>/dev/null || echo HEAD)"
short_sha="$(git rev-parse --short HEAD 2>/dev/null || echo HEAD)"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
ran_refresh=0

matches() {
  printf '%s\n' "$changed_files" | grep -Eq "$1"
}

# Directive prepended when refreshing from a linked worktree: read the feature
# code here, but read/write the wiki on the main checkout.
redirect_directive() {
  [ "$linked" -eq 1 ] || return 0
  cat <<DIRECTIVE
WORKTREE REDIRECT (read carefully): You are running from a linked git worktree,
but the project wiki is global state that lives on the MAIN checkout at
${wiki_root}. Read and edit wiki pages, index.md, gaps.md, and the changelog ONLY
under ${wiki_root}/wiki/ — do NOT create or edit any file under the current
working directory (${committing_tree}). The change to document is commit ${sha}
on branch ${branch}; inspect it with 'git show ${sha}' and 'git show ${sha}:<path>'.
Reference the change by its branch/slug name "${branch}", never by the raw commit
SHA (it may be rebased or squashed before it reaches the main branch).

DIRECTIVE
}

run_refresh() {
  local prompt="$1"
  local full_prompt
  full_prompt="$(redirect_directive)${prompt}"
  ran_refresh=1

  # Test/override seam: when LLM_WIKI_REFRESH_CMD is set, invoke it with
  # (wiki_root, prompt) instead of the real agent. Lets tests exercise the
  # worktree-redirect/lock/commit plumbing without a live model run.
  if [ -n "${LLM_WIKI_REFRESH_CMD:-}" ]; then
    run_without_git_env "$LLM_WIKI_REFRESH_CMD" "$wiki_root" "$full_prompt" >>"$log_file" 2>&1 || true
    return 0
  fi

  local add_dir_args=( --add-dir "$LLM_WIKI_QMD_CACHE_DIR" )
  [ "$linked" -eq 1 ] && add_dir_args+=( --add-dir "$wiki_root" )

  if command -v timeout >/dev/null 2>&1; then
    run_without_git_env timeout "${LLM_WIKI_CODEX_TIMEOUT:-1800}" codex exec "${add_dir_args[@]}" -C "$committing_tree" "$full_prompt" >>"$log_file" 2>&1 \
      || log_line "WARN: refresh agent exited non-zero (code $?)"
  else
    run_without_git_env codex exec "${add_dir_args[@]}" -C "$committing_tree" "$full_prompt" >>"$log_file" 2>&1 \
      || log_line "WARN: refresh agent exited non-zero (code $?)"
  fi
}

if matches '(^|/)(schema\.rb|structure\.sql|db/migrate/|migrations/|models/|entities/|prisma/schema\.prisma)'; then
  run_refresh "$(cat <<'PROMPT'
Refresh this project's LLM wiki data-model coverage after a commit touched schema,
migration, model, or entity files. Read AGENTS.md, wiki/index.md,
wiki/architecture.md, wiki/dependencies.md, wiki/gaps.md, and recent wiki/log.md
entries first. Inspect the committed diff and relevant source files. Update affected
wiki pages, update wiki/index.md if page coverage changes, add a new
wiki/log.d/<timestamp>-<slug>.md fragment without editing compiled wiki/log.md, and
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
add a new wiki/log.d/<timestamp>-<slug>.md fragment without editing compiled wiki/log.md,
and record uncertainty in wiki/gaps.md. Do not run qmd update or
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
coverage changes, add a new wiki/log.d/<timestamp>-<slug>.md fragment without editing
compiled wiki/log.md, and record uncertainty in wiki/gaps.md. Do not
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
wiki/index.md if page coverage changes, add a new wiki/log.d/<timestamp>-<slug>.md
fragment without editing compiled wiki/log.md, and record uncertainty in
wiki/gaps.md. Do not run qmd update or qmd embed yourself; the post-commit wrapper
runs bounded qmd maintenance after refreshes finish. Do not invent facts.
PROMPT
)"
fi

if [ "$ran_refresh" -eq 1 ]; then
  # Recompile wiki/log.md from the wiki/log.d/*.md fragments the refresh agent
  # wrote (single shared compiler). Fragments are append-only and conflict-free
  # across worktrees; the compiled log.md is a derived artifact regenerated here
  # on the main checkout so it never has to be hand-edited or merged.
  if [ -x "$wiki_root/.llm-wiki/compile-log.sh" ]; then
    bash "$wiki_root/.llm-wiki/compile-log.sh" "$wiki_root" >>"$log_file" 2>&1 \
      || log_line "ERROR: compile-log.sh failed for $wiki_root; wiki/log.md may be stale"
  else
    log_line "WARN: $wiki_root/.llm-wiki/compile-log.sh missing or not executable; skipped log.md compile"
  fi

  if command -v qmd >/dev/null 2>&1; then
    ( cd "$wiki_root" && run_qmd update ) >>"$log_file" 2>&1 || true
    ( cd "$wiki_root" && run_qmd embed --max-docs-per-batch 64 --max-batch-mb 64 ) >>"$log_file" 2>&1 || true
  fi

  # Commit the refreshed wiki on the MAIN checkout — scoped to wiki/, with the
  # post-commit hook disabled so this commit can't re-trigger us (the hook also
  # honors HIVE_SKIP_LLM_WIKI_POST_COMMIT), and never pushed (so an in-progress
  # branch is never diverged from its remote). Leaving the worktree untouched
  # keeps its `git status` clean. A failed commit is logged loudly because it
  # would otherwise strand the agent's edits as uncommitted dirt on the main
  # checkout with no signal.
  if [ -n "$(git -C "$wiki_root" status --porcelain -- wiki 2>/dev/null)" ]; then
    if ! git -C "$wiki_root" add -- wiki >>"$log_file" 2>&1; then
      log_line "ERROR: git add -- wiki failed on $wiki_root; wiki edits left UNCOMMITTED"
    fi
    if ! HIVE_SKIP_LLM_WIKI_POST_COMMIT=1 \
         git -C "$wiki_root" -c core.hooksPath=/dev/null \
         commit --only -m "docs(wiki): post-commit refresh for ${branch}@${short_sha}" \
         -- wiki >>"$log_file" 2>&1; then
      log_line "ERROR: wiki refresh commit FAILED on $wiki_root (${branch}@${short_sha}); edits remain staged/dirty on the main checkout"
    fi
  fi

  for sync_dir in "$HOME/wikis/.sync-needed" "$(dirname "$wiki_root")/wikis/.sync-needed"; do
    if [ -d "$(dirname "$sync_dir")" ]; then
      mkdir -p "$sync_dir"
      touch "$sync_dir/$(basename "$wiki_root")"
    fi
  done
fi
