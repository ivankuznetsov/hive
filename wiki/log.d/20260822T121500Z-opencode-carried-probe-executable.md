---
created: 2026-08-22
tags: [agent-cli-runtime, opencode, probe, patrol-fix]
---

# OpenCode probe carries the caller-resolved executable

Patrol finding
`pr-998-05225eb9e83d4386:consolidate-opencode-executable-resolution-ownership`
(generation 1) identified that `OpenCode::Overlay.prepare!` resolved the
executable, then re-encoded it as the `AGENT_CLI_RUNTIME_OPENCODE_BIN`
environment override to reach `OpenCode::Probe.call!`, because the probe had no
parameter for it. The probe then re-resolved the executable three separate
times: `profile.binary_installed?`, the `BinaryUnavailable` message, and the
result's `executable` (from the filtered child environment).

## Change

- `ProbeRequest` gained an optional `executable:` field.
- `OpenCode::Probe.call!/call` resolve the executable once
  (`request.executable || profile.bin(env:)`) and thread it through the
  installation check, version check, all inspection captures, and the reported
  result executable — including the fail-soft path.
- `Profile#binary_installed?`, `#check_version!`, and `#capture_local` accept an
  optional `executable:` override; without it, environment-based resolution is
  unchanged for legacy callers.
- `prepare!` passes the resolved executable on the probe request and no longer
  mutates the probe environment.

## Invariants

- The executable the probe validated and reports is exactly the executable the
  compiled invocation runs.
- Callers with an already-resolved executable never depend on environment key
  precedence to communicate it to the probe.
