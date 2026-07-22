## [2026-07-21T22:25:58Z] fix — complete strict project config propagation

**Action:** Preserved `UnsupportedProjectConfigError` through both `hive new`
config readers, managed task resolution, and every status presentation. Strict
root-key failures now remain exit 78 instead of becoming exit 1, exit 64, or an
`ok: true` degraded status payload. Root-key validation also runs before an
invalid workflow-path expansion can hide the `reviewers` migration guidance.

Project workflow loading now resolves the raw config once, installs one
fingerprinted overlay, and validates against that active stage vocabulary
without a `Config.load` reverse cycle. Subsequent config reads reuse the active
overlay rather than rescanning descriptors.

**Docs:** Corrected custom-stage override guidance: `agent` and `permissions`
belong in the stage block, resource limits use `budget_usd.<stage>` and
`timeout_sec.<stage>`, and descriptor stages own `model` / `effort`.

**Coverage:** Added focused regressions for new, status, managed tasks,
invalid-path ordering, and workflow fingerprint reuse.
