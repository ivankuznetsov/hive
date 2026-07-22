## [2026-07-22T16:33:40Z] wiki — refresh queued patrol and dry-run hardening

**Action:** Inspected queued commits `207a12be` and `391f130a` plus their exact
source blobs. Documented the direct-Ruby babysitter dry-run launcher and shared
startup/loader environment boundary, command-aware Git guard changes, patrol's
durable finding registry and lifecycle fields, validator-key and exact-target
binding, clean-base validation preflight, namespaced E2E retention settings,
artifact cleanup confinement, and the cycle-free sample systemd dependency.
Refreshed the corresponding command, module, prompt-template, operating, E2E,
and testing pages.

**Uncertainty:** Neither source commit is an ancestor of the refresh branch.
The current default lacks both new registry/environment modules and retains the
older launcher, E2E environment names, and systemd ordering line, so every new
contract is branch-qualified and [[gaps]] records the required integration and
live-smoke evidence. Compiled [[log]] was not edited. Page coverage remains 94,
so [[index]] did not change.

**Refreshed pages:**

- [[commands/babysit]]
- [[commands/patrol]]
- [[e2e]]
- [[gaps]]
- [[modules/babysitter]]
- [[modules/patrol]]
- [[operating]]
- [[templates]]
- [[testing]]
