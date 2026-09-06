---
title: Keep quota retries hourly and workflow restrictions opt-in
date: 2026-09-06
---

Provider-limit recovery now uses the hourly cooldown from its first automatic
retry and never parks repeated quota failures as deterministic. Existing quota
parks rearm automatically while preserving their next eligible time. Ordinary
non-provider errors retain the existing failure policy.

Blank and research workflow templates no longer inject read-only permissions.
They inherit project policy, matching the authoring skill's normal-execution
guidance. Explicitly requested restrictions are unchanged.

Regression coverage checks repeated identical quotas, initial hourly delay,
legacy parked quota recovery, and absence of template-injected restrictions.
