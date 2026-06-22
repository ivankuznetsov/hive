#!/bin/sh
set -eu

usage() {
  echo "usage: interactive_claude_wrapper.sh --cwd DIR [--add-dir DIR ...] [--permission-mode MODE | --dangerously-skip-permissions] [--mcp-config FILE] [--strict-mcp-config] [--allowedTools TOOLS] [--model MODEL] [--effort LEVEL] [--bin PATH]" >&2
  exit 64
}

cwd=""
bin="claude"

# Append parsed --add-dir pairs back onto $@ as we shift each input
# argument off. After the loop, $@ holds exactly the --add-dir DIR
# pairs we want to forward — no `eval` indirection, so values like
# `$(...)` or backticks cannot be re-parsed under shell rules.
remaining=$#
while [ "$remaining" -gt 0 ]; do
  arg=$1
  shift
  remaining=$((remaining - 1))
  case "$arg" in
    --cwd)
      [ "$remaining" -ge 1 ] || usage
      cwd=$1
      shift
      remaining=$((remaining - 1))
      ;;
    --add-dir)
      [ "$remaining" -ge 1 ] || usage
      set -- "$@" "--add-dir" "$1"
      shift
      remaining=$((remaining - 1))
      ;;
    --permission-mode)
      [ "$remaining" -ge 1 ] || usage
      set -- "$@" "--permission-mode" "$1"
      shift
      remaining=$((remaining - 1))
      ;;
    --dangerously-skip-permissions)
      set -- "$@" "--dangerously-skip-permissions"
      ;;
    --allowedTools)
      [ "$remaining" -ge 1 ] || usage
      set -- "$@" "--allowedTools" "$1"
      shift
      remaining=$((remaining - 1))
      ;;
    --mcp-config)
      [ "$remaining" -ge 1 ] || usage
      set -- "$@" "--mcp-config" "$1"
      shift
      remaining=$((remaining - 1))
      ;;
    --strict-mcp-config)
      set -- "$@" "--strict-mcp-config"
      ;;
    --model)
      [ "$remaining" -ge 1 ] || usage
      set -- "$@" "--model" "$1"
      shift
      remaining=$((remaining - 1))
      ;;
    --effort)
      [ "$remaining" -ge 1 ] || usage
      set -- "$@" "--effort" "$1"
      shift
      remaining=$((remaining - 1))
      ;;
    --bin)
      [ "$remaining" -ge 1 ] || usage
      bin=$1
      shift
      remaining=$((remaining - 1))
      ;;
    *)
      usage
      ;;
  esac
done

if [ -z "$cwd" ]; then
  echo "interactive_claude_wrapper.sh: --cwd is required" >&2
  usage
fi

cd "$cwd"

unset ANTHROPIC_API_KEY
unset CLAUDE_API_KEY
# Threat model: hive passes the Screenote base_url to claude explicitly (and
# the OAuth token rides a 0600 temp MCP config that's deleted right after the
# run — it never enters this environment). Unsetting HIVE_SCREENOTE_BASE_URL
# stops an operator's exported value from silently overriding hive's chosen
# base_url for the child — a redundant, unvalidated second source. Do NOT
# delete this `unset` thinking the explicit pass-through makes it a no-op.
unset HIVE_SCREENOTE_BASE_URL

exec "$bin" "$@"
