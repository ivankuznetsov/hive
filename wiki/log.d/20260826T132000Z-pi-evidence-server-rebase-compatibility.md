# Pi evidence server survives runtime-policy rebases

- 2026-08-26 · `lib/hive/agent_support/pi/runtime.rb`,
  `lib/hive/artifacts/project_command_sandbox.rb` · PR #1234 rebase repair

## What changed

The Pi evidence runtime again registers and admits `evidence_server` for visual
evidence. The controller-owned `hive evidence server` gateway was already
implemented and documented, but the moved Pi runtime extension omitted the
tool after a runtime-policy extraction, leaving non-Hive visual producers
without the capability named by their prompt.

`ProjectCommandSandbox` now supplies the current required exclusions when it
asks `RuntimePolicy` for bubblewrap parent directories. This keeps the
controller-owned terminal boundary compatible with the extracted shared helper
and preserves the existing `/usr`, `/etc`, `/proc`, `/dev`, and `/tmp` mounts.

## Verification

- Pi evidence-runtime tool and cleanup tests
- Capture-toolkit, project-server, project-sandbox, terminal-recorder,
  evidence-command, artifacts-stage, drop-command, and worktree unit tests
