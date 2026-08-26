---
title: Recover clean Patrol output after Pi retries a rate limit
type: fix
tags: [patrol-fix, pi, rate-limit, artifact-firewall]
---

Pi can retry a temporary provider 429 internally, finish the required Patrol
Fix report, and exit zero. Managed agent custody now accepts that clean final
transaction even though the earlier event is classified as `limits_reached`
rather than `provider_error`. The recovery remains restricted to typed retry or
rate-limit failures with a valid custody report, zero exit, and no timeout;
resource exhaustion remains terminal.
