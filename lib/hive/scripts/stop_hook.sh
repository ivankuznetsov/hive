#!/usr/bin/env bash
set -eu

: "${HIVE_TASK_STAGE_DIR:?HIVE_TASK_STAGE_DIR required}"

cat > "${HIVE_TASK_STAGE_DIR}/result.json"
touch "${HIVE_TASK_STAGE_DIR}/.done"
