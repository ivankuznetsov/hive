# 2026-11-01 — Recheck local review identity after remote confirmation

- Review publication confirmation rechecks local HEAD and branch after the final
  remote identity lookup, rejecting concurrent movement before success.
- The shared check protects both publication and terminal completion, retaining
  publication proof while leaving verification pending on movement.
- Regression coverage moves HEAD during completion's final lookup and moves HEAD
  or branch during publication confirmation.
