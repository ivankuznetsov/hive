## [2026-07-26T04:46:08Z] Skillpack internal boundary

**Action:** Promoted Skillpack to `boundary-ready` behind
`require "hive/agent_skills"`. The facade now clean-loads deterministic
OpenClaw, Claude, Codex, and Pi rendering plus read-only projection inspection,
frozen preview-bound planning, and stale-safe atomic apply without loading Hive
configuration, workflows, commands, web code, or native package inventory.

**Hive dogfood:** Bundled skill inspection, setup planning/execution,
OpenClaw diagnosis, Doctor, Init preflight, setup-agents, and the web adapter
route through the facade. Hive-only target resolution, manifest parsing, native
package operations, consent, filtering, messages, and JSON presentation remain
lazily loaded adapters above the policy-light mechanism.

**Guarantee:** Plans bind path identities and tree digests. Apply refuses
foreign or unsafe trees, rejects observations that changed after preview,
stages privately, swaps the complete directory atomically, and preserves or
restores the previous managed tree on failure. This introduces no gem,
marketplace, signature system, independent version, or publication decision.

**Enforcement:** The component catalog records the public projection/report/
plan values and typed errors, validates the clean entry point and Agent ABI
dependency, and rejects production direct requires or construction of
Skillpack internals. Added focused facade coverage while retaining exact
canonical bytes, provenance, rollback, setup, and packaged projection tests.
The coverage bootstrap now reloads the version and error contracts that the
gemspec loads before instrumentation, alongside `lib/hive.rb`, so clean
entry-point splits remain visible to the unchanged 100% executable-line gate.

**Docs:** Updated [[commands/setup-agents]], [[component-boundaries]], and
[[testing]]. Did not edit compiled [[log]].

**Review hardening:** `Projection` now validates, copies, and deeply freezes
its rendered path/content mapping and identity strings. A caller cannot mutate
its own buffers after preview and make apply publish bytes the plan did not
bind.
