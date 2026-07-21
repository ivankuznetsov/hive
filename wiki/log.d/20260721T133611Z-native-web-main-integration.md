## [2026-07-21T13:36:11Z] native web — reconcile the current main integration

- Kept current-main Rails controllers, status/mobile behavior, and repository
  models while replaying the native-web setup and delivery review fixes.
- Kept temporary asset compilation on the canonical
  `HIVE_WEB_STORAGE_DIR` contract after the legacy alias migration.
- Routed Rails task-diff and repository-clone timeout constants through the
  canonical environment resolver instead of reading deprecated aliases.
- Isolated both canonical and legacy loopback variables in integration tests
  so the host-authorization gate cannot leak state between requests.
- Native authenticated installs now retain the `Hive web` identity, verified
  local installs use `hive`, and the container-only precompiled-assets marker
  preserves the `hivebox` identity.
- Consent-approved install guidance and the packaged-layout fixture now pass
  `--yes`; the canonical Hive skill and regenerated OpenClaw projection explain
  the default managed-service mutation, opt-out, and read-only status contract.
- `hive web install --json` retains one versioned error document through both
  bundle and service-install failures, while read-only status performs one
  health probe and mutating setup keeps its bounded retry window.
- Linux without systemd-user remains a truthful successful platform exception:
  lifecycle/readiness fields stay false, recovery guidance is explicit, and
  genuine install or active-not-ready failures remain nonzero.
- Release verification now builds the managed web archive once, runs the
  installed proven gem through setup against those exact digest-pinned bytes,
  and carries the same archive forward to signing and publication.
- Foreground and managed-service launches now share the same bind-aware local
  loopback decision; explicit non-loopback binds cannot inherit the local
  no-auth/Host-lockdown mode.
- Regression coverage now drives real Linux/macOS restart commands, the
  non-loopback production Host branch, and Docker installer argument boundaries
  for data paths containing spaces.
