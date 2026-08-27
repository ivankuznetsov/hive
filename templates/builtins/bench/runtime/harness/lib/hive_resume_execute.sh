#!/usr/bin/env bash
# Resume only the execute marker already verified by the host-side recovery
# classifier. Dirty-residue recovery delegates completion to Hive's guarded
# native boundary; other retryable failures clear only the verified marker.
set -uo pipefail

TASK_DIR="${1:-}"
MARKER_ID="${2:-}"
JSON_OUT="${3:-/dev/stdout}"
ERR_OUT="${4:-/dev/stderr}"
WORK_ROOT="${HB_WORK_ROOT:-/work}"
TASK_MD="$TASK_DIR/task.md"
RECOVERY_OUT="$WORK_ROOT/.hb/execute-residue-recovery.json"
RECOVERED_SENTINEL="$WORK_ROOT/.hb/execute-residue-recovered"

ERROR_LINE="$(grep '<!-- ERROR ' "$TASK_MD" 2>/dev/null | tail -1)"
REASON="$(printf '%s\n' "$ERROR_LINE" | sed -n 's/.* reason=\([^ >]*\).*/\1/p')"
if [ ! -d "$TASK_DIR" ] || [ -z "$MARKER_ID" ] || \
   [[ ! "$REASON" =~ ^(implementer_failed|provider_error|dirty_worktree)$ ]] || \
   [[ "$ERROR_LINE" != *"marker_id=$MARKER_ID"* ]]; then
  echo "HB_ERROR execute_resume_preflight_failed" >>"$ERR_OUT"
  exit 5
fi

if [ "$REASON" = "dirty_worktree" ]; then
  mkdir -p "$WORK_ROOT/.hb" || exit 5
  rm -f "$RECOVERY_OUT" "$RECOVERED_SENTINEL"
  WORKTREE="$WORK_ROOT/.worktrees/$(basename "$TASK_DIR")"
  if [ ! -d "$WORKTREE" ]; then
    echo "HB_ERROR execute_resume_worktree_still_dirty" >>"$ERR_OUT"
    exit 5
  fi
  WORKTREE_STATUS="$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>>"$ERR_OUT")"
  WORKTREE_STATUS_RC=$?
  if [ "$WORKTREE_STATUS_RC" -ne 0 ]; then
    echo "HB_ERROR execute_resume_worktree_still_dirty" >>"$ERR_OUT"
    exit 5
  fi
  if [ -n "$WORKTREE_STATUS" ]; then
    if ! git -C "$WORKTREE" config user.email bench@hive-bench || \
       ! git -C "$WORKTREE" config user.name hive-bench; then
      echo "HB_ERROR execute_resume_worktree_recovery_failed" >>"$ERR_OUT"
      exit 5
    fi
  fi
  if ! hive worktree commit-residue "$TASK_DIR" --complete-execute --json \
    >"$RECOVERY_OUT" 2>>"$ERR_OUT"; then
    echo "HB_ERROR execute_resume_worktree_recovery_failed" >>"$ERR_OUT"
    exit 5
  fi
  if ! ruby -rjson -e \
    'exit(JSON.parse(File.read(ARGV.fetch(0)))["execute_completed"] == true ? 0 : 1)' \
    "$RECOVERY_OUT"; then
    echo "HB_ERROR execute_resume_completion_missing" >>"$ERR_OUT"
    exit 5
  fi

  WORKTREE_STATUS="$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>>"$ERR_OUT")"
  WORKTREE_STATUS_RC=$?
  if [ "$WORKTREE_STATUS_RC" -ne 0 ] || [ -n "$WORKTREE_STATUS" ]; then
    echo "HB_ERROR execute_resume_worktree_still_dirty" >>"$ERR_OUT"
    exit 5
  fi
  : >"$RECOVERED_SENTINEL"
  exit 0
fi

hive markers clear "$TASK_DIR" --name ERROR \
  --match-attr "marker_id=$MARKER_ID,reason=$REASON" --json \
  >"$JSON_OUT" 2>>"$ERR_OUT"
