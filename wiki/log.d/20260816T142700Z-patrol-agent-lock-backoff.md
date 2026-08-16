---
title: Architecture Patrol lock-contention backoff
area: patrol
---

Architecture Patrol now treats the shared project agent lock's
`agent_in_flight` result as a one-hour deferred retry. The finding checkpoint
remains durable and retryable, but an ordinary Patrol run can no longer make
Architecture Patrol allocate a new discovery claim and journal effects every
minute while both engines correctly serialize their agents.
