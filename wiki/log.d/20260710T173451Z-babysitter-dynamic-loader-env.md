## [2026-07-10T17:34:51Z] babysitter — scrub dynamic-loader env across dry-run passthrough

**Action:** Hardened `Hive::Babysitter::DryRunEnv` and both executable stubs against `LD_*` / `DYLD_*` loader injection. The parent environment is captured, scrubbed for the agent block, and restored afterward; generated launchers unset known loader injection/search variables before starting Ruby; and both stubs delete every remaining loader-prefixed key immediately before allowlisted real-binary exec. Added focused regressions for parent restoration, launcher handoff, and both `git` / `gh` passthroughs.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
