## 2026-07-18 — Harden Honeycomb runtime and lifecycle review boundaries

- Moved generated managed-policy files outside agent-writable task trees,
  isolated tmux launches with the same compiled child environment as headless
  runs, and closed shell/path/domain hook bypasses.
- Bound catalog disclosures to the verified manifest and serialized selection
  recovery and generation cleanup with task creation/moves.
- Added inspect-before-consent install/remove dry runs, closed lifecycle JSON
  schema arms, and adversarial regression coverage for each repaired boundary.
