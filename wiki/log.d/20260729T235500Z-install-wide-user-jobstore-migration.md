---
date: 2026-07-29
area: refactor-patrol, migration, packaging, testing
---

# Migrate every known OS user's JobStore during shared-package upgrades

- Replaced the invoking-user completion model with a root-only host
  coordinator over fixed NSS-home anchors and a root-owned exact custom-profile
  inventory. The coordinator binds the installed candidate and account/home
  identity, rechecks the complete NSS tuple immediately before execution, then
  drops groups, gid, and uid before reading a registry or touching project
  state.
- Split machine aggregate evidence from strict per-profile receipts, with
  distinct OS-user/profile counts, inventory closure, candidate digest, shared
  root and identity-drift refusal, isolated retryable rows, and no legacy
  receipt compatibility path.
- Added AUR activation plus an hourly `--resume` system timer for inactive
  users, avoiding unconditional hourly force-sweeps. Direct non-root and
  Homebrew installs explicitly report their current-user limit and the
  administrator all-user command; first use remains a fallback only.
- Persisted exact `HIVE_HOME`/XDG roots in newly rendered user daemon units and
  suppressed unrelated LLM-wiki startup repair during the migration command.
- Added a permanent Linux merge gate that converts released-v2 projects under
  three distinct kernel UIDs using default, `HIVE_HOME`, and split-XDG profiles
  and proves the dropped identities own all resulting state.
