## 2026-08-05 — Seal Workflow Creator live fixtures independently of ambient umask

**Fix:** Hosted coverage runs Ruby from a toolcache artifact owned by its build
UID rather than the test process or root, so production correctly rejects that
foreign-owned executable. The live setup fixture now copies the exact host Ruby
into its current-user-owned input closure before admission. It also holds umask
`0077` across all generated inputs and restores the caller's umask afterward.
A focused regression starts from `0002` and proves the copied interpreter has
the current UID, one link, and no group/world write bits; production admission
was not relaxed.

**Evidence:** The exact hosted seed passes all eight setup tests under ambient
umask `0002` with 50 assertions and no failures, errors, or skips. The optional
hostile campaign remains outside normal CI and was not run.
