#!/bin/sh
set -eu

: "${HIVE_TASK_STAGE_DIR:?HIVE_TASK_STAGE_DIR required}"

# Buffer stdin first so an empty payload doesn't silently produce a
# zero-byte result.json — that file is forensic evidence, and an empty
# write is indistinguishable from "hook ran but Claude Code passed no
# data". If stdin is empty, write an explicit sentinel JSON object
# instead so the operator can tell the difference.
result_path="${HIVE_TASK_STAGE_DIR}/result.json"
payload=$(cat)
if [ -z "$payload" ]; then
  printf '%s\n' '{"hive_stop_hook":"empty_stdin"}' > "$result_path"
else
  printf '%s' "$payload" > "$result_path"
fi
touch "${HIVE_TASK_STAGE_DIR}/.done"
