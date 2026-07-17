#!/usr/bin/env bash
# Clear only the execute marker already verified by the host-side recovery
# classifier. Kept as a small command so the exact Hive invocation is testable.
set -uo pipefail

TASK_DIR="${1:-}"
MARKER_ID="${2:-}"
JSON_OUT="${3:-/dev/stdout}"
ERR_OUT="${4:-/dev/stderr}"
TASK_MD="$TASK_DIR/task.md"

ERROR_LINE="$(grep '<!-- ERROR ' "$TASK_MD" 2>/dev/null | tail -1)"
if [ ! -d "$TASK_DIR" ] || [ -z "$MARKER_ID" ] || \
   [[ "$ERROR_LINE" != *"reason=implementer_failed"* ]] || \
   [[ "$ERROR_LINE" != *"marker_id=$MARKER_ID"* ]]; then
  echo "HB_ERROR execute_resume_preflight_failed" >>"$ERR_OUT"
  exit 5
fi

hive markers clear "$TASK_DIR" --name ERROR \
  --match-attr "marker_id=$MARKER_ID,reason=implementer_failed" --json \
  >"$JSON_OUT" 2>>"$ERR_OUT"
