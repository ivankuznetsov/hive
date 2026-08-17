## 2026-08-16 — Enforce exact managed Codex reads

**Problem:** A managed actor mapped to Codex could not run when its scoped
permission block used an exact `Read(path)` rule, even though Codex's named
filesystem policy can grant read access to an individual file. The official
Architecture workflow's web-research stage therefore failed before launch.

**Fix:** Resolve exact non-wildcard read targets under declared roots and pass
only those targets to the Codex filesystem profile. Launch-time realpath checks
reject missing targets and symlink escapes. Portable runners without equivalent
enforcement continue to fail closed.

**Verification:** The runtime-policy suite covers exact-file admission and
asserts that neither the task root nor package root is granted. A real Codex
probe independently confirmed the allowed file is readable while an adjacent
task artifact is hidden.
