## [2026-07-10T04:00:00Z] agents - route model and effort per built-in stage

**Action:** Added source-aware top-level `models:` configuration with independent exact/coarse field inheritance. `AgentProfile` now validates capabilities and renders native Claude/Codex argv; core, review, digest, patrol, diagnosis, babysitter, rebase, native Codex review, and council calls carry closed stage identities.

**Coverage:** Added configuration/profile/spawn, stage/reviewer, descriptor/council, and auxiliary routing coverage, including mixed native flags and negative-space assertions. Updated [[modules/config]], [[modules/agent_profile]], [[modules/agent]], [[stages/review]], [[modules/digest]], [[modules/patrol]], [[modules/diagnosis_agent]], [[modules/babysitter]], [[modules/rebase]], [[testing]], [[decisions]], and [[index]]; did not edit compiled [[log]].
