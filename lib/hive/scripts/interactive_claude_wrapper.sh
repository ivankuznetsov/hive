#!/bin/sh
set -eu

usage() {
  echo "usage: interactive_claude_wrapper.sh --cwd DIR [--add-dir DIR ...] [--bin PATH]" >&2
  exit 64
}

cwd=""
bin="claude"
add_dir_count=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd)
      [ "$#" -ge 2 ] || usage
      cwd=$2
      shift 2
      ;;
    --add-dir)
      [ "$#" -ge 2 ] || usage
      add_dir_count=$((add_dir_count + 1))
      eval "add_dir_$add_dir_count=\$2"
      shift 2
      ;;
    --bin)
      [ "$#" -ge 2 ] || usage
      bin=$2
      shift 2
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

set -- "$bin"
i=1
while [ "$i" -le "$add_dir_count" ]; do
  eval "dir=\${add_dir_$i}"
  set -- "$@" "--add-dir" "$dir"
  i=$((i + 1))
done

exec "$@"
