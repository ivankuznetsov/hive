---
date: 2026-07-30
summary: Preserve operator launchers and validate managed QMD health during setup
---

- Made the bash installer publish `hive` and `hv` user-bin symlinks only when
  their destinations are absent or already point at the exact managed
  launcher. Occupied operator paths are preserved and the safe fallback is
  selected without destructive replacement.
- Left already-correct managed links in place and made a concurrent destination
  creator fail closed into the fallback path without deleting the replacement.
- Made uninstall remove only current-user bash-channel launcher symlinks whose
  exact regular targets are under the active XDG or recorded prefix install
  root and whose stable install marker proves Hive ownership. Same-shaped
  operator trees and malformed prefix records are preserved.
- Quarantined and revalidated a launcher before unlink so a concurrent
  operator replacement is restored or retained instead of deleted.
- Made setup diagnostics run a bounded QMD startup probe, distinguish a
  repairable broken managed install from a broken operator binary, and verify
  the managed executable after npm reports success. The post-install probe has
  a 10-second process-group-cleaning timeout; diagnostic detail is
  secret-redacted and bounded.
- Kept that process lifecycle and diagnostic policy in the setup-owned
  `Hive::Setup::QmdProbe`, shared by diagnostics and post-install validation
  instead of widening the managed-Web verifier.
- Converted probe timeouts and spawn failures into typed QMD repair results so
  diagnostics and JSON setup still emit their complete envelope.
- Added focused regressions for the prior launcher overwrite/removal and false
  QMD-success cases, plus standalone setup/uninstall test dependency isolation.
