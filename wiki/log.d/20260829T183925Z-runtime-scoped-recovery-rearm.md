# Runtime replacements now rearm deterministic recovery once

**Context:** Screenote's review CI repeatedly hit Hive's hosted-log encoding
exception and reached the deterministic-failure ceiling. After the encoding fix
was merged and deployed, the fresh daemon correctly observed the recovery but
returned the old parked receipt because recovery history had no runtime-source
identity.

**Action:** Recovery requests now persist the same channel/release/build digest
used by durable attempt pacing. Retry counts and identical-failure evidence are
scoped to that digest. A changed validated runtime automatically rearms one
parked request, resets its stale ladder/evidence, and makes a bounded probe due;
same-runtime ticks remain inert. Legacy digest-less parks get exactly one
compatibility rearm. Explicit `workflow.retry` keeps its same-runtime role and
now resets the same failure series consistently.

**Coverage:** Coordinator tests pin legacy and changed-runtime rearming,
same-runtime parking, transition-loss fail-closed behavior, fresh failure
counts, and explicit unpark resets. Queue/schema tests pin the optional SHA-256
wire field and reject malformed digests; runtime identity remains the single
source for deployment-insensitive build digests.
