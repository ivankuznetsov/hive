#!/usr/bin/env bash
# hive-bench runner entrypoint.
#
# Docker appends the `docker run <image> <cmd...>` arguments to the ENTRYPOINT
# argv. The runner must honor BOTH command protocols its callers use:
#   - a single shell command string — isolation.sh's gen mode and the gate's
#     gate_exec forward `hb_isolated <mode> <work> "cd /work && …"`;
#   - an exec-style argv array — `hb_isolated <mode> <work> <cmd...>` documents
#     argv forwarding, and isolation.sh passes "$@" verbatim, so e.g.
#     `hb_isolated gate /work sh -c '…'` must run `sh` with `-c '…'`.
# The previous bare `ENTRYPOINT ["/bin/bash", "-lc"]` broke the second
# protocol: bash's `-c` consumed only the FIRST appended argument as its
# command string and the remaining arguments became unused shell positional
# parameters — a multi-argument command silently truncated to its first word.
#
# Dispatch:
#   0 args        -> interactive login shell (docker run -it debugging)
#   1 arg         -> login-shell `-c` on the command string (unchanged protocol)
#   2+ args       -> login-shell environment, then exec the argv array verbatim
#                    (no shell re-parsing, no word splitting)
set -euo pipefail
if [ "$#" -eq 0 ]; then
  exec /bin/bash -l
elif [ "$#" -eq 1 ]; then
  exec /bin/bash -l -c "$1"
else
  # Re-exec through a login bash so the environment matches the string
  # protocol (image PATH, bundle env), then exec the ORIGINAL argv untouched.
  # The first word after `-c 'exec "$@"'` is only the shell's $0 placeholder.
  exec /bin/bash -l -c 'exec "$@"' hb-entrypoint "$@"
fi
