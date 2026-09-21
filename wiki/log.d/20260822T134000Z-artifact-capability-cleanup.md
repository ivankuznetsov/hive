# Artifact capability failures remove partial attempt roots

**Action:** The producer capability-preflight rescue now closes a partially
prepared capture toolkit and securely removes its private writable attempt root
before publishing the blocked pointer.

**Why:** Live daemon retries that failed Node/browser capability probing left a
new empty `attempt-03-*` directory each time. Those directories carried no
admitted evidence, could never be resumed, and accumulated outside the normal
producer teardown path.

**Tests:** The capability-block regression now creates a private partial capture,
requires toolkit close, and proves the attempt root is absent before the blocked
result returns.
