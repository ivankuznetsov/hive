## 2026-07-10 — Require absolute Grok auth overrides

**Action:** `GROK_AUTH_PATH` and explicit `GROK_HOME` values must now be
absolute. This guarantees that Hive's
parent-process preflight and a Grok child launched with a different working
directory resolve the same credential file and state directory. Relative path
overrides fail closed in both preflight and login-status checks, even when an
API key is present.

**Tests:** Added focused preflight and login-status coverage for relative paths
and API-key bypass attempts.

**Wiki page updated:** `wiki/modules/agent_profile.md`.

**Docs updated:** `docs/architecture.md` and
`docs/notes/headless-agent-cli-matrix.md`.
