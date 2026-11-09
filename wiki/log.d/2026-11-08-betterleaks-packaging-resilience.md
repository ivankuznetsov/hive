# Betterleaks packaging resilience

Add opt-in digest-keyed archive reuse with private per-use verification and
atomic best-effort publication. Keep Betterleaks 1.8.1, all four pinned digests,
licenses, paths, and modes. Bound every required archive's HTTPS requests,
redirects, token rejection fallback, retries, and backoff to one 300-second
monotonic deadline, with origin-bound private auth headers and safe diagnostics.

Wire all eight CI/build paths to the pinned Actions cache with OS/source-file
keys and prefix restoration. Keep both release-candidate consumers anonymous,
match candidate cache setup to fresh builds, and preserve environment inheritance
and exact-byte reuse. Forward bounded fixed packaging diagnostics in candidates.
Document post-change-main dispatch/action-lock and trusted-harness sequencing.

Controlled real-digest archive, outage, concurrency, transport, workflow, and
candidate tests cover local behavior; a short real subprocess test covers timeout
cleanup. The separate anonymous HTTP/2 302-to-release-assets/200 capture informs
sanitized parser fixtures only. The rewritten curl redirect/auth transport has
not been exercised against the production GitHub release endpoint before merge.
Document cache scope/immutability, cold/full-pin rollout failures, and the
20-minute worst-case packaging allowance against unchanged 15/20-minute job
limits and their opaque runner cancellation behavior. Retain existing platform
execution and deployment evidence gaps.
