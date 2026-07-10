## 2026-07-10 — Require absolute direct Grok auth paths

**Action:** `GROK_AUTH_PATH` must now be absolute. This guarantees that Hive's
parent-process preflight and a Grok child launched with a different working
directory resolve the same credential file. Relative direct paths fail closed
in both preflight and login-status checks.

**Tests:** Added focused preflight and login-status coverage for relative paths.

**Wiki page updated:** `wiki/modules/agent_profile.md`.

**Docs updated:** `docs/architecture.md` and
`docs/notes/headless-agent-cli-matrix.md`.
