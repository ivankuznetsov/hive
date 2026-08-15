# Retry durable active Patrol findings after feature rotation

**Action:** Ordinary Patrol shipping cycles now rank the durable active finding
backlog together with newly reviewed findings. Existing semantic, history,
per-feature, fix-attempt, and PR caps remain authoritative.

**Why:** Live current-main dogfood showed two valid findings left active after
the per-feature cap selected their siblings. Once the SHA-bound feature cursor
moved on, later cycles could not retry those records unless a reviewer happened
to rediscover the same feature. The stale-SHA evidence revalidator proved both
records still apply, including exact line relocation, so commit movement was
not a valid reason to leave them without a fix attempt.

**Evidence:** The focused command regression now covers a finding skipped by
the feature cap, rotation to a later review batch with no rediscovery, and a
subsequent shipping attempt from durable state.
