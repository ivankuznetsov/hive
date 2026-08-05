## 2026-08-05 — Seal Workflow Creator live fixtures independently of ambient umask

**Fix:** Hosted coverage ran with a group-writable ambient umask, so the live
setup fixture created an OpenClaw entrypoint that production correctly rejected
as mutable. The fixture now holds umask `0077` across all generated inputs and
restores the caller's umask afterward. A focused regression starts from `0002`
and proves setup still receives owner-private inputs; production admission was
not relaxed.

**Evidence:** The exact hosted seed passes all eight setup tests under ambient
umask `0002` with 47 assertions and no failures, errors, or skips. The optional
hostile campaign remains outside normal CI and was not run.
