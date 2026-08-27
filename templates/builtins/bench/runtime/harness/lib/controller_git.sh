#!/usr/bin/env bash
set -eu

: "${HB_CONTROLLER_ORIGIN:?sealed controller Git requires HB_CONTROLLER_ORIGIN}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=5
export GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
export GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null
export GIT_CONFIG_KEY_2=core.fsmonitor GIT_CONFIG_VALUE_2=false
export GIT_CONFIG_KEY_3=credential.helper GIT_CONFIG_VALUE_3=''
export GIT_CONFIG_KEY_4=protocol.ext.allow GIT_CONFIG_VALUE_4=never

# A candidate-controlled .git/config can put its pushurl before command-scope
# values. Resolve origin ourselves instead of asking that configuration stack.
args=("$@")
index=0
while [ "$index" -lt "${#args[@]}" ]; do
  case "${args[$index]}" in
    -C|-c|--config-env|--git-dir|--work-tree|--namespace) index=$((index + 2)) ;;
    -C*|-c*|--config-env=*|--git-dir=*|--work-tree=*|--namespace=*|-*) index=$((index + 1)) ;;
    *) break ;;
  esac
done
if [ "${args[$index]:-}" = "remote" ] &&
   [ "${args[$((index + 1))]:-}" = "get-url" ] &&
   [ "${args[${#args[@]} - 1]:-}" = "origin" ]; then
  printf '%s\n' "$HB_CONTROLLER_ORIGIN"
  exit 0
fi
if [ "${args[$index]:-}" = "push" ]; then
  for ((position = index + 1; position < ${#args[@]}; position++)); do
    if [ "${args[$position]}" = "origin" ]; then
      args[position]="$HB_CONTROLLER_ORIGIN"
      break
    fi
  done
fi

case "$(id -u)" in
  0)
    exec setpriv --reuid=1000 --regid=1000 --init-groups --no-new-privs \
      --bounding-set=-all --inh-caps=-all --ambient-caps=-all /usr/bin/git "${args[@]}"
    ;;
  1000) exec /usr/bin/git "${args[@]}" ;;
  *) echo "sealed controller Git requires uid 0 or 1000" >&2; exit 126 ;;
esac
