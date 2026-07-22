#!/usr/bin/env bash
set -euo pipefail

# LLM_WIKI_RUNNER_CAPABILITIES: drain

# Transactional LLM-wiki post-commit refresh.
#
# Every relevant commit is queued in the shared Git directory. One worker
# drains that queue into a dedicated llm-wiki/refresh branch checked out in a
# disposable managed worktree. User checkouts are read-only inputs: neither the
# committing checkout nor the primary checkout is used as an agent workspace,
# staging area, log destination, or QMD cache.

project_override=""
retry_selector=""
drain_mode=0

usage() {
  printf 'Usage: %s [--project <path>] [--drain | --retry-failed <sha|all>]\n' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      project_override="$2"
      shift 2
      ;;
    --drain)
      drain_mode=1
      shift
      ;;
    --retry-failed)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      retry_selector="$2"
      shift 2
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done
if [ "$drain_mode" -eq 1 ] && [ -n "$retry_selector" ]; then
  printf 'llm-wiki: --drain and --retry-failed are mutually exclusive\n' >&2
  exit 2
fi
if [ "$retry_selector" != all ] && [ -n "$retry_selector" ] && \
   [[ ! "$retry_selector" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
  printf 'llm-wiki: retry selector must be a full source SHA or all\n' >&2
  exit 2
fi

if [ -n "$project_override" ]; then
  committing_tree="$(git -C "$project_override" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$committing_tree" ]; then
    printf 'llm-wiki: --project must identify a Git worktree\n' >&2
    exit 2
  fi
else
  committing_tree="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$committing_tree"

configure_git_tool_environment() {
  GIT_ENV_UNSET_ARGS=()
  GIT_ENV_NAMES=()
  local name
  while IFS= read -r name; do
    if [ -n "$name" ]; then
      GIT_ENV_UNSET_ARGS+=("-u" "$name")
      GIT_ENV_NAMES+=("$name")
    fi
  done < <(git rev-parse --local-env-vars 2>/dev/null || true)
}

run_without_git_env() {
  env "${GIT_ENV_UNSET_ARGS[@]+"${GIT_ENV_UNSET_ARGS[@]}"}" "$@"
}

run_with_timeout() {
  local seconds="$1" kill_after
  local timeout_bin
  shift

  timeout_bin="$(command -v timeout 2>/dev/null || true)"
  if [ -z "$timeout_bin" ] || [ ! -x "$timeout_bin" ]; then
    timeout_bin="$(command -v gtimeout 2>/dev/null || true)"
  fi
  if [ -z "$timeout_bin" ] || [ ! -x "$timeout_bin" ]; then
    printf 'llm-wiki: bounded execution unavailable (install timeout or gtimeout)\n' >&2
    return 125
  fi

  kill_after="${LLM_WIKI_TIMEOUT_KILL_AFTER:-10}"
  [[ "$kill_after" =~ ^[1-9][0-9]*$ ]] || kill_after=10
  run_without_git_env "$timeout_bin" -k "$kill_after" "$seconds" "$@"
}

clear_git_tool_environment() {
  local name
  for name in "${GIT_ENV_NAMES[@]}"; do
    unset "$name"
  done
}

configure_git_tool_environment

common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[ -n "$common_dir" ] || exit 0
state_dir="$common_dir/llm-wiki"
pending_dir="$state_dir/pending"
failed_dir="$state_dir/failed"
failure_count_file="$state_dir/consecutive-failures"
breaker_file="$state_dir/refresh-disabled"
publication_blocked_file="$state_dir/publication-blocked"
canonical_config="$state_dir/config.json"
lock_ref="${LLM_WIKI_LOCK_REF:-refs/llm-wiki/refresh-lock}"
source_ref_prefix="refs/llm-wiki/sources"
refresh_root="$state_dir/refresh-worktree"
log_file="$state_dir/post-commit-refresh.log"
refresh_branch="${LLM_WIKI_REFRESH_BRANCH:-llm-wiki/refresh}"
refresh_remote="${LLM_WIKI_REFRESH_REMOTE:-origin}"
remote_refresh_ref="refs/llm-wiki/remotes/refresh"
remote_base_ref="refs/llm-wiki/remotes/base"
lock_owner_oid=""
global_lock_fd=""
global_lock_keeper_pid=""
mkdir -p "$pending_dir" "$failed_dir"

positive_integer_or_default() {
  local value="$1" fallback="$2"
  if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

max_auto_pending="$(positive_integer_or_default "${LLM_WIKI_MAX_AUTO_PENDING:-25}" 25)"
max_batch_sources="$(positive_integer_or_default "${LLM_WIKI_MAX_BATCH_SOURCES:-10}" 10)"
max_paths_per_source="$(positive_integer_or_default "${LLM_WIKI_MAX_PATHS_PER_SOURCE:-20}" 20)"
max_path_bytes="$(positive_integer_or_default "${LLM_WIKI_MAX_PATH_BYTES:-200}" 200)"

log_line() {
  printf '[llm-wiki][%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$log_file" 2>/dev/null || true
}

configure_qmd_environment() {
  local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
  if ! mkdir -p "$cache_home/qmd" 2>/dev/null || ! touch "$cache_home/qmd/.write-test" 2>/dev/null; then
    export XDG_CACHE_HOME="$state_dir/cache"
    mkdir -p "$XDG_CACHE_HOME/qmd"
    export LLM_WIKI_QMD_CACHE_DIR="$XDG_CACHE_HOME/qmd"
  else
    rm -f "$cache_home/qmd/.write-test"
    export LLM_WIKI_QMD_CACHE_DIR="$cache_home/qmd"
  fi
}

run_qmd() {
  command -v qmd >/dev/null 2>&1 || return 0
  run_with_timeout "${LLM_WIKI_QMD_TIMEOUT:-900}" qmd "$@"
}

sha="$(git rev-parse HEAD 2>/dev/null || true)"
[ -n "$sha" ] || exit 0
if [ "$drain_mode" -eq 0 ] && [ -z "$retry_selector" ]; then
  changed_files="$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)"
  [ -n "$changed_files" ] || exit 0

  if ! printf '%s\n' "$changed_files" | grep -Eq \
    '(^|/)(schema\.rb|structure\.sql|db/migrate/|migrations/|models/|entities/|prisma/schema\.prisma|routes|controllers|handlers|resolvers|app/|src/|lib/|test/|tests/|spec/|templates/|config/|bin/|README\.md|Gemfile|Gemfile\.lock|package\.json|package-lock\.json|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock|requirements\.txt|pyproject\.toml|poetry\.lock|composer\.json|composer\.lock|docs/|wiki/|raw/notes/|plans/|todos/|CHANGELOG\.md|AGENTS\.md|CLAUDE\.md)'; then
    exit 0
  fi

  if [ -f "$failed_dir/$sha" ]; then
    log_line "source $sha remains quarantined; skipping automatic refresh"
    exit 0
  fi
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  queue_tmp="$pending_dir/.${sha}.$$"
  {
    printf '%s\t%s\n' "$sha" "$branch"
    printf '%s\n' "$changed_files"
  } >"$queue_tmp"
  mv -f "$queue_tmp" "$pending_dir/$sha"

  if ! run_with_timeout "${LLM_WIKI_GIT_REF_TIMEOUT:-5}" \
       git update-ref "$source_ref_prefix/$sha" "$sha" \
       >>"$log_file" 2>&1; then
    breaker_tmp="$state_dir/.refresh-disabled.$$"
    printf 'source-pin:%s\n' "$sha" >"$breaker_tmp"
    mv -f "$breaker_tmp" "$breaker_file"
    log_line "ERROR: source $sha queued but could not be pinned; automatic refresh disabled"
    exit 0
  fi

  if [ -f "$breaker_file" ]; then
    log_line "automatic refresh circuit is open; source $sha queued"
    exit 0
  fi

  scheduler_service="$(sed -n '1p' "$state_dir/scheduler-service" 2>/dev/null || true)"
  if [ "${HIVE_SKIP_LLM_WIKI_SYSTEMCTL:-}" != "1" ] && \
     [[ "$scheduler_service" =~ ^llm-wiki-[A-Za-z0-9_.-]+\.service$ ]]; then
    if command -v systemctl >/dev/null 2>&1 && \
       run_with_timeout "${LLM_WIKI_SYSTEMCTL_TIMEOUT:-10}" \
         systemctl --user start --no-block "$scheduler_service" \
         >>"$log_file" 2>&1; then
      log_line "queued source $sha for memory-bounded systemd worker $scheduler_service"
      exit 0
    else
      rm -f -- "$state_dir/scheduler-service"
      log_line "WARN: memory-bounded systemd worker $scheduler_service could not be started; using machine-wide serialized fallback"
    fi
  fi
fi

# From this point onward every Git command is nested maintenance work against
# the managed refresh worktree, not inspection of the triggering hook context.
clear_git_tool_environment

process_identity() {
  local pid="$1"
  if [ -r "/proc/$pid/stat" ]; then
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true
  else
    ps -o lstart= -p "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  fi
}

acquire_global_provider_lock() {
  local uid runtime_dir lock_file lock_status
  [ "${LLM_WIKI_GLOBAL_LOCK_HELD:-}" = "1" ] && return 0

  uid="${UID:-$(id -u)}"
  runtime_dir="${XDG_RUNTIME_DIR:-}"
  if [ -z "$runtime_dir" ] && [ -d "/run/user/$uid" ] && [ -w "/run/user/$uid" ]; then
    runtime_dir="/run/user/$uid"
  fi
  runtime_dir="${runtime_dir:-${TMPDIR:-/tmp}}"
  lock_file="$runtime_dir/hive-llm-wiki-refresh.lock"

  if [ "${LLM_WIKI_DISABLE_FLOCK:-}" != "1" ] && command -v flock >/dev/null 2>&1; then
    exec {global_lock_fd}>"$lock_file"
    flock --nonblock "$global_lock_fd"
    return
  fi

  command -v ruby >/dev/null 2>&1 || return 1
  coproc HIVE_GLOBAL_LOCK_KEEPER {
    # Commit hooks can inherit Bundler/Coverage loader state from a parent
    # process even when PATH resolves a different system Ruby. The lock keeper
    # only needs Ruby's core File API, so isolate it from those injected loaders.
    RUBYOPT='' RUBYLIB='' ruby -e '
      lock = File.open(ARGV.fetch(0), File::RDWR | File::CREAT, 0o600)
      if lock.flock(File::LOCK_EX | File::LOCK_NB)
        STDOUT.puts("locked")
        STDOUT.flush
        STDIN.read
      else
        STDOUT.puts("busy")
      end
    ' "$lock_file"
  }
  global_lock_keeper_pid="$HIVE_GLOBAL_LOCK_KEEPER_PID"
  IFS= read -r lock_status <&"${HIVE_GLOBAL_LOCK_KEEPER[0]}" || lock_status=""
  [ "$lock_status" = "locked" ]
}

lock_owner_stale() {
  local owner_oid="$1" owner pid identity current_identity
  owner="$(git cat-file -p "$owner_oid" 2>/dev/null || true)"
  IFS='|' read -r pid _ identity _ <<<"$owner"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    current_identity="$(process_identity "$pid")"
    if [ -z "$identity" ] || [ -z "$current_identity" ] || [ "$identity" = "$current_identity" ]; then
      return 1
    fi
  fi
  return 0
}

acquire_lock() {
  local wait_seconds deadline now owner current_oid expected_oid zero_oid
  wait_seconds="${LLM_WIKI_LOCK_WAIT_SECONDS:-60}"
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds=60
  now="$(date +%s 2>/dev/null || echo 0)"
  deadline="$((now + wait_seconds))"
  owner="$$|$now|$(process_identity "$$")|${RANDOM:-0}"
  lock_owner_oid="$(printf '%s\n' "$owner" | git hash-object -w --stdin)"
  zero_oid="${lock_owner_oid//?/0}"

  while true; do
    current_oid="$(git rev-parse --verify --quiet "$lock_ref" 2>/dev/null || true)"
    if [ -z "$current_oid" ] || lock_owner_stale "$current_oid"; then
      expected_oid="${current_oid:-$zero_oid}"
      if run_with_timeout "${LLM_WIKI_GIT_REF_TIMEOUT:-5}" \
           git update-ref "$lock_ref" "$lock_owner_oid" "$expected_oid" \
           >>"$log_file" 2>&1; then
        [ -n "$current_oid" ] && log_line "reclaimed stale refresh lock"
        return 0
      fi
    fi

    # Check the deadline after every unsuccessful iteration. A failed
    # compare-and-swap can otherwise spin forever while short-lived owners race
    # to acquire and release an apparently absent or stale ref.
    now="$(date +%s 2>/dev/null || echo 0)"
    [ "$now" -ge "$deadline" ] && return 1
    sleep 1
  done
}

pending_source_count() {
  local path count=0
  shopt -s nullglob
  for path in "$pending_dir"/*; do
    [ -f "$path" ] && count=$((count + 1))
  done
  shopt -u nullglob
  printf '%s\n' "$count"
}

pending_sources_present() {
  [ "$(pending_source_count)" -gt 0 ]
}

recover_queue_temps() {
  local path name queued_sha queued_sha_in_file queued_branch target
  shopt -s nullglob
  for path in "$pending_dir"/.[0-9a-fA-F]*.*; do
    [ -f "$path" ] || continue
    name="$(basename "$path")"
    if [[ ! "$name" =~ ^\.([0-9a-fA-F]{40,64})\.[0-9]+$ ]]; then
      log_line "WARN: unrecognized queue temp retained: $name"
      continue
    fi
    queued_sha="${BASH_REMATCH[1]}"
    target="$pending_dir/$queued_sha"
    if [ -f "$target" ]; then
      rm -f -- "$path"
      log_line "removed duplicate queue temp for source $queued_sha"
      continue
    fi
    IFS=$'\t' read -r queued_sha_in_file queued_branch <"$path" || true
    if [ "$queued_sha_in_file" != "$queued_sha" ]; then
      log_line "WARN: incomplete queue temp retained: $name"
      continue
    fi
    mv -f -- "$path" "$target"
    log_line "recovered interrupted queue write for source $queued_sha"
  done
  shopt -u nullglob
}

open_backlog_circuit_if_needed() {
  local count breaker_tmp
  count="$(pending_source_count)"
  [ "$count" -gt "$max_auto_pending" ] || return 1
  breaker_tmp="$state_dir/.refresh-disabled.$$"
  printf 'backlog:%s\n' "$count" >"$breaker_tmp"
  mv -f "$breaker_tmp" "$breaker_file"
  log_line "automatic refresh disabled before provider launch: $count queued sources exceed LLM_WIKI_MAX_AUTO_PENDING=$max_auto_pending; run .llm-wiki/post-commit-refresh.sh --retry-failed all for one bounded batch"
  return 0
}

pin_queued_sources() {
  local path queued_sha queued_branch
  {
    printf 'start\n'
    shopt -s nullglob
    for path in "$pending_dir"/* "$failed_dir"/*; do
      [ -f "$path" ] || continue
      queued_sha=""
      queued_branch=""
      IFS=$'\t' read -r queued_sha queued_branch <"$path" || true
      if [[ "$queued_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] && \
         git cat-file -e "${queued_sha}^{commit}" 2>/dev/null; then
        printf 'update %s/%s %s\n' "$source_ref_prefix" "$queued_sha" "$queued_sha"
      else
        log_line "ERROR: queued source is not an available commit: $queued_sha"
      fi
    done
    shopt -u nullglob
    printf 'commit\n'
  } | run_with_timeout "${LLM_WIKI_GIT_REF_TIMEOUT:-5}" \
    git update-ref --stdin >>"$log_file" 2>&1
}

open_source_pin_circuit() {
  local breaker_tmp="$state_dir/.refresh-disabled.$$"
  printf 'source-pin:batch\n' >"$breaker_tmp"
  mv -f "$breaker_tmp" "$breaker_file"
  log_line "ERROR: could not pin queued source commits; automatic refresh disabled"
}

reconcile_circuit_after_success() {
  local pending_count failed_count breaker_tmp

  # Close first, then recount while still holding the worker lock. A hook that
  # observed the old breaker and exited has already queued its source, while a
  # hook that arrives after this removal will wait for this lock and perform its
  # own reconciliation.
  rm -f -- "$breaker_file"
  pending_count="$(pending_source_count)"
  failed_count="$(failed_source_count)"
  if [ "$failed_count" -gt 0 ]; then
    breaker_tmp="$state_dir/.refresh-disabled.$$"
    printf 'quarantined:%s\n' "$failed_count" >"$breaker_tmp"
    mv -f "$breaker_tmp" "$breaker_file"
    log_line "refresh succeeded, but $failed_count quarantined source(s) remain; automatic refresh stays disabled"
  elif [ "$pending_count" -gt 0 ] && [ "$drain_mode" -eq 1 ]; then
    log_line "scheduled refresh left $pending_count newly arrived source(s) queued for the next bounded drain"
  elif [ "$pending_count" -gt 0 ]; then
    breaker_tmp="$state_dir/.refresh-disabled.$$"
    printf 'deferred:%s\n' "$pending_count" >"$breaker_tmp"
    mv -f "$breaker_tmp" "$breaker_file"
    log_line "automatic refresh deferred: $pending_count source(s) arrived outside the completed bounded batch; run .llm-wiki/post-commit-refresh.sh --retry-failed all"
  fi
}

restore_failed_sources() {
  local file restored=0 has_pending=0
  if [ "$retry_selector" = all ]; then
    shopt -s nullglob
    for file in "$failed_dir"/*; do
      [ -f "$file" ] || continue
      if ! mv -f -- "$file" "$pending_dir/$(basename "$file")"; then
        shopt -u nullglob
        printf 'llm-wiki: could not restore quarantined source %s\n' "$(basename "$file")" >&2
        return 1
      fi
      restored=$((restored + 1))
    done
    shopt -u nullglob
  elif [ -f "$failed_dir/$retry_selector" ]; then
    if ! mv -f -- "$failed_dir/$retry_selector" "$pending_dir/$retry_selector"; then
      printf 'llm-wiki: could not restore quarantined source %s\n' "$retry_selector" >&2
      return 1
    fi
    restored=1
  elif [ -f "$pending_dir/$retry_selector" ]; then
    restored=0
  else
    printf 'llm-wiki: no quarantined source %s\n' "$retry_selector" >&2
    return 1
  fi

  shopt -s nullglob
  for file in "$pending_dir"/*; do
    if [ -f "$file" ]; then
      has_pending=1
      break
    fi
  done
  shopt -u nullglob
  if [ "$restored" -eq 0 ] && [ "$has_pending" -eq 0 ]; then
    printf 'llm-wiki: no quarantined or pending sources to retry\n'
    return 1
  fi
  printf 'llm-wiki: retrying %s restored source(s) with queued work\n' "$restored"
}

failed_source_count() {
  local path count=0
  shopt -s nullglob
  for path in "$failed_dir"/*; do
    [ -f "$path" ] && count=$((count + 1))
  done
  shopt -u nullglob
  printf '%s\n' "$count"
}

recoverable_queue_temps_present() {
  local path name queued_sha queued_sha_in_file
  shopt -s nullglob
  for path in "$pending_dir"/.[0-9a-fA-F]*.*; do
    [ -f "$path" ] || continue
    name="$(basename "$path")"
    if [[ "$name" =~ ^\.([0-9a-fA-F]{40,64})\.[0-9]+$ ]]; then
      queued_sha="${BASH_REMATCH[1]}"
      queued_sha_in_file=""
      IFS=$'\t' read -r queued_sha_in_file _ <"$path" || true
      if [ "$queued_sha_in_file" = "$queued_sha" ]; then
        shopt -u nullglob
        return 0
      fi
    fi
  done
  shopt -u nullglob
  return 1
}

# Scheduled runs are queue consumers. Avoid taking the shared Git-ref lock or
# preparing cache state when there is provably nothing they can consume. A
# queued source must still be recovered and pinned while the circuit is open,
# so the breaker is checked only after the worker owns the lock. The no-work
# condition is checked again under the lock below for race safety.
if [ "$drain_mode" -eq 1 ]; then
  if ! pending_sources_present && ! recoverable_queue_temps_present; then
    log_line "scheduled drain skipped; no queued sources"
    exit 0
  fi
fi

if ! acquire_lock; then
  log_line "refresh remains queued; worker lock was busy"
  if [ -n "$retry_selector" ]; then
    printf 'llm-wiki: retry deferred; refresh worker lock is busy\n' >&2
    exit 1
  fi
  exit 0
fi

cleanup_refresh_worktree() {
  if git worktree list --porcelain 2>/dev/null | grep -Fqx "worktree $refresh_root"; then
    git worktree remove --force "$refresh_root" >>"$log_file" 2>&1 || true
  elif [ -e "$refresh_root" ]; then
    rm -rf "$refresh_root" 2>/dev/null || true
  fi
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  cleanup_refresh_worktree
  [ -n "$global_lock_keeper_pid" ] && kill "$global_lock_keeper_pid" 2>/dev/null || true
  [ -n "$global_lock_keeper_pid" ] && wait "$global_lock_keeper_pid" 2>/dev/null || true
  [ -n "$lock_owner_oid" ] && \
    run_with_timeout "${LLM_WIKI_GIT_REF_TIMEOUT:-5}" \
      git update-ref -d "$lock_ref" "$lock_owner_oid" \
      >>"$log_file" 2>&1 || true
}
trap cleanup EXIT

default_base_ref() {
  local candidate
  candidate="$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
  for candidate in "$remote_base_ref" "$candidate" refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
    [ -n "$candidate" ] || continue
    if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "$sha"
}

sync_remote_base_ref() {
  local symref_output branch_ref candidate
  git update-ref -d "$remote_base_ref" >/dev/null 2>&1 || true
  publication_required || return 0

  symref_output="$(
    run_with_timeout "${LLM_WIKI_GIT_FETCH_TIMEOUT:-120}" \
      git ls-remote --symref "$refresh_remote" HEAD 2>>"$log_file" || true
  )"
  branch_ref="$(printf '%s\n' "$symref_output" | awk '$1 == "ref:" && $3 == "HEAD" { print $2; exit }')"
  if [ -z "$branch_ref" ]; then
    for candidate in main master; do
      if run_with_timeout "${LLM_WIKI_GIT_FETCH_TIMEOUT:-120}" \
           git ls-remote --exit-code --heads "$refresh_remote" "refs/heads/$candidate" \
           >>"$log_file" 2>&1; then
        branch_ref="refs/heads/$candidate"
        break
      fi
    done
  fi
  if [ -z "$branch_ref" ]; then
    log_line "ERROR: could not resolve the default branch on $refresh_remote; queue retained"
    return 1
  fi

  run_with_timeout "${LLM_WIKI_GIT_FETCH_TIMEOUT:-120}" \
    git fetch --no-tags "$refresh_remote" "$branch_ref:$remote_base_ref" \
    >>"$log_file" 2>&1 || {
      log_line "ERROR: could not fetch $refresh_remote default branch; queue retained"
      return 1
    }
}

publication_required() {
  [ "${LLM_WIKI_SKIP_PUSH:-}" != "1" ] && \
    git remote get-url "$refresh_remote" >/dev/null 2>&1
}

sync_remote_refresh_ref() {
  local remote_head status
  git update-ref -d "$remote_refresh_ref" >/dev/null 2>&1 || true
  publication_required || return 0

  if remote_head="$(
    run_with_timeout "${LLM_WIKI_GIT_FETCH_TIMEOUT:-120}" \
      git ls-remote --exit-code --heads "$refresh_remote" \
      "refs/heads/$refresh_branch" 2>>"$log_file"
  )"; then
    [ -n "$remote_head" ] || return 0
  else
    status=$?
    if [ "$status" -eq 2 ]; then
      return 0
    fi
    log_line "ERROR: could not inspect $refresh_remote/$refresh_branch; queue retained"
    return 1
  fi

  run_with_timeout "${LLM_WIKI_GIT_FETCH_TIMEOUT:-120}" \
    git fetch --no-tags "$refresh_remote" \
    "refs/heads/$refresh_branch:$remote_refresh_ref" \
    >>"$log_file" 2>&1 || {
      log_line "ERROR: could not fetch $refresh_remote/$refresh_branch; queue retained"
      return 1
    }
}

merge_refresh_ref() {
  local merge_ref="$1" description="$2" blocked_tmp
  git -C "$refresh_root" merge-base --is-ancestor "$merge_ref" HEAD 2>/dev/null && return 0
  if HIVE_SKIP_LLM_WIKI_POST_COMMIT=1 \
       git -C "$refresh_root" -c core.hooksPath=/dev/null \
       merge --no-edit "$merge_ref" >>"$log_file" 2>&1; then
    return 0
  fi

  HIVE_SKIP_LLM_WIKI_POST_COMMIT=1 \
    git -C "$refresh_root" -c core.hooksPath=/dev/null \
    merge --abort >>"$log_file" 2>&1 || true
  blocked_tmp="$state_dir/.publication-blocked.$$"
  {
    printf 'ref=%s\n' "$merge_ref"
    printf 'description=%s\n' "$description"
    printf 'recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$blocked_tmp"
  mv -f "$blocked_tmp" "$publication_blocked_file"
  log_line "ERROR: could not merge $description into $refresh_branch; queue retained"
  return 1
}

prepare_refresh_worktree() {
  local base_ref
  cleanup_refresh_worktree
  mkdir -p "$state_dir"
  sync_remote_refresh_ref || return 1
  sync_remote_base_ref || return 1
  base_ref="$(default_base_ref)"

  if git show-ref --verify --quiet "refs/heads/$refresh_branch"; then
    git worktree add "$refresh_root" "$refresh_branch" >>"$log_file" 2>&1 || return 1
  elif git show-ref --verify --quiet "$remote_refresh_ref"; then
    git worktree add -b "$refresh_branch" "$refresh_root" "$remote_refresh_ref" \
      >>"$log_file" 2>&1 || return 1
  else
    git worktree add -b "$refresh_branch" "$refresh_root" "$base_ref" >>"$log_file" 2>&1 || return 1
  fi

  if git show-ref --verify --quiet "$remote_refresh_ref"; then
    merge_refresh_ref "$remote_refresh_ref" "$refresh_remote/$refresh_branch" || return 1
  fi
  merge_refresh_ref "$base_ref" "$base_ref" || return 1
  rm -f -- "$publication_blocked_file"
}

publish_refresh_branch() {
  if [ "${LLM_WIKI_SKIP_PUSH:-}" = "1" ]; then
    log_line "refresh branch push skipped by LLM_WIKI_SKIP_PUSH"
    return 0
  fi
  if ! git remote get-url "$refresh_remote" >/dev/null 2>&1; then
    log_line "refresh branch kept locally; remote $refresh_remote is not configured"
    return 0
  fi

  if ! HIVE_SKIP_LLM_WIKI_POST_COMMIT=1 \
    run_with_timeout "${LLM_WIKI_GIT_PUSH_TIMEOUT:-120}" \
      git -C "$refresh_root" -c core.hooksPath=/dev/null \
      push "$refresh_remote" "HEAD:refs/heads/$refresh_branch" \
      >>"$log_file" 2>&1; then
    return 2
  fi
  git update-ref "$remote_refresh_ref" "$(git -C "$refresh_root" rev-parse HEAD)"
}

seed_untracked_local_wiki() {
  if [ -n "$(git -C "$refresh_root" ls-files -- wiki)" ] || \
     [ ! -e "$committing_tree/wiki" ]; then
    return 0
  fi
  if [ -L "$committing_tree/wiki" ] || [ ! -d "$committing_tree/wiki" ]; then
    log_line "ERROR: refusing to seed a non-directory or symlinked local wiki; queue retained"
    return 1
  fi

  mkdir -p "$refresh_root/wiki"
  cp -Rp "$committing_tree/wiki/." "$refresh_root/wiki/" >>"$log_file" 2>&1 || {
    log_line "ERROR: could not seed untracked local wiki; queue retained"
    return 1
  }
  log_line "seeded refresh branch from untracked local wiki snapshot"
}

wiki_only_changes() {
  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      wiki/*) ;;
      *) log_line "ERROR: refresh attempted non-wiki change: $path"; return 1 ;;
    esac
  done < <(
    {
      git -C "$refresh_root" diff --name-only
      git -C "$refresh_root" diff --cached --name-only
      git -C "$refresh_root" ls-files --others --exclude-standard --directory
      git -C "$refresh_root" ls-files --others --ignored --exclude-standard --directory
    } | sort -u
  )
}

run_refresh_agent() {
  local prompt="$1"
  if [ -n "${LLM_WIKI_REFRESH_CMD:-}" ]; then
    run_with_timeout "${LLM_WIKI_REFRESH_TIMEOUT:-1800}" \
      "$LLM_WIKI_REFRESH_CMD" "$refresh_root" "$prompt" >>"$log_file" 2>&1
    return $?
  fi

  local headless_agent timeout_seconds owner_config
  owner_config="$canonical_config"
  [ -f "$owner_config" ] || owner_config="$committing_tree/.llm-wiki/config.json"
  headless_agent="$(
    sed -nE 's/.*"headless_agent"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      "$owner_config" 2>/dev/null | head -n 1 || true
  )"
  case "$headless_agent" in
    codex)
      local add_dir_args=( --add-dir "$LLM_WIKI_QMD_CACHE_DIR" )
      run_with_timeout "${LLM_WIKI_CODEX_TIMEOUT:-1800}" \
        codex exec "${add_dir_args[@]}" -C "$refresh_root" "$prompt" >>"$log_file" 2>&1
      ;;
    claude)
      timeout_seconds="${LLM_WIKI_CLAUDE_TIMEOUT:-1800}"
      (cd "$refresh_root" && run_with_timeout "$timeout_seconds" \
        claude -p "$prompt" --allowedTools "Bash,Read,Edit,Write" \
        --add-dir "$refresh_root" --max-budget-usd 0.50) >>"$log_file" 2>&1
      ;;
    pi)
      timeout_seconds="${LLM_WIKI_PI_TIMEOUT:-1800}"
      (cd "$refresh_root" && run_with_timeout "$timeout_seconds" \
        pi -p --no-session --tools read,bash,edit,write,grep,find,ls \
        "$prompt") >>"$log_file" 2>&1
      ;;
    *)
      log_line "ERROR: unsupported or missing headless_agent in .llm-wiki/config.json"
      return 1
      ;;
  esac
}

snapshot_queue() {
  QUEUE_FILES=()
  local path
  if [ -n "$retry_selector" ] && [ "$retry_selector" != all ] && \
     [ -f "$pending_dir/$retry_selector" ]; then
    QUEUE_FILES+=("$pending_dir/$retry_selector")
  fi
  shopt -s nullglob
  for path in "$pending_dir"/*; do
    [ "${#QUEUE_FILES[@]}" -ge "$max_batch_sources" ] && break
    [ "$path" = "$pending_dir/$retry_selector" ] && continue
    [ -f "$path" ] && QUEUE_FILES+=("$path")
  done
  shopt -u nullglob
  [ "${#QUEUE_FILES[@]}" -gt 0 ]
}

local_source_commit() {
  local queued_sha="$1"
  git -C "$refresh_root" log -n 1 --format=%H --fixed-strings \
    --grep="LLM-Wiki-Source: $queued_sha" 2>/dev/null || true
}

source_receipted() {
  local queued_sha="$1" receipt_commit
  receipt_commit="$(git rev-parse --verify "refs/llm-wiki/receipts/$queued_sha^{commit}" 2>/dev/null || true)"
  if [ -n "$receipt_commit" ]; then
    publication_required || return 0
    if git show-ref --verify --quiet "$remote_refresh_ref" && \
       git merge-base --is-ancestor "$receipt_commit" "$remote_refresh_ref"; then
      return 0
    fi
  fi
  receipt_commit="$(
    local_source_commit "$queued_sha"
  )"
  [ -n "$receipt_commit" ] || return 1
  publication_required || return 0
  git show-ref --verify --quiet "$remote_refresh_ref" || return 1
  git merge-base --is-ancestor "$receipt_commit" "$remote_refresh_ref"
}

publish_retained_sources() {
  local file queued_sha queued_branch status
  local original=("${QUEUE_FILES[@]}") retained=() remaining=()
  for file in "${QUEUE_FILES[@]}"; do
    IFS=$'\t' read -r queued_sha queued_branch <"$file"
    if [ -n "$(local_source_commit "$queued_sha")" ]; then
      retained+=("$file")
    else
      remaining+=("$file")
    fi
  done
  [ "${#retained[@]}" -gt 0 ] || return 0

  QUEUE_FILES=("${retained[@]}")
  if publish_refresh_branch; then
    status=0
  else
    status=$?
    QUEUE_FILES=("${original[@]}")
    log_line "WARN: could not publish retained $refresh_branch commit; queue retained"
    return "$status"
  fi
  if ! write_source_receipts; then
    QUEUE_FILES=("${original[@]}")
    log_line "ERROR: could not write retained source receipts; queue retained"
    return 1
  fi
  rm -f -- "${retained[@]}"
  QUEUE_FILES=("${remaining[@]}")
  log_line "published ${#retained[@]} retained source(s) without another agent run"
}

write_source_receipts() {
  local refresh_head file queued_sha queued_branch
  refresh_head="$(git -C "$refresh_root" rev-parse HEAD)"
  {
    printf 'start\n'
    for file in "${QUEUE_FILES[@]}"; do
      IFS=$'\t' read -r queued_sha queued_branch <"$file"
      printf 'update refs/llm-wiki/receipts/%s %s\n' "$queued_sha" "$refresh_head"
      printf 'delete %s/%s\n' "$source_ref_prefix" "$queued_sha"
    done
    printf 'commit\n'
  } | run_with_timeout "${LLM_WIKI_GIT_REF_TIMEOUT:-5}" \
    git update-ref --stdin >>"$log_file" 2>&1
}

prune_receipted_queue_files() {
  local file queued_sha queued_branch
  local retained=()
  for file in "${QUEUE_FILES[@]}"; do
    IFS=$'\t' read -r queued_sha queued_branch <"$file"
    if source_receipted "$queued_sha"; then
      rm -f -- "$file"
      run_with_timeout "${LLM_WIKI_GIT_REF_TIMEOUT:-5}" \
        git update-ref -d "$source_ref_prefix/$queued_sha" \
        >>"$log_file" 2>&1 || true
      log_line "acknowledged previously committed source $queued_sha"
    else
      retained+=("$file")
    fi
  done
  QUEUE_FILES=("${retained[@]}")
}

record_batch_failure() {
  local file queued_sha queued_branch count max_attempts count_tmp unreceipted=0
  max_attempts="${LLM_WIKI_MAX_REFRESH_ATTEMPTS:-2}"
  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || max_attempts=2

  for file in "${QUEUE_FILES[@]}"; do
    [ -f "$file" ] || continue
    IFS=$'\t' read -r queued_sha queued_branch <"$file"
    if source_receipted "$queued_sha"; then
      rm -f -- "$file"
      run_with_timeout "${LLM_WIKI_GIT_REF_TIMEOUT:-5}" \
        git update-ref -d "$source_ref_prefix/$queued_sha" \
        >>"$log_file" 2>&1 || true
      log_line "acknowledged committed source $queued_sha after receipt write failure"
      continue
    fi
    unreceipted=1
  done
  if [ "$unreceipted" -eq 0 ]; then
    rm -f -- "$failure_count_file"
    reconcile_circuit_after_success
    return 0
  fi

  count="$(sed -n '1p' "$failure_count_file" 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  count="$((count + 1))"
  count_tmp="$state_dir/.consecutive-failures.$$"
  printf '%s\n' "$count" >"$count_tmp"
  mv -f "$count_tmp" "$failure_count_file"

  if [ "$count" -ge "$max_attempts" ]; then
    for file in "${QUEUE_FILES[@]}"; do
      [ -f "$file" ] || continue
      IFS=$'\t' read -r queued_sha queued_branch <"$file"
      mv -f -- "$file" "$failed_dir/$queued_sha"
    done
    printf 'failures:%s\n' "$count" >"$breaker_file"
    log_line "ERROR: automatic refresh disabled after $count consecutive failed batch(es); run .llm-wiki/post-commit-refresh.sh --retry-failed all"
  else
    log_line "refresh batch failed ($count/$max_attempts consecutive failures); queue retained"
  fi
}

process_queue_batch() {
  local sources="" file queued_sha queued_branch prompt short_source compile_runner
  local path display_path path_count omitted_paths
  local LC_ALL=C
  local commit_args=()
  prune_receipted_queue_files
  if [ "${#QUEUE_FILES[@]}" -eq 0 ]; then
    rm -f -- "$failure_count_file"
    return 0
  fi
  retained_status=0
  publish_retained_sources || retained_status=$?
  [ "$retained_status" -eq 0 ] || return "$retained_status"
  if [ "${#QUEUE_FILES[@]}" -eq 0 ]; then
    rm -f -- "$failure_count_file"
    return 0
  fi
  for file in "${QUEUE_FILES[@]}"; do
    IFS=$'\t' read -r queued_sha queued_branch <"$file"
    if ! git cat-file -e "${queued_sha}^{commit}" 2>/dev/null; then
      log_line "ERROR: refusing to acknowledge unavailable source commit $queued_sha"
      return 1
    fi
    commit_args+=( -m "LLM-Wiki-Source: $queued_sha" )
    sources+="- commit ${queued_sha} on branch ${queued_branch}; changed paths:\n"
    path_count=0
    omitted_paths=0
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if [ "$path_count" -lt "$max_paths_per_source" ]; then
        display_path="${path:0:max_path_bytes}"
        sources+="  - ${display_path}\n"
        path_count=$((path_count + 1))
      else
        omitted_paths=$((omitted_paths + 1))
      fi
    done < <(sed -n '2,$p' "$file")
    if [ "$omitted_paths" -gt 0 ]; then
      sources+="  - ... ${omitted_paths} additional changed path(s); inspect the commit directly\n"
    fi
  done

  prompt="$(cat <<PROMPT
Refresh this project's LLM wiki for the queued committed changes below.

You are running in the dedicated managed wiki-refresh worktree at ${refresh_root}.
This worktree is based on the current default branch. Inspect each source commit
with 'git show <sha>' and 'git show <sha>:<path>'; a source commit may belong to
another branch and need not be checked out here.

Queued sources:
$(printf '%b' "$sources")

Read .llm-wiki/config.json, AGENTS.md, CLAUDE.md, wiki/index.md, wiki/gaps.md,
and recent wiki/log.md entries first. Search main_wiki_path when configured.
Update only files under wiki/. Update affected architecture, command/API,
dependency, data-model, planning, or documentation pages as warranted by the
actual diffs. Update wiki/index.md only when coverage changes. Add one
wiki/log.d/<timestamp>-<slug>.md fragment for this coalesced batch without
editing compiled wiki/log.md. Record uncertainty in wiki/gaps.md. Do not run
qmd; the wrapper handles bounded index maintenance. Do not invent facts.
PROMPT
)"

  if ! run_refresh_agent "$prompt"; then
    log_line "ERROR: refresh agent failed; generated work discarded and queue retained"
    return 1
  fi
  wiki_only_changes || return 1

  compile_runner="$refresh_root/.llm-wiki/compile-log.sh"
  if [ ! -x "$compile_runner" ] && [ -x "$state_dir/compile-log.sh" ]; then
    compile_runner="$state_dir/compile-log.sh"
  fi
  if [ -x "$compile_runner" ]; then
    bash "$compile_runner" "$refresh_root" >>"$log_file" 2>&1 || {
      log_line "ERROR: changelog compilation failed; queue retained"
      return 1
    }
  else
    log_line "WARN: compile-log.sh missing; leaving wiki/log.md unchanged"
  fi
  wiki_only_changes || return 1

  if [ -e "$refresh_root/wiki" ] || [ -n "$(git -C "$refresh_root" ls-files -- wiki)" ]; then
    git -C "$refresh_root" add -f -A -- wiki >>"$log_file" 2>&1 || return 1
  fi
  wiki_only_changes || return 1
  if ! git -C "$refresh_root" diff --cached --quiet; then
    short_source="$(basename "${QUEUE_FILES[0]}")"
    if ! HIVE_SKIP_LLM_WIKI_POST_COMMIT=1 \
         git -C "$refresh_root" -c core.hooksPath=/dev/null \
         commit --only -m "docs(wiki): queued refresh for ${#QUEUE_FILES[@]} commit(s) at ${short_source:0:12}" \
         "${commit_args[@]}" \
         -- wiki >>"$log_file" 2>&1; then
      log_line "ERROR: refresh commit failed; queue retained"
      return 1
    fi
  elif publication_required; then
    short_source="$(basename "${QUEUE_FILES[0]}")"
    if ! HIVE_SKIP_LLM_WIKI_POST_COMMIT=1 \
         git -C "$refresh_root" -c core.hooksPath=/dev/null \
         commit --allow-empty \
         -m "docs(wiki): acknowledge ${#QUEUE_FILES[@]} commit(s) at ${short_source:0:12}" \
         "${commit_args[@]}" >>"$log_file" 2>&1; then
      log_line "ERROR: empty refresh acknowledgement commit failed; queue retained"
      return 1
    fi
  fi

  if ! publish_refresh_branch; then
    log_line "WARN: could not push $refresh_branch to $refresh_remote; generated commit and queue retained"
    return 2
  fi

  if ! write_source_receipts; then
    log_line "ERROR: could not write source receipts; queue retained"
    return 1
  fi
  rm -f -- "${QUEUE_FILES[@]}"
  rm -f -- "$failure_count_file"
  ( cd "$refresh_root" && run_qmd update ) >>"$log_file" 2>&1 || true
  ( cd "$refresh_root" && run_qmd embed --max-docs-per-batch 64 --max-batch-mb 64 ) >>"$log_file" 2>&1 || true
  return 0
}

recover_queue_temps

# A scheduled drain is a queue consumer, never a source-discovery trigger.
# Check for work before pinning sources or preparing the managed worktree so an
# idle timer cannot mutate refresh state. Circuit-blocked work is deliberately
# pinned first, preserving queued commits until a later bounded retry.
if [ "$drain_mode" -eq 1 ]; then
  if ! pending_sources_present; then
    log_line "scheduled drain skipped; no queued sources"
    exit 0
  fi
fi

if ! pin_queued_sources; then
  open_source_pin_circuit
  if [ -n "$retry_selector" ]; then
    printf 'llm-wiki: retry failed while pinning queued source commits\n' >&2
    exit 1
  fi
  exit 0
fi
if [ -n "$retry_selector" ]; then
  if ! restore_failed_sources; then
    exit 1
  fi
  rm -f -- "$publication_blocked_file"
# A worker can pass the pre-lock check and then wait while its predecessor opens
# the circuit. Re-check under the lock before any worktree or provider action.
elif [ -f "$breaker_file" ]; then
  log_line "automatic refresh circuit remains open; queued sources retained"
  exit 0
elif [ -f "$publication_blocked_file" ]; then
  log_line "automatic refresh publication remains blocked by a merge conflict; queued sources retained; run --retry-failed all after resolving the branch"
  exit 0
elif open_backlog_circuit_if_needed; then
  exit 0
fi
if ! pending_sources_present; then
  exit 0
fi
if ! acquire_global_provider_lock; then
  log_line "refresh remains queued; machine-wide provider lock was busy"
  if [ -n "$retry_selector" ]; then
    printf 'llm-wiki: retry deferred; machine-wide refresh worker is busy\n' >&2
    exit 1
  fi
  exit 0
fi
configure_qmd_environment
if ! prepare_refresh_worktree; then
  log_line "ERROR: could not prepare managed refresh worktree; queue retained"
  if [ -n "$retry_selector" ]; then
    printf 'llm-wiki: retry failed while preparing the refresh worktree\n' >&2
    exit 1
  fi
  exit 0
fi
if ! seed_untracked_local_wiki; then
  if [ -n "$retry_selector" ]; then
    printf 'llm-wiki: retry failed while seeding the local wiki snapshot\n' >&2
    exit 1
  fi
  exit 0
fi

drain_batch_count=0
max_drain_batches="$(positive_integer_or_default "${LLM_WIKI_MAX_DRAIN_BATCHES:-3}" 3)"
while snapshot_queue; do
  batch_status=0
  process_queue_batch || batch_status=$?
  if [ "$batch_status" -eq 2 ]; then
    log_line "refresh publication deferred; it will retry without opening the provider circuit"
    if [ -n "$retry_selector" ]; then
      printf 'llm-wiki: retry generated the refresh but publication is still deferred; see %s\n' "$log_file" >&2
      exit 1
    fi
    exit 0
  elif [ "$batch_status" -ne 0 ]; then
    record_batch_failure
    if [ -n "$retry_selector" ]; then
      printf 'llm-wiki: retry failed; see %s\n' "$log_file" >&2
      exit 1
    fi
    exit 0
  fi
  drain_batch_count=$((drain_batch_count + 1))
  if [ "$drain_mode" -ne 1 ] || [ "$drain_batch_count" -ge "$max_drain_batches" ]; then
    break
  fi
  sleep "${LLM_WIKI_DRAIN_SETTLE_SECONDS:-1}"
done

reconcile_circuit_after_success

if [ -n "$retry_selector" ]; then
  remaining_sources="$(pending_source_count)"
  remaining_failed="$(failed_source_count)"
  if [ -f "$breaker_file" ]; then
    printf 'llm-wiki: bounded refresh batch completed; %s queued and %s quarantined source(s) remain, so the circuit stays open\n' \
      "$remaining_sources" "$remaining_failed"
    printf 'llm-wiki: rerun .llm-wiki/post-commit-refresh.sh --retry-failed all for the next bounded batch\n'
  elif [ "$remaining_sources" -gt 0 ]; then
    printf 'llm-wiki: bounded refresh batch completed; %s source(s) queued during the run\n' "$remaining_sources"
  else
    printf 'llm-wiki: queued refresh completed successfully\n'
  fi
fi

main_checkout="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
project_name="$(basename "${main_checkout:-$committing_tree}")"
for sync_dir in "$HOME/wikis/.sync-needed" "$(dirname "${main_checkout:-$committing_tree}")/wikis/.sync-needed"; do
  if [ -d "$(dirname "$sync_dir")" ]; then
    mkdir -p "$sync_dir"
    touch "$sync_dir/$project_name"
  fi
done

exit 0
