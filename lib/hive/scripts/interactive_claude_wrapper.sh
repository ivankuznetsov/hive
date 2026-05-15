#!/bin/sh
set -eu

usage() {
  echo "usage: interactive_claude_wrapper.sh --cwd DIR [--add-dir DIR ...] [--bin PATH]" >&2
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

exec "$bin" "$@"
