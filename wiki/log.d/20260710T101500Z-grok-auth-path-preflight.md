# 2026-07-10 — Grok preflight honors the CLI credential path

**Action:** Grok agent preflight and login-status probes now resolve
`GROK_AUTH_PATH` before `GROK_HOME` and the default `~/.grok/auth.json`.
An explicit but missing path fails closed instead of falling back to a different
refresh-token chain. This lets containerized workflows share one canonical
credential file and adjacent refresh lock without creating a compatibility
copy solely for Hive.

**Tests:** Added focused coverage for direct-path precedence, missing-path
failure, login-status parity, and explicit auth locations in runners where the
operating-system home directory cannot be resolved.

**Wiki pages updated:** `wiki/modules/agent_profile.md`,
`wiki/commands/web.md`, and `wiki/gaps.md`.

**Docs updated:** `docs/architecture.md` and
`docs/notes/headless-agent-cli-matrix.md`.
