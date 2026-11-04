#!/usr/bin/env bash
# Runs a command inside an ephemeral, resource-capped hive-bench runner
# container. Fails CLOSED (exit 70) if Docker is unavailable or isolation
# cannot be established — a benchmark score is never produced from an
# un-isolated run (mirrors agent-reviewer-eval's posture).
#
# Usage:
#   hb_isolated <mode> <work_dir> <cmd...>
#     mode=gate  -> --network none, read-only except /work (no agent, no model)
#     mode=gen   -> egress allowed to the model API; HOME on the tmpfs and provider
#                   credentials selected by HB_API_KEYS (one API variable name,
#                   or explicitly empty with exactly one OAuth path). pi/claude
#                   run non-root with all caps
#                   dropped; codex needs uid 0 + relaxed seccomp (its app-server
#                   refuses otherwise) and chowns /work back to the host uid.
#
# Network note: true egress allowlisting on plain Docker needs a proxy/firewall
# (in CI, GitHub's runner egress firewall or StepSecurity Harden-Runner). v1
# enforces it there; locally, `gen` uses the default bridge and relies on the
# read-only rootfs, dropped capabilities, and resource caps. gen does NOT silently
# fail open: the operator must set HB_ALLOW_EGRESS=1 to acknowledge outbound
# network. The `gate` mode's --network none is always enforced.
set -euo pipefail

HB_FAIL_ISOLATION=70

hb_isolated() {
  local mode="$1" work="$2"; shift 2
  command -v docker >/dev/null 2>&1 || { echo "hive-bench: docker unavailable — failing closed" >&2; exit "$HB_FAIL_ISOLATION"; }
  [ -d "$work" ] || { echo "hive-bench: work dir missing — failing closed" >&2; exit "$HB_FAIL_ISOLATION"; }
  # `docker run -v` needs an absolute source; the caller may pass a relative path.
  work="$(cd "$work" && pwd)" || { echo "hive-bench: cannot resolve work dir — failing closed" >&2; exit "$HB_FAIL_ISOLATION"; }

  local net_args=() env_args=() mount_args=() extra_args=()
  # Default hardened posture (gate + pi/claude gen): non-root, all caps dropped.
  local sec_args=(--cap-drop ALL --security-opt no-new-privileges)

  case "$mode" in
    gate)
      net_args=(--network none)
      env_args=(-e HOME=/tmp)
      ;;
    gen)
      # Egress must be explicitly acknowledged — we never fail open silently.
      [ "${HB_ALLOW_EGRESS:-}" = "1" ] || {
        echo "hive-bench: gen mode requires HB_ALLOW_EGRESS=1 to permit model-API egress — failing closed" >&2
        exit "$HB_FAIL_ISOLATION"
      }
      net_args=()  # default bridge; egress allowlist applied by the CI firewall layer
      # Unset is not an empty OAuth allowlist. Declarations contain names only.
      if [ "${HB_API_KEYS+x}" != x ]; then
        echo "hive-bench: gen requires HB_API_KEYS to be one supported API variable or explicitly empty for one OAuth file — failing closed" >&2
        exit "$HB_FAIL_ISOLATION"
      fi
      case "$HB_API_KEYS" in
        OPENROUTER_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY|"") ;;
        *)
          echo "hive-bench: gen requires HB_API_KEYS to be one supported API variable or explicitly empty for one OAuth file — failing closed" >&2
          exit "$HB_FAIL_ISOLATION"
          ;;
      esac
      if [ -n "$HB_API_KEYS" ]; then
        if [ -n "${HB_CODEX_AUTH:-}" ] || [ -n "${HB_CLAUDE_AUTH:-}" ]; then
          echo "hive-bench: gen credentials require one API variable without OAuth, or exactly one regular OAuth file — failing closed" >&2
          exit "$HB_FAIL_ISOLATION"
        fi
        local k="$HB_API_KEYS"
        if [ -n "${!k:-}" ]; then
          env_args+=(-e "$k")
        fi
      elif [ -n "${HB_CODEX_AUTH:-}" ] && [ -z "${HB_CLAUDE_AUTH:-}" ] && [ -f "$HB_CODEX_AUTH" ]; then
        : # Exactly one existing regular file; Docker must never create a source.
      elif [ -n "${HB_CLAUDE_AUTH:-}" ] && [ -z "${HB_CODEX_AUTH:-}" ] && [ -f "$HB_CLAUDE_AUTH" ]; then
        :
      else
        echo "hive-bench: gen credentials require one API variable without OAuth, or exactly one regular OAuth file — failing closed" >&2
        exit "$HB_FAIL_ISOLATION"
      fi
      if [ -n "${HB_CODEX_AUTH:-}" ]; then
        # codex's in-process app-server requires uid 0 + relaxed seccomp, and
        # refuses a codex_home under /tmp — so it gets root, a writable /root, and
        # an unconfined seccomp profile. Weaker than the non-root posture above,
        # but still ephemeral, fs-isolated to /work, resource-capped and egress-
        # gated; the agent chowns /work back to the host uid (see codex_command).
        sec_args=(--user 0:0 --security-opt seccomp=unconfined)
        env_args+=(-e HOME=/root)
        extra_args+=(--tmpfs /root)
        mount_args+=(-v "${HB_CODEX_AUTH}:/root/.codex/auth.json:ro")
      else
        # pi/claude: non-root, HOME on the tmpfs; mount claude's OAuth creds ro.
        env_args+=(-e HOME=/tmp)
        if [ -n "${HB_CLAUDE_AUTH:-}" ]; then
          mount_args+=(-v "${HB_CLAUDE_AUTH}:/tmp/.claude/.credentials.json:ro")
        fi
      fi
      ;;
    *)
      echo "hive-bench: unknown isolation mode — failing closed" >&2; exit "$HB_FAIL_ISOLATION" ;;
  esac

  docker run --rm \
    ${net_args[@]+"${net_args[@]}"} \
    ${env_args[@]+"${env_args[@]}"} \
    ${mount_args[@]+"${mount_args[@]}"} \
    ${sec_args[@]+"${sec_args[@]}"} \
    ${extra_args[@]+"${extra_args[@]}"} \
    --cpus "${HB_CPUS:-8}" --memory "${HB_MEMORY:-16g}" --pids-limit "${HB_PIDS:-4096}" \
    --read-only --tmpfs /tmp \
    -v "$work:/work" \
    "${HB_RUNNER_IMAGE:-hive-bench-runner:latest}" \
    "$@"
}

# Allow sourcing (for tests) or direct invocation.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  hb_isolated "$@"
fi
