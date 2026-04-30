#!/usr/bin/env bash
set -euo pipefail

case "${HIVE_E2E_STAGE:-}" in
  brainstorm)
    printf '# Brainstorm\n\n<!-- COMPLETE -->\n' > "$HIVE_FAKE_CLAUDE_WRITE_FILE"
    ;;
  plan)
    printf '# Plan\n\n<!-- COMPLETE -->\n' > "$HIVE_FAKE_CLAUDE_WRITE_FILE"
    ;;
esac
